// A fake Telegram, Claude API and R2 for the tests: fetch is replaced, every call is recorded.

import type { BotEnv, Bucket } from "../src/env.ts";

export const CHAT = -1004427242312;
export const ROM = 755;
export const BUGS = 753;
export const BOT_ID = 123;
export const OWNER = 500;
export const CONN = "conn1";

export class MemoryBucket implements Bucket {
	data = new Map<string, string>();
	async get(key: string) {
		const v = this.data.get(key);
		return v === undefined ? null : { text: async () => v };
	}
	async put(key: string, value: string) {
		this.data.set(key, value);
	}
}

export interface Call {
	url: string;
	body: any;
}

export class World {
	calls: Call[] = [];
	admins = new Set<number>([OWNER]);
	/** What Claude says next; a function sees the request body */
	claude: string | ((body: any) => string) = "Use the web installer.";
	stopReason = "end_turn";
	failing = new Set<string>();
	bucket = new MemoryBucket();
	env: BotEnv = {
		STATE: this.bucket,
		CHAT_ID: String(CHAT),
		SUPPORT_TOPICS: "755,754,752",
		MODEL: "claude-sonnet-5-5",
		MAX_REPLIES_PER_USER_HOUR: "3",
		MAX_REPLIES_PER_DAY: "300",
		OWNER_QUIET_HOURS: "12",
		TELEGRAM_BOT_TOKEN: `${BOT_ID}:token`,
		TELEGRAM_WEBHOOK_SECRET: "tg-secret",
		ANTHROPIC_API_KEY: "test-key",
	};
	#realFetch = globalThis.fetch;

	install() {
		globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
			if (input instanceof Request) return this.#handle(input.url, await input.text());
			return this.#handle(String(input), init?.body);
		}) as typeof fetch;
		return this;
	}
	uninstall() {
		globalThis.fetch = this.#realFetch;
	}

	tg(method?: string): Call[] {
		return this.calls.filter((c) => c.url.includes("api.telegram.org/bot") && (!method || c.url.endsWith(`/${method}`)));
	}
	asked(): Call[] {
		return this.calls.filter((c) => c.url.startsWith("https://api.anthropic.com/"));
	}

	#json(value: unknown, status = 200) {
		return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
	}

	async #handle(url: string, raw: unknown): Promise<Response> {
		let body: any = raw;
		if (typeof body === "string") {
			try {
				body = JSON.parse(body);
			} catch {}
		}
		this.calls.push({ url, body });

		const tg = /^https:\/\/api\.telegram\.org\/bot[^/]+\/(\w+)$/.exec(url);
		if (tg) {
			const name = tg[1];
			if (this.failing.has(name)) return this.#json({ ok: false, error_code: 500, description: "Internal" }, 500);
			if (name === "sendMessage") return this.#json({ ok: true, result: { message_id: 9000 + this.tg("sendMessage").length } });
			if (name === "getChatMember") return this.#json({ ok: true, result: { status: this.admins.has(body.user_id) ? "administrator" : "member" } });
			if (name === "getBusinessConnection") return this.#json({ ok: true, result: { id: CONN, user: { id: OWNER }, is_enabled: true, rights: { can_reply: true } } });
			return this.#json({ ok: true, result: true });
		}
		if (url.startsWith("https://api.anthropic.com/v1/messages")) {
			if (this.failing.has("claude")) return this.#json({ type: "error", error: { type: "invalid_request_error", message: "boom" } }, 400);
			const text = typeof this.claude === "function" ? this.claude(body) : this.claude;
			return this.#json({
				id: "msg_1",
				type: "message",
				role: "assistant",
				model: body.model,
				content: this.stopReason === "refusal" ? [] : [{ type: "text", text }],
				stop_reason: this.stopReason,
				stop_sequence: null,
				usage: { input_tokens: 10, output_tokens: 10 },
			});
		}
		return this.#json({ message: `unexpected ${url}` }, 599);
	}
}

let updateId = 1;

export function telegramRequest(update: Record<string, unknown>, secret = "tg-secret", id = updateId++): Request {
	return new Request("https://bot.example/telegram", {
		method: "POST",
		headers: { "X-Telegram-Bot-Api-Secret-Token": secret, "Content-Type": "application/json" },
		body: JSON.stringify({ update_id: id, ...update }),
	});
}

let messageId = 100;

/** A post in a topic of Expressive Group Chat */
export function post(topic: number, text: string, extra: Record<string, unknown> = {}) {
	return {
		message_id: messageId++,
		date: 1794400000,
		chat: { id: CHAT, type: "supergroup" },
		from: { id: 42, first_name: "Ashray" },
		message_thread_id: topic,
		is_topic_message: true,
		reply_to_message: { message_id: topic, date: 1, chat: { id: CHAT, type: "supergroup" }, forum_topic_created: {} },
		text,
		...extra,
	};
}

/** A message in a private chat: with the bot, or (with a connection id) one of the owner's own chats */
export function dm(text: string | undefined, extra: Record<string, unknown> = {}) {
	return { message_id: messageId++, date: 1794400000, chat: { id: 42, type: "private" }, from: { id: 42, first_name: "Ashray" }, text, ...extra };
}
