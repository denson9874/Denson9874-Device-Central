// Telegram -> Claude -> Telegram. Three places the bot answers:
//   private   someone messages the bot itself
//   group     a post in a support topic of Expressive Group Chat
//   business  a message to Daryl's own account, through Telegram Business (Settings > Telegram Business > Chatbots)
// Telegram delivers one update at a time (setup.sh sets max_connections=1) and retries until it gets a 2xx.

import { type SendOptions, Telegram, type Turn, askClaude } from "./clients.ts";
import { type BotEnv, getJSON, putJSON, sameSecret } from "./env.ts";
import { BUSINESS_LABEL, type Mode, NO_ANSWER, SKIP, START, TEXT_ONLY, systemPrompt } from "./instructions.ts";

interface User {
	id: number;
	is_bot?: boolean;
}
interface Chat {
	id: number;
	type: string;
}
export interface Message {
	message_id: number;
	date: number;
	chat: Chat;
	from?: User;
	sender_chat?: Chat;
	message_thread_id?: number;
	is_topic_message?: boolean;
	reply_to_message?: Message;
	forum_topic_created?: unknown;
	business_connection_id?: string;
	text?: string;
	caption?: string;
}
interface BusinessConnection {
	id: string;
	user: User;
	is_enabled?: boolean;
	/** Bot API before 9.0 */
	can_reply?: boolean;
	rights?: { can_reply?: boolean };
}
export interface Update {
	update_id: number;
	message?: Message;
	business_connection?: BusinessConnection;
	business_message?: Message;
}

/** Tries per update. Two, so a failing Claude call can't hold up the messages behind it for long. */
const MAX_TRIES = 2;
/** Earlier turns sent along with a question, and how long they count */
const HISTORY_TURNS = 8;
const HISTORY_SECONDS = 6 * 3600;
/** Telegram's limit for one message is 4096 characters */
const MAX_REPLY = 3900;

interface Ctx {
	env: BotEnv;
	tg: Telegram;
	now: number;
}

export async function handleTelegram(request: Request, env: BotEnv): Promise<Response> {
	if (!sameSecret(request.headers.get("X-Telegram-Bot-Api-Secret-Token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) {
		return new Response("Unauthorized", { status: 401 });
	}
	const update = (await request.json()) as Update;
	if (!Number.isInteger(update.update_id)) return new Response("Bad Request", { status: 400 });

	const key = `u/${update.update_id}`;
	const seen = (await getJSON<{ tries: number; done?: boolean }>(env.STATE, key)) ?? { tries: 0 };
	if (seen.done) return new Response("ok");
	seen.tries++;
	await putJSON(env.STATE, key, seen);
	try {
		const ctx: Ctx = { env, tg: new Telegram(env.TELEGRAM_BOT_TOKEN), now: Math.floor(Date.now() / 1000) };
		if (update.message) await onMessage(update.message, ctx);
		else if (update.business_message) await onBusinessMessage(update.business_message, ctx);
		else if (update.business_connection) await saveConnection(update.business_connection, ctx);
	} catch (e) {
		console.error(`update ${update.update_id}, try ${seen.tries}:`, String(e));
		if (seen.tries < MAX_TRIES) return new Response("retry", { status: 500 });
	}
	await putJSON(env.STATE, key, { ...seen, done: true });
	return new Response("ok");
}

function topicOf(msg: Message): number {
	return msg.is_topic_message ? (msg.message_thread_id ?? 0) : 0;
}

/** The message this one really replies to. In a topic, every message "replies" to the topic's first message. */
function parentOf(msg: Message): Message | undefined {
	const r = msg.reply_to_message;
	if (!r || r.forum_topic_created || (msg.is_topic_message && r.message_id === msg.message_thread_id)) return undefined;
	return r;
}

const textOf = (msg: Message) => (msg.text ?? msg.caption ?? "").trim();

async function isOff(ctx: Ctx): Promise<boolean> {
	return (await getJSON<{ off: boolean }>(ctx.env.STATE, "off"))?.off === true;
}

/** Admins of Expressive Group Chat run the bot: their posts get no answers, and they hold the on/off switch. */
async function isAdmin(userId: number, ctx: Ctx): Promise<boolean> {
	const key = `adm/${userId}`;
	const cached = await getJSON<{ admin: boolean; t: number }>(ctx.env.STATE, key);
	if (cached && ctx.now - cached.t < 3600) return cached.admin;
	const member = await ctx.tg.call<{ status?: string }>("getChatMember", { chat_id: Number(ctx.env.CHAT_ID), user_id: userId });
	const admin = member.status === "creator" || member.status === "administrator";
	await putJSON(ctx.env.STATE, key, { admin, t: ctx.now });
	return admin;
}

async function onMessage(msg: Message, ctx: Ctx): Promise<void> {
	const { env, tg } = ctx;
	const text = textOf(msg);
	const user = msg.from;

	if (msg.chat.type === "private") {
		if (!user || user.is_bot) return;
		const command = /^\/helpdesk(?:@\w+)?\s+(on|off|status)\s*$/i.exec(text);
		if (command) {
			if (!(await isAdmin(user.id, ctx))) return;
			const what = command[1].toLowerCase();
			if (what !== "status") await putJSON(env.STATE, "off", { off: what === "off" });
			await tg.send(msg.chat.id, (await isOff(ctx)) ? "Helpdesk is OFF: I answer nobody until /helpdesk on." : "Helpdesk is ON.");
			return;
		}
		if (await isOff(ctx)) return;
		if (/^\/start\b/.test(text)) return void (await tg.send(msg.chat.id, START));
		if (!text) return void (await tg.send(msg.chat.id, TEXT_ONLY));
		await answer(ctx, { mode: "private", scope: `p/${msg.chat.id}`, userId: user.id, msg, text, send: {} });
		return;
	}

	if (String(msg.chat.id) !== env.CHAT_ID) return;
	const topic = topicOf(msg);
	if (!env.SUPPORT_TOPICS.split(",").includes(String(topic))) return;
	// Other bots, and admins posting as the group or a channel
	if (!user || user.is_bot || msg.sender_chat) return;
	if (!text || text.startsWith("/")) return;
	// A reply to another person is their conversation; a reply to the bot continues ours
	const parent = parentOf(msg);
	if (parent && parent.from?.id !== tg.id) return;
	if (await isOff(ctx)) return;
	if (await isAdmin(user.id, ctx)) return;
	await answer(ctx, { mode: "group", scope: `g/${msg.chat.id}/${user.id}`, userId: user.id, msg, text, send: { topic, replyTo: msg.message_id } });
}

const connectionKey = (id: string) => `c/${id}`;

async function saveConnection(conn: BusinessConnection, ctx: Ctx): Promise<void> {
	await putJSON(ctx.env.STATE, connectionKey(conn.id), conn);
}

async function connectionOf(id: string, ctx: Ctx): Promise<BusinessConnection> {
	const saved = await getJSON<BusinessConnection>(ctx.env.STATE, connectionKey(id));
	if (saved) return saved;
	const conn = await ctx.tg.call<BusinessConnection>("getBusinessConnection", { business_connection_id: id });
	await saveConnection(conn, ctx);
	return conn;
}

async function onBusinessMessage(msg: Message, ctx: Ctx): Promise<void> {
	const id = msg.business_connection_id;
	const user = msg.from;
	if (!id || !user || msg.chat.type !== "private") return;
	const conn = await connectionOf(id, ctx);
	const quietKey = `q/${id}/${msg.chat.id}`;
	// The owner writing in a chat means he's handling it himself
	if (user.id === conn.user.id) return void (await putJSON(ctx.env.STATE, quietKey, { t: ctx.now }));
	if (user.is_bot || conn.is_enabled === false || !(conn.rights?.can_reply ?? conn.can_reply)) return;
	const text = textOf(msg);
	if (!text || (await isOff(ctx))) return;
	const quiet = await getJSON<{ t: number }>(ctx.env.STATE, quietKey);
	if (quiet && ctx.now - quiet.t < Number(ctx.env.OWNER_QUIET_HOURS || "12") * 3600) return;
	await answer(ctx, { mode: "business", scope: `b/${id}/${msg.chat.id}`, userId: user.id, msg, text, send: { business: id, replyTo: msg.message_id } });
}

/** Counts an answer against the per-person and per-day limits; false when either is used up. */
async function underLimits(userId: number, ctx: Ctx): Promise<boolean> {
	const { env, now } = ctx;
	const userKey = `r/u/${userId}/${Math.floor(now / 3600)}`;
	const dayKey = `r/d/${Math.floor(now / 86400)}`;
	const [mine, all] = await Promise.all([getJSON<{ n: number }>(env.STATE, userKey), getJSON<{ n: number }>(env.STATE, dayKey)]);
	if ((mine?.n ?? 0) >= Number(env.MAX_REPLIES_PER_USER_HOUR || "10") || (all?.n ?? 0) >= Number(env.MAX_REPLIES_PER_DAY || "300")) return false;
	await Promise.all([putJSON(env.STATE, userKey, { n: (mine?.n ?? 0) + 1 }), putJSON(env.STATE, dayKey, { n: (all?.n ?? 0) + 1 })]);
	return true;
}

interface Ask {
	mode: Mode;
	/** Whose conversation this is: the key its recent turns are kept under */
	scope: string;
	userId: number;
	msg: Message;
	text: string;
	send: SendOptions;
}

async function answer(ctx: Ctx, ask: Ask): Promise<void> {
	const { env, tg, now } = ctx;
	if (!(await underLimits(ask.userId, ctx))) {
		console.warn(`limit reached, no answer for ${ask.scope}`);
		return;
	}
	const historyKey = `h/${ask.scope}`;
	const saved = await getJSON<{ t: number; turns: Turn[] }>(env.STATE, historyKey);
	const earlier = saved && now - saved.t < HISTORY_SECONDS ? saved.turns : [];
	const turns: Turn[] = [...earlier, { r: "user", c: ask.text }];

	await tg.typing(ask.msg.chat.id, ask.send);
	const reply = await askClaude(env.ANTHROPIC_API_KEY, env.MODEL, systemPrompt(ask.mode), turns);
	// The model answers SKIP when a message isn't for it; Claude declining counts the same
	const said = reply && reply.replace(/[^A-Za-z]/g, "").toUpperCase() !== SKIP ? reply : null;
	if (!said && ask.mode !== "private") return;

	let text = said ? said.slice(0, MAX_REPLY) : NO_ANSWER;
	if (ask.mode === "business") text = `${BUSINESS_LABEL}\n\n${text}`;
	await tg.send(ask.msg.chat.id, text, ask.send);
	if (!said) return;
	// Keep the last few turns, starting on a user turn as the API requires
	const kept = [...turns, { r: "assistant" as const, c: said }].slice(-HISTORY_TURNS);
	while (kept.length && kept[0].r !== "user") kept.shift();
	await putJSON(env.STATE, historyKey, { t: now, turns: kept });
}
