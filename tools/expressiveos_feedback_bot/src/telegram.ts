// Telegram -> GitHub. Telegram delivers one update at a time (setup.sh sets max_connections=1),
// and retries an update until it gets a 2xx, so every step checks whether an earlier try did it.

import { GitHub, Telegram } from "./clients.ts";
import { type BotEnv, type Kind, type Link, getJSON, putJSON, sameSecret } from "./env.ts";
import {
	easternDate,
	easternTime,
	escapeName,
	isChatter,
	isLauncher,
	markerLine,
	megabytes,
	messageLink,
	missingInfo,
	phonesIn,
	quote,
	safeFileName,
	setVotes,
	titleFor,
	votesLine,
} from "./format.ts";
import * as say from "./messages.ts";

interface User {
	id: number;
	is_bot?: boolean;
	first_name?: string;
	last_name?: string;
	username?: string;
}
interface Chat {
	id: number;
	type: string;
	title?: string;
	username?: string;
}
interface FileRef {
	file_id: string;
	file_size?: number;
	file_name?: string;
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
	media_group_id?: string;
	text?: string;
	caption?: string;
	entities?: { type: string; url?: string }[];
	caption_entities?: { type: string; url?: string }[];
	photo?: FileRef[];
	document?: FileRef;
	video?: FileRef;
	animation?: FileRef;
	audio?: FileRef;
	voice?: FileRef;
	video_note?: FileRef;
}
interface Reaction {
	chat: Chat;
	message_id: number;
	user?: User;
	old_reaction: { type: string; emoji?: string }[];
	new_reaction: { type: string; emoji?: string }[];
}
export interface Update {
	update_id: number;
	message?: Message;
	edited_message?: Message;
	message_reaction?: Reaction;
}

/** Tries per update before the bot gives up on it. From the third, attachments are skipped. */
const MAX_TRIES = 5;

interface Ctx {
	env: BotEnv;
	tg: Telegram;
	gh: GitHub;
	attempt: number;
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
		await handleUpdate(update, {
			env,
			tg: new Telegram(env.TELEGRAM_BOT_TOKEN),
			gh: new GitHub(env.GITHUB_TOKEN, env.GITHUB_REPO),
			attempt: seen.tries,
		});
	} catch (e) {
		console.error(`update ${update.update_id}, try ${seen.tries}:`, String(e));
		// Telegram sends it again; after MAX_TRIES the update is dropped so later ones aren't held up
		if (seen.tries < MAX_TRIES) return new Response("retry", { status: 500 });
	}
	await putJSON(env.STATE, key, { ...seen, done: true });
	return new Response("ok");
}

export async function handleUpdate(update: Update, ctx: Ctx): Promise<void> {
	if (update.message) await onMessage(update.message, ctx);
	else if (update.edited_message) await onEdit(update.edited_message, ctx);
	else if (update.message_reaction) await onReaction(update.message_reaction, ctx);
}

const linkKey = (chat: number, message: number) => `m/${chat}/${message}`;
const albumKey = (chat: number, group: string) => `g/${chat}/${group}`;

function topicOf(msg: Message): number {
	return msg.is_topic_message ? (msg.message_thread_id ?? 0) : 0;
}

/** The message this one really replies to. In a topic, every message "replies" to the topic's first message. */
function parentOf(msg: Message): Message | undefined {
	const r = msg.reply_to_message;
	if (!r || r.forum_topic_created || (msg.is_topic_message && r.message_id === msg.message_thread_id)) return undefined;
	return r;
}

function textOf(msg: Message): string {
	const text = msg.text ?? msg.caption ?? "";
	const urls = (msg.entities ?? msg.caption_entities ?? []).filter((e) => e.type === "text_link" && e.url).map((e) => e.url);
	return urls.length ? `${text}\n\nLinks: ${urls.join(" ")}` : text;
}

function author(msg: Message): { name: string; username?: string } {
	if (msg.sender_chat) return { name: msg.sender_chat.title ?? "Admin", username: msg.sender_chat.username };
	const u = msg.from;
	return { name: [u?.first_name, u?.last_name].filter(Boolean).join(" ") || "Someone", username: u?.username };
}

function byline(msg: Message): string {
	const a = author(msg);
	return `**${escapeName(a.name)}**${a.username ? ` (@​${escapeName(a.username)})` : ""}`;
}

function attachmentOf(msg: Message): { id: string; name: string; size?: number; isFile: boolean } | null {
	const ext = (f: FileRef, fallback: string) => ({ id: f.file_id, name: safeFileName(f.file_name ?? fallback), size: f.file_size });
	if (msg.document) return { ...ext(msg.document, "file"), isFile: true };
	if (msg.photo?.length) return { ...ext(msg.photo[msg.photo.length - 1], "photo.jpg"), isFile: false };
	if (msg.video) return { ...ext(msg.video, "video.mp4"), isFile: false };
	if (msg.animation) return { ...ext(msg.animation, "animation.mp4"), isFile: false };
	if (msg.video_note) return { ...ext(msg.video_note, "video-note.mp4"), isFile: false };
	if (msg.voice) return { ...ext(msg.voice, "voice.ogg"), isFile: false };
	if (msg.audio) return { ...ext(msg.audio, "audio.mp3"), isFile: false };
	return null;
}

/** Commits the message's file to the repo; returns the line for the issue or comment. */
async function saveAttachment(msg: Message, ctx: Ctx): Promise<string | null> {
	const a = attachmentOf(msg);
	if (!a) return null;
	const max = Number(ctx.env.MAX_ATTACHMENT_MB || "10") * 1048576;
	const size = a.size ? ` (${megabytes(a.size)})` : "";
	if (a.size && a.size > max) return `⚠️ ${a.name}${size} is too big for the bot: ask for a link.`;
	if (ctx.attempt >= 3) return `⚠️ The bot couldn't save ${a.name}${size}.`;
	let bytes: Uint8Array;
	try {
		bytes = await ctx.tg.download(a.id);
	} catch (e) {
		// "file is too big" (over Telegram's 20 MB) has no retry that helps
		if (/too big/i.test(String(e))) return `⚠️ ${a.name}${size} is too big for the bot: ask for a link.`;
		throw e;
	}
	if (bytes.byteLength > max) return `⚠️ ${a.name} (${megabytes(bytes.byteLength)}) is too big for the bot: ask for a link.`;
	const path = `attachments/${easternDate(msg.date)}/${msg.message_id}-${a.name}`;
	await ctx.gh.putFile(path, bytes, `Telegram attachment from message ${msg.message_id}`);
	return `📎 [${a.name}](${ctx.gh.fileUrl(path)}) (${megabytes(bytes.byteLength)})`;
}

async function onMessage(msg: Message, ctx: Ctx): Promise<void> {
	const { env, tg } = ctx;
	if (msg.chat.type === "private") {
		if (msg.from?.is_bot) return;
		await tg
			.call("sendMessage", { chat_id: msg.chat.id, text: say.DM_POINTER, link_preview_options: { is_disabled: true } })
			.catch((e) => console.warn(String(e)));
		return;
	}
	if (String(msg.chat.id) !== env.CHAT_ID) return;
	// Other bots (Rose); an admin posting as the group comes from a bot account with sender_chat set
	if (msg.from?.is_bot && !msg.sender_chat) return;

	const text = textOf(msg);
	const command = /^\/(\w+)(?:@\w+)?(?:\s+([\s\S]*))?$/.exec((msg.text ?? "").trim());
	if (command) {
		if (command[1].toLowerCase() === "track") await onTrack(msg, command[2] ?? "", ctx);
		return; // other commands (Rose's /rules, /bug ...) aren't feedback
	}

	const chat = msg.chat.id;
	if (await getJSON<Link>(env.STATE, linkKey(chat, msg.message_id))) return; // done on an earlier try

	// The rest of an album, or a reply to something already logged, joins that issue
	if (msg.media_group_id) {
		const album = await getJSON<Link>(env.STATE, albumKey(chat, msg.media_group_id));
		if (album) return addToIssue(album, msg, "added", ctx);
	}
	const parent = parentOf(msg);
	if (parent) {
		const link = await getJSON<Link>(env.STATE, linkKey(chat, parent.message_id));
		if (link) return addToIssue(link, msg, "replied", ctx);
	}

	const topic = topicOf(msg);
	const kind: Kind | null = topic === Number(env.BUGS_TOPIC) ? "bug" : topic === Number(env.IDEAS_TOPIC) ? "idea" : null;
	if (!kind) return;
	if (!attachmentOf(msg) && isChatter(text)) return;
	await createIssue(msg, kind, ctx, { parent });
}

async function createIssue(msg: Message, kind: Kind, ctx: Ctx, opts: { parent?: Message; trackedBy?: Message }): Promise<number> {
	const { env, tg, gh } = ctx;
	const chat = msg.chat.id;
	const topic = opts.trackedBy ? topicOf(opts.trackedBy) : topicOf(msg);
	const text = textOf(msg);
	const attachment = await saveAttachment(msg, ctx);
	const hasFile = Boolean(msg.document);
	const missing = kind === "bug" ? missingInfo(text, hasFile) : [];
	const phones = phonesIn(text);
	const labels = [kind, ...phones.map((p) => `phone:${p}`), ...(isLauncher(text) ? ["launcher"] : [])];
	const where = topic === Number(env.BUGS_TOPIC) ? "Bugs" : topic === Number(env.IDEAS_TOPIC) ? "Ideas" : `topic ${topic || "General"}`;

	const body = [
		text ? quote(text) : "_(no text)_",
		...(attachment ? ["", attachment] : []),
		...(opts.parent ? ["", `↩️ In reply to ${byline(opts.parent)}:`, quote(textOf(opts.parent).slice(0, 600))] : []),
		"",
		"---",
		`**From:** ${byline(msg)} · [Open in Telegram](${messageLink(msg.chat, msg.message_id, topic)})`,
		`**Topic:** ${where} · **Posted:** ${easternTime(msg.date)}`,
		...(opts.trackedBy ? [`**Logged by:** ${byline(opts.trackedBy)} with /track`] : []),
		...(missing.length ? [`**Missing from the post:** ${missing.join(", ")}`] : []),
		votesLine(0),
		markerLine({ c: chat, t: topic, m: msg.message_id, k: kind }),
	].join("\n");

	const issue = await gh.createIssue(titleFor(kind, text, author(msg).name), body, labels);
	const link: Link = { i: issue, k: kind, t: topic, r: msg.message_id };
	await putJSON(env.STATE, linkKey(chat, msg.message_id), link);
	if (msg.media_group_id) await putJSON(env.STATE, albumKey(chat, msg.media_group_id), link);

	await tg.react(chat, msg.message_id, "👀");
	// Asking is a nicety: a failure here mustn't make Telegram resend the post
	try {
		if (opts.trackedBy) {
			await tg.reply(chat, topicOf(opts.trackedBy), opts.trackedBy.message_id, say.tracked(issue, kind));
		} else if (missing.length) {
			const sent = await tg.reply(chat, topic, msg.message_id, say.askForDetails(issue, missing));
			await putJSON(env.STATE, linkKey(chat, sent), link); // replies to the ask join the issue too
		}
	} catch (e) {
		console.warn(String(e));
	}
	return issue;
}

async function addToIssue(link: Link, msg: Message, verb: "replied" | "added", ctx: Ctx): Promise<void> {
	const chat = msg.chat.id;
	const text = textOf(msg);
	const attachment = await saveAttachment(msg, ctx);
	const body = [
		`💬 ${byline(msg)} ${verb} · [Open in Telegram](${messageLink(msg.chat, msg.message_id, topicOf(msg))}) · ${easternTime(msg.date)}`,
		...(text ? ["", quote(text)] : []),
		...(attachment ? ["", attachment] : []),
	].join("\n");
	await ctx.gh.comment(link.i, body);
	await putJSON(ctx.env.STATE, linkKey(chat, msg.message_id), link);
	if (msg.media_group_id) await putJSON(ctx.env.STATE, albumKey(chat, msg.media_group_id), link);
	if (attachment) await ctx.tg.react(chat, msg.message_id, "👀");
}

async function onEdit(msg: Message, ctx: Ctx): Promise<void> {
	if (String(msg.chat.id) !== ctx.env.CHAT_ID) return;
	const link = await getJSON<Link>(ctx.env.STATE, linkKey(msg.chat.id, msg.message_id));
	const text = textOf(msg);
	if (!link || !text) return;
	await ctx.gh.comment(
		link.i,
		[`✏️ ${byline(msg)} edited their message · [Open in Telegram](${messageLink(msg.chat, msg.message_id, topicOf(msg))})`, "", quote(text)].join("\n"),
	);
}

const thumbsUp = (list: { type: string; emoji?: string }[]) => (list.some((r) => r.type === "emoji" && r.emoji === "👍") ? 1 : 0);

/** 👍 on a logged post is a vote (the Ideas topic asks for them); the count goes in the issue body. */
async function onReaction(r: Reaction, ctx: Ctx): Promise<void> {
	if (String(r.chat.id) !== ctx.env.CHAT_ID) return;
	const delta = thumbsUp(r.new_reaction) - thumbsUp(r.old_reaction);
	if (!delta) return;
	const link = await getJSON<Link>(ctx.env.STATE, linkKey(r.chat.id, r.message_id));
	if (!link || link.r !== r.message_id) return; // only the issue's own post counts
	const key = `v/${r.chat.id}/${r.message_id}`;
	const votes = Math.max(0, ((await getJSON<number>(ctx.env.STATE, key)) ?? 0) + delta);
	await putJSON(ctx.env.STATE, key, votes);
	const issue = await ctx.gh.getIssue(link.i);
	await ctx.gh.setBody(link.i, setVotes(issue.body ?? "", votes));
}

async function isAdmin(msg: Message, ctx: Ctx): Promise<boolean> {
	if (msg.sender_chat?.id === msg.chat.id) return true; // an anonymous admin
	if (!msg.from) return false;
	const member = await ctx.tg.call<{ status: string }>("getChatMember", { chat_id: msg.chat.id, user_id: msg.from.id });
	return member.status === "creator" || member.status === "administrator";
}

/** Admins: reply "/track" (or "/track idea") to any message in the chat to log it. */
async function onTrack(msg: Message, arg: string, ctx: Ctx): Promise<void> {
	if (!(await isAdmin(msg, ctx))) return;
	const chat = msg.chat.id;
	const target = parentOf(msg);
	if (!target) {
		await ctx.tg.reply(chat, topicOf(msg), msg.message_id, say.TRACK_HOW);
		return;
	}
	const existing = await getJSON<Link>(ctx.env.STATE, linkKey(chat, target.message_id));
	if (existing) {
		await ctx.tg.reply(chat, topicOf(msg), msg.message_id, say.alreadyLogged(existing.i));
		return;
	}
	const kind: Kind = /idea/i.test(arg) ? "idea" : /bug/i.test(arg) ? "bug" : topicOf(msg) === Number(ctx.env.IDEAS_TOPIC) ? "idea" : "bug";
	// The quoted copy of the message has no topic fields of its own; it's in the command's topic
	const copy: Message = { ...target, is_topic_message: msg.is_topic_message, message_thread_id: msg.message_thread_id };
	await createIssue(copy, kind, ctx, { trackedBy: msg });
}
