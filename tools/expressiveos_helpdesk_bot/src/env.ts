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
	SUPPORT_TOPICS: string;
	MODEL: string;
	MAX_REPLIES_PER_USER_HOUR: string;
	MAX_REPLIES_PER_DAY: string;
	OWNER_QUIET_HOURS: string;
	TELEGRAM_BOT_TOKEN: string;
	TELEGRAM_WEBHOOK_SECRET: string;
	ANTHROPIC_API_KEY: string;
}

export async function getJSON<T>(bucket: Bucket, key: string): Promise<T | null> {
	const obj = await bucket.get(key);
	return obj ? (JSON.parse(await obj.text()) as T) : null;
}

export function putJSON(bucket: Bucket, key: string, value: unknown): Promise<unknown> {
	return bucket.put(key, JSON.stringify(value));
}

/** Constant-time string comparison, for the webhook secret. */
export function sameSecret(a: string, b: string): boolean {
	if (!a || !b || a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return diff === 0;
}
