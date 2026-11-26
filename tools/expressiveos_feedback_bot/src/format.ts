// Pure helpers: reading a Telegram post and writing the issue text. No network, no bindings.

import type { Kind } from "./env.ts";
import type { Missing } from "./messages.ts";

export const PHONES: [codename: string, pattern: RegExp][] = [
	["cheetah", /\b(cheetah|pixel ?7 ?pro|p7 ?pro|7 ?pro)\b/i],
	["husky", /\b(husky|pixel ?8 ?pro|p8 ?pro|8 ?pro)\b/i],
	["kodiak", /\b(kodiak|(pixel ?|p)11 ?pro ?xl)\b/i],
	["yogi", /\b(yogi|(pixel ?|p)11 ?pro ?fold)\b/i],
	["grizzly", /\b(grizzly|(pixel ?|p)11 ?pro)\b(?! ?(xl|fold))/i],
	["cubs", /\b(cubs|(pixel ?|p)11)\b(?! ?pro)/i],
];

// The pinned bug template's hints. A post that copies the template without filling a line in
// shouldn't count as naming a phone or attaching a log.
const TEMPLATE_HINTS = ["(for example Pixel 7 Pro)", "(Settings > About phone)", "adb logcat -b all -d > log.txt", "yes or no"];
const TEMPLATE_LABEL = /^(phone|build date|root, modules or another kernel|what happened|steps to make it happen again|log, taken right after)\s*:?\s*/i;

function withoutHints(text: string): string {
	let out = text;
	for (const hint of TEMPLATE_HINTS) out = out.split(hint).join(" ");
	return out;
}

export function phonesIn(text: string): string[] {
	const t = withoutHints(text);
	return PHONES.filter(([, re]) => re.test(t)).map(([name]) => name);
}

export function isLauncher(text: string): boolean {
	return /\b(launcher|app drawer|drawer|home ?screen|smartspacer?|at a glance|recents|icon pack|widgets?)\b/i.test(text) || /\bEL\b/.test(text);
}

const MONTH = "(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?";
const BUILD = new RegExp(
	[
		"\\b20\\d{6}\\b", // 20261103
		"\\b20\\d\\d[-./]\\d{1,2}[-./]\\d{1,2}\\b", // 2026-11-03
		"\\b\\d{1,2}[/.-]\\d{1,2}([/.-]\\d{2,4})?\\b", // 11/03, 3.11.26
		`\\b${MONTH} ?\\d{1,2}(st|nd|rd|th)?\\b`, // Nov 3
		`\\b\\d{1,2}(st|nd|rd|th)? ${MONTH}`, // 3 Nov
		"\\bv?\\d+\\.\\d+(\\.\\d+)*\\b", // 1.0, 5.1.0
	].join("|"),
	"i",
);

const LOG_LINK =
	/https?:\/\/\S*(pastebin|del\.dog|gist\.github|dpaste|katb\.in|nekobin|hastebin|paste\.|0x0\.st|termbin|privatebin|rentry\.|drive\.google\.com|mega\.nz)/i;
const LOG_SNIPPET =
	/(FATAL EXCEPTION|AndroidRuntime:|--------- beginning of (crash|main|system)|\b\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3}\b|\bavc:\s*denied\b)/i;
const NON_LOG_MEDIA_EXT = /\.(jpe?g|png|gif|webp|heic|bmp|mp4|mov|mkv|webm|avi|mp3|ogg|wav|m4a|flac|apk)$/i;
const NON_LOG_MIME = /^(image|video|audio)\/|^application\/vnd\.android\.package-archive$/i;

/** True when a Telegram document attachment is an actual log/archive rather than an image, video, audio or APK. */
export function isLogDocument(doc?: { file_name?: string; mime_type?: string } | null): boolean {
	if (!doc) return false;
	if (doc.mime_type && NON_LOG_MIME.test(doc.mime_type)) return false;
	if (doc.file_name && NON_LOG_MEDIA_EXT.test(doc.file_name)) return false;
	return true;
}

/** True when message text includes a paste/log link or pasted logcat/crash output (not merely the word "logcat"). */
export function hasLogText(text: string): boolean {
	const t = withoutHints(text);
	return LOG_LINK.test(t) || LOG_SNIPPET.test(t);
}

/** What the pinned template asks for that a bug report doesn't have. */
export function missingInfo(text: string, hasLogFile: boolean): Missing[] {
	const t = withoutHints(text);
	const missing: Missing[] = [];
	if (!phonesIn(t).length) missing.push("phone");
	if (!BUILD.test(t)) missing.push("build");
	if (!hasLogFile && !hasLogText(t)) missing.push("log");
	return missing;
}

const TEMPLATE_LINE = /^(phone|build date|root, modules or another kernel|what happened|steps to make it happen again|log, taken right after)\s*:/im;
const HOW_TO_QUESTION =
	/\b(how (do|can|should|to)\b|where (do|can|is|are)\b|what (is|are) (the|expressive)|can i\b|do i (need|have) to\b|will .* require\b|which logs?\b)/i;
const BUG_SYMPTOMS =
	/\b(bug|crash(es|ed|ing)?|broken|breaks?|freez(e|es|ing)|froze|lag(s|ging)?|stutter(s|ing)?|bootloop(s|ing)?|reboot(s|ing)?|drain(s|ing)?|overheat(s|ing)?|flicker(s|ing)?|glitch(es|ing)?|stuck|fail(s|ed|ing)?|error|issue|problem|doesn'?t work|not working|won'?t (turn|open|start|boot|connect|charge|install|send)|stopped working|force clos(e|es|ing)|\bfc\b|dead|vanish(es|ed)?|disappear(s|ed)?|drop(s|ped|ping)?)\b/i;

/**
 * Pure how-to/support questions in Bugs (753) — e.g. "How do I take a logcat?" or "Can I dirty flash 1.3.1?" —
 * are answered by the Helpdesk bot rather than treated as unlogged bug reports. Any post naming a failure/symptom,
 * carrying an attachment, or using the bug template is treated as a bug report.
 */
export function isSupportQuestion(text: string, hasAttachment = false): boolean {
	const t = text.trim();
	if (!t || hasAttachment || !t.includes("?")) return false;
	if (TEMPLATE_LINE.test(t) || BUG_SYMPTOMS.test(t)) return false;
	return HOW_TO_QUESTION.test(t);
}

/** "ok", "thanks", "+1" and emoji-only posts aren't reports on their own (as replies they still join an issue). */
export function isChatter(text: string): boolean {
	const t = text.trim();
	if (!t) return true;
	if (/^[\p{Extended_Pictographic}\u200d\ufe0f\s]+$/u.test(t)) return true;
	return /^(ok(ay)?|thanks?( you)?|thx|ty|nice|great|cool|same( here)?|me too|\+1|lol|yes|no|yep|nope)[\s.!🙏👍]*$/i.test(t);
}

function clip(text: string, max: number): string {
	if (text.length <= max) return text;
	const cut = text.slice(0, max - 1);
	const space = cut.lastIndexOf(" ");
	return `${space > max / 2 ? cut.slice(0, space) : cut}…`;
}

/** The issue title: the template's "What happened" line, else the first line that isn't a template label. */
export function titleFor(kind: Kind, text: string, author: string): string {
	const lines = text
		.split("\n")
		.map((l) => l.replace(/[*_`]/g, "").trim())
		.filter(Boolean);
	const what = lines.find((l) => /^what happened\s*:/i.test(l))?.replace(TEMPLATE_LABEL, "").trim();
	const first = lines.find((l) => !TEMPLATE_LABEL.test(l) && !/^[^\p{L}\p{N}]*how to report a bug/iu.test(l));
	const title = (what || first || "").replace(/\s+/g, " ");
	if (title) return clip(title, 90);
	return kind === "bug" ? `Bug report from ${author}` : `Idea from ${author}`;
}

/**
 * User text for an issue. "@name" must not ping a GitHub user who happens to share a Telegram
 * name, and "<" is escaped so the text shows as written and can't fake the bot's own markers.
 */
export function sanitize(text: string): string {
	return text.replace(/</g, "&lt;").replace(/@(?=[A-Za-z0-9_])/g, "@​");
}

export function quote(text: string): string {
	return sanitize(text)
		.split("\n")
		.map((l) => (l ? `> ${l}` : ">"))
		.join("\n");
}

/** A name in bold text: Markdown characters escaped, mentions defused. */
export function escapeName(name: string): string {
	return sanitize(name).replace(/[\\`*_[\]|~#]/g, "\\$&");
}

export function messageLink(chat: { id: number; username?: string }, messageId: number, topic: number): string {
	const base = chat.username ? `https://t.me/${chat.username}` : `https://t.me/c/${String(chat.id).replace(/^-100/, "")}`;
	return topic ? `${base}/${topic}/${messageId}` : `${base}/${messageId}`;
}

/** "Nov 5, 2026, 4:50 AM ET" */
export function easternTime(unixSeconds: number): string {
	const s = new Intl.DateTimeFormat("en-US", {
		timeZone: "America/New_York",
		year: "numeric",
		month: "short",
		day: "numeric",
		hour: "numeric",
		minute: "2-digit",
	}).format(new Date(unixSeconds * 1000));
	return `${s} ET`;
}

/** "2026-11-05" in Eastern time, for attachment folders */
export function easternDate(unixSeconds: number): string {
	return new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date(unixSeconds * 1000));
}

/** A milestone's due date as "Dec 3". GitHub keeps the day in UTC (midnight Pacific when set on the website). */
export function dueDay(iso: string | null | undefined): string | undefined {
	if (!iso) return undefined;
	return new Intl.DateTimeFormat("en-US", { timeZone: "UTC", month: "short", day: "numeric" }).format(new Date(iso));
}

export function megabytes(bytes: number): string {
	return `${(bytes / 1048576).toFixed(bytes < 1048576 ? 2 : 1)} MB`;
}

/** The bot's marker at the end of an issue body: where the issue's first post is in Telegram. */
export interface Marker {
	c: number;
	t: number;
	m: number;
	k: Kind;
}

export function markerLine(marker: Marker): string {
	return `<!-- tg:${JSON.stringify(marker)} -->`;
}

/** The last marker in an issue body. User text can't hold one: sanitize() escapes "<". */
export function parseMarker(body: string | null | undefined): Marker | null {
	const all = [...(body ?? "").matchAll(/<!-- tg:(\{[^<>]*\}) -->/g)];
	if (!all.length) return null;
	try {
		const m = JSON.parse(all[all.length - 1][1]) as Marker;
		return Number.isInteger(m.c) && Number.isInteger(m.m) ? m : null;
	} catch {
		return null;
	}
}

const VOTES = /^\*\*👍 votes:\*\* \d+$/m;

export function votesLine(n: number): string {
	return `**👍 votes:** ${n}`;
}

/** The issue body with its vote count set (the line is added above the marker if it's missing). */
export function setVotes(body: string, n: number): string {
	if (VOTES.test(body)) return body.replace(VOTES, votesLine(n));
	const at = body.lastIndexOf("<!-- tg:");
	return at < 0 ? `${body}\n${votesLine(n)}` : `${body.slice(0, at)}${votesLine(n)}\n${body.slice(at)}`;
}

/** A file name that's safe in a repo path and a URL. */
export function safeFileName(name: string): string {
	const clean = name.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^[._]+/, "") || "file";
	if (clean.length <= 80) return clean;
	const ext = /\.[A-Za-z0-9]{1,8}$/.exec(clean)?.[0] ?? "";
	return clean.slice(0, 80 - ext.length) + ext;
}
