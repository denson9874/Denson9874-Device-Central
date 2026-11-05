// What the Worker gets from cloudflare.config.ts. Written out here (rather than generated) so the
// tests can hand the handlers a plain object and an in-memory bucket.

/** The part of an R2 bucket the bot uses. */
export interface Bucket {
	get(key: string): Promise<{ text(): Promise<string> } | null>;
	put(key: string, value: string): Promise<unknown>;
}

export interface BotEnv {
	STATE: Bucket;
	CHAT_ID: string;
	BUGS_TOPIC: string;
	IDEAS_TOPIC: string;
	GITHUB_REPO: string;
	REPLY_LOGINS: string;
	MAX_ATTACHMENT_MB: string;
	TELEGRAM_BOT_TOKEN: string;
	TELEGRAM_WEBHOOK_SECRET: string;
	GITHUB_TOKEN: string;
	GITHUB_WEBHOOK_SECRET: string;
}

export type Kind = "bug" | "idea";

/** Which issue a Telegram message belongs to. Stored for every message the bot logged or sent. */
export interface Link {
	/** Issue number */
	i: number;
	k: Kind;
	/** Topic (message_thread_id) of the issue's first post, 0 outside topics */
	t: number;
	/** Message id of the issue's first post */
	r: number;
}

export async function getJSON<T>(bucket: Bucket, key: string): Promise<T | null> {
	const obj = await bucket.get(key);
	return obj ? (JSON.parse(await obj.text()) as T) : null;
}

export function putJSON(bucket: Bucket, key: string, value: unknown): Promise<unknown> {
	return bucket.put(key, JSON.stringify(value));
}

/** Constant-time string comparison, for webhook secrets and signatures. */
export function sameSecret(a: string, b: string): boolean {
	if (!a || !b || a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return diff === 0;
}
