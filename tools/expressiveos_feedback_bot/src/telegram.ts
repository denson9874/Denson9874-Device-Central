// Telegram -> GitHub. Telegram delivers one update at a time (setup.sh sets max_connections=1),
// and retries an update until it gets a 2xx, so every step checks whether an earlier try did it.

import { GitHub, Telegram } from "./clients.ts";
import { type BotEnv, type Kind, type Link, type PendingBug, type StrikeState, getJSON, putJSON, sameSecret } from "./env.ts";
import {
	easternDate,
	easternTime,
	escapeName,
	hasLogText,
	isChatter,
	isLauncher,
	isLogDocument,
	isSupportQuestion,
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
	mime_type?: string;
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
		await handleUpdate(update, {
			env,
			tg: new Telegram(env.TELEGRAM_BOT_TOKEN),
			gh: new GitHub(env.GITHUB_TOKEN, env.GITHUB_REPO),
			attempt: seen.tries,
			now: Math.floor(Date.now() / 1000),
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
const pendingKey = (chat: number, message: number) => `p/${chat}/${message}`;
const pendingAlbumKey = (chat: number, group: string) => `pg/${chat}/${group}`;
const strikeKey = (chat: number, user: number) => `w/${chat}/${user}`;

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

function formatByline(name: string, username?: string): string {
	return `**${escapeName(name)}**${username ? ` (@​${escapeName(username)})` : ""}`;
}

function byline(msg: Message): string {
	const a = author(msg);
	return formatByline(a.name, a.username);
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

async function saveFileRef(
	file: { id: string; name: string; size?: number },
	date: number,
	messageId: number,
	ctx: Ctx,
): Promise<string> {
	const max = Number(ctx.env.MAX_ATTACHMENT_MB || "10") * 1048576;
	const size = file.size ? ` (${megabytes(file.size)})` : "";
	if (file.size && file.size > max) return `⚠️ ${file.name}${size} is too big for the bot: ask for a link.`;
	if (ctx.attempt >= 3) return `⚠️ The bot couldn't save ${file.name}${size}.`;
	let bytes: Uint8Array;
	try {
		bytes = await ctx.tg.download(file.id);
	} catch (e) {
		// "file is too big" (over Telegram's 20 MB) has no retry that helps
		if (/too big/i.test(String(e))) return `⚠️ ${file.name}${size} is too big for the bot: ask for a link.`;
		throw e;
	}
	if (bytes.byteLength > max) return `⚠️ ${file.name} (${megabytes(bytes.byteLength)}) is too big for the bot: ask for a link.`;
	const path = `attachments/${easternDate(date)}/${messageId}-${file.name}`;
	await ctx.gh.putFile(path, bytes, `Telegram attachment from message ${messageId}`);
	return `📎 [${file.name}](${ctx.gh.fileUrl(path)}) (${megabytes(bytes.byteLength)})`;
}

/** Commits the message's file to the repo; returns the line for the issue or comment. */
async function saveAttachment(msg: Message, ctx: Ctx): Promise<string | null> {
	const a = attachmentOf(msg);
	return a ? saveFileRef(a, msg.date, msg.message_id, ctx) : null;
}

function hasLogs(msg: Message, text: string): boolean {
	return isLogDocument(msg.document) || hasLogText(text);
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
	// Other bots (Rose, Helpdesk); an admin posting as the group comes from a bot account with sender_chat set
	if (msg.from?.is_bot && !msg.sender_chat) return;

	const text = textOf(msg);
	const command = /^\/(\w+)(?:@\w+)?(?:\s+([\s\S]*))?$/.exec((msg.text ?? "").trim());
	if (command) {
		const cmd = command[1].toLowerCase();
		if (cmd === "track") await onTrack(msg, command[2] ?? "", ctx);
		else if (cmd === "unwarn") await onUnwarn(msg, ctx);
		return; // other commands (Rose's /rules, /bug ...) aren't feedback
	}

	const chat = msg.chat.id;
	if (await getJSON<Link>(env.STATE, linkKey(chat, msg.message_id))) return; // done on an earlier try

	// The rest of an album, or a reply to something already logged, joins that issue
	if (msg.media_group_id) {
		const album = await getJSON<Link>(env.STATE, albumKey(chat, msg.media_group_id));
		if (album) return addToIssue(album, msg, "added", ctx);
		// Extra screenshots in a logless bug album don't trigger a second strike
		const pendingAlbum = await getJSON<{ m: number }>(env.STATE, pendingAlbumKey(chat, msg.media_group_id));
		if (pendingAlbum) {
			const pending = await getJSON<PendingBug>(env.STATE, pendingKey(chat, pendingAlbum.m));
			if (pending && !pending.i) {
				if (hasLogs(msg, text)) await promotePendingBug(pending, msg, ctx);
				return;
			}
		}
	}
	const parent = parentOf(msg);
	if (parent) {
		const link = await getJSON<Link>(env.STATE, linkKey(chat, parent.message_id));
		if (link) return addToIssue(link, msg, "replied", ctx);
		const pendingRef = await getJSON<PendingBug | { ref: number }>(env.STATE, pendingKey(chat, parent.message_id));
		if (pendingRef) {
			const rootId = "ref" in pendingRef ? pendingRef.ref : pendingRef.m;
			const pending = "ref" in pendingRef ? await getJSON<PendingBug>(env.STATE, pendingKey(chat, rootId)) : pendingRef;
			if (pending && !pending.i) {
				if (hasLogs(msg, text)) {
					await promotePendingBug(pending, msg, ctx);
				} else if (text.trim()) {
					pending.extra = [...(pending.extra ?? []), text];
					await putJSON(env.STATE, pendingKey(chat, pending.m), pending);
				}
				return;
			}
		}
	}

	const topic = topicOf(msg);
	const kind: Kind | null = topic === Number(env.BUGS_TOPIC) ? "bug" : topic === Number(env.IDEAS_TOPIC) ? "idea" : null;
	if (!kind) return;
	const att = attachmentOf(msg);
	if (!att && isChatter(text)) return;

	if (kind === "bug") {
		// Pure how-to questions ("How do I take a logcat?") are answered by Helpdesk bot without a strike or issue
		if (isSupportQuestion(text, Boolean(att))) return;
		// Replies to another member's unlogged chat in Bugs aren't standalone bug reports unless they include logs
		if (parent && !hasLogs(msg, text)) return;
		// Non-admin bug reports in Bugs (753) without logs get warned (1/3, 2/3) and muted for 48h on 3/3
		if (!hasLogs(msg, text) && msg.from && !(await isAdmin(msg, ctx))) {
			await warnMissingLogs(msg, ctx);
			return;
		}
	}

	await createIssue(msg, kind, ctx, { parent });
}

async function warnMissingLogs(msg: Message, ctx: Ctx): Promise<void> {
	const { env, tg, now } = ctx;
	const chat = msg.chat.id;
	const topic = topicOf(msg);
	const userId = msg.from!.id;
	const maxStrikes = Math.max(1, Number(env.MAX_LOG_STRIKES || "3"));
	const muteHours = Math.max(1, Number(env.MUTE_HOURS || "48"));

	// Idempotent if an earlier webhook try already created the pending record
	const existing = await getJSON<PendingBug>(env.STATE, pendingKey(chat, msg.message_id));
	if (existing) return;

	const sKey = strikeKey(chat, userId);
	const prev = (await getJSON<StrikeState>(env.STATE, sKey)) ?? { count: 0, updatedAt: now };
	const strike = prev.lastMessageId === msg.message_id ? prev.count || maxStrikes : prev.count + 1;

	let replyText: string;
	if (strike >= maxStrikes) {
		const untilDate = Math.max(now, msg.date) + muteHours * 3600;
		const restricted = await tg.muteMember(chat, userId, untilDate);
		// Reset strike count to 0 once the 48h mute triggers
		await putJSON(env.STATE, sKey, {
			count: 0,
			lastMessageId: msg.message_id,
			mutedUntil: untilDate,
			updatedAt: now,
		} satisfies StrikeState);
		replyText = say.mutedForMissingLogs(maxStrikes, muteHours, restricted);
	} else {
		await putJSON(env.STATE, sKey, {
			count: strike,
			lastMessageId: msg.message_id,
			updatedAt: now,
		} satisfies StrikeState);
		replyText = say.missingLogWarning(strike, maxStrikes, muteHours);
	}

	const a = author(msg);
	const att = attachmentOf(msg);
	const pending: PendingBug = {
		m: msg.message_id,
		t: topic,
		u: userId,
		name: a.name,
		username: a.username,
		date: msg.date,
		text: textOf(msg),
		...(att ? { media: { id: att.id, name: att.name, size: att.size } } : {}),
	};

	try {
		const sent = await tg.reply(chat, topic, msg.message_id, replyText);
		pending.w = sent;
		await putJSON(env.STATE, pendingKey(chat, sent), { ref: msg.message_id });
	} catch (e) {
		console.warn(String(e));
	}
	await putJSON(env.STATE, pendingKey(chat, msg.message_id), pending);
	if (msg.media_group_id) await putJSON(env.STATE, pendingAlbumKey(chat, msg.media_group_id), { m: msg.message_id });
}

async function promotePendingBug(pending: PendingBug, logMsg: Message, ctx: Ctx): Promise<number> {
	const { env, tg, gh } = ctx;
	const chat = logMsg.chat.id;
	const topic = pending.t;
	const logText = textOf(logMsg);
	const combinedText = [pending.text, ...(pending.extra ?? []), logText].filter(Boolean).join("\n\n");
	const origMedia = pending.media ? await saveFileRef(pending.media, pending.date, pending.m, ctx) : null;
	const logAttachment = logMsg.message_id === pending.m ? null : await saveAttachment(logMsg, ctx);
	const hasLogFile = isLogDocument(logMsg.document);
	const missing = missingInfo(combinedText, hasLogFile).filter((m) => m !== "log");
	const phones = phonesIn(combinedText);
	const labels = ["bug", ...phones.map((p) => `phone:${p}`), ...(isLauncher(combinedText) ? ["launcher"] : [])];

	const body = [
		pending.text ? quote(pending.text) : "_(no text)_",
		...(origMedia ? ["", origMedia] : []),
		...(pending.extra?.length ? ["", ...pending.extra.map((e) => quote(e))] : []),
		...(logMsg.message_id !== pending.m && logText ? ["", `💬 Log follow-up:`, quote(logText)] : []),
		...(logAttachment ? ["", logAttachment] : []),
		"",
		"---",
		`**From:** ${formatByline(pending.name, pending.username)} · [Open in Telegram](${messageLink(logMsg.chat, pending.m, topic)})`,
		`**Topic:** Bugs · **Posted:** ${easternTime(pending.date)}`,
		...(missing.length ? [`**Missing from the post:** ${missing.join(", ")}`] : []),
		votesLine(0),
		markerLine({ c: chat, t: topic, m: pending.m, k: "bug" }),
	].join("\n");

	const issue = await gh.createIssue(titleFor("bug", combinedText, pending.name), body, labels);
	const link: Link = { i: issue, k: "bug", t: topic, r: pending.m };
	pending.i = issue;
	await putJSON(env.STATE, pendingKey(chat, pending.m), pending);
	await putJSON(env.STATE, linkKey(chat, pending.m), link);
	await putJSON(env.STATE, linkKey(chat, logMsg.message_id), link);
	if (pending.w) await putJSON(env.STATE, linkKey(chat, pending.w), link);

	await tg.react(chat, logMsg.message_id, "👀");
	try {
		const sent = await tg.reply(chat, topic, logMsg.message_id, say.loggedWithLog(issue, missing));
		await putJSON(env.STATE, linkKey(chat, sent), link);
	} catch (e) {
		console.warn(String(e));
	}
	return issue;
}

async function createIssue(msg: Message, kind: Kind, ctx: Ctx, opts: { parent?: Message; trackedBy?: Message }): Promise<number> {
	const { env, tg, gh } = ctx;
	const chat = msg.chat.id;
	const topic = opts.trackedBy ? topicOf(opts.trackedBy) : topicOf(msg);
	const text = textOf(msg);
	const attachment = await saveAttachment(msg, ctx);
	const hasLogFile = isLogDocument(msg.document);
	const missing = kind === "bug" ? missingInfo(text, hasLogFile) : [];
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
	const text = textOf(msg);
	const link = await getJSON<Link>(ctx.env.STATE, linkKey(msg.chat.id, msg.message_id));
	if (link) {
		if (!text) return;
		await ctx.gh.comment(
			link.i,
			[`✏️ ${byline(msg)} edited their message · [Open in Telegram](${messageLink(msg.chat, msg.message_id, topicOf(msg))})`, "", quote(text)].join("\n"),
		);
		return;
	}
	const pending = await getJSON<PendingBug>(ctx.env.STATE, pendingKey(msg.chat.id, msg.message_id));
	if (pending && !pending.i && hasLogs(msg, text)) {
		pending.text = text;
		await promotePendingBug(pending, msg, ctx);
	}
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

/** Admins: reply "/unwarn" to a member's message to clear their missing-log strikes. */
async function onUnwarn(msg: Message, ctx: Ctx): Promise<void> {
	if (!(await isAdmin(msg, ctx))) return;
	const chat = msg.chat.id;
	const target = parentOf(msg);
	if (!target?.from) {
		await ctx.tg.reply(chat, topicOf(msg), msg.message_id, say.UNWARN_HOW);
		return;
	}
	await putJSON(ctx.env.STATE, strikeKey(chat, target.from.id), { count: 0, updatedAt: ctx.now } satisfies StrikeState);
	await ctx.tg.reply(chat, topicOf(msg), msg.message_id, say.unwarned(author(target).name));
}
