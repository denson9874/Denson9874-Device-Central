// A fake Telegram, GitHub and R2 for the tests: fetch is replaced, every call is recorded.

import type { BotEnv, Bucket } from "../src/env.ts";

export const CHAT = -1004427242312;
export const BUGS = 753;
export const IDEAS = 751;

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
	method: string;
	url: string;
	body: any;
}

export class World {
	calls: Call[] = [];
	issues = new Map<number, { title: string; body: string; labels: string[]; comments: string[] }>();
	files = new Map<string, string>();
	admins = new Set<number>();
	nextIssue = 1;
	nextMessage = 9000;
	/** Methods or paths that fail, for retry tests */
	failing = new Set<string>();
	bucket = new MemoryBucket();
	env: BotEnv = {
		STATE: this.bucket,
		CHAT_ID: String(CHAT),
		BUGS_TOPIC: String(BUGS),
		IDEAS_TOPIC: String(IDEAS),
		GITHUB_REPO: "denson9874/expressiveos-feedback",
		REPLY_LOGINS: "denson9874",
		MAX_ATTACHMENT_MB: "10",
		TELEGRAM_BOT_TOKEN: "123:token",
		TELEGRAM_WEBHOOK_SECRET: "tg-secret",
		GITHUB_TOKEN: "gh-token",
		GITHUB_WEBHOOK_SECRET: "gh-secret",
	};
	#realFetch = globalThis.fetch;

	install() {
		globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => this.#handle(String(input), init ?? {})) as typeof fetch;
		return this;
	}
	uninstall() {
		globalThis.fetch = this.#realFetch;
	}

	/** Telegram methods called, in order */
	tg(method?: string): Call[] {
		return this.calls.filter((c) => c.url.includes("api.telegram.org/bot") && (!method || c.url.endsWith(`/${method}`)));
	}
	gh(method?: string, path?: RegExp): Call[] {
		return this.calls.filter((c) => c.url.startsWith("https://api.github.com/") && (!method || c.method === method) && (!path || path.test(c.url)));
	}

	#json(value: unknown, status = 200) {
		return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
	}

	async #handle(url: string, init: RequestInit): Promise<Response> {
		const method = init.method ?? "GET";
		let body: any = init.body;
		if (typeof body === "string") {
			try {
				body = JSON.parse(body);
			} catch {}
		}
		this.calls.push({ method, url, body });

		const tg = /^https:\/\/api\.telegram\.org\/bot[^/]+\/(\w+)$/.exec(url);
		if (tg) {
			const name = tg[1];
			if (this.failing.has(name)) return this.#json({ ok: false, error_code: 500, description: "Internal" }, 500);
			if (name === "getFile") {
				if (body.file_id === "huge") return this.#json({ ok: false, error_code: 400, description: "Bad Request: file is too big" }, 400);
				return this.#json({ ok: true, result: { file_path: `files/${body.file_id}` } });
			}
			if (name === "sendMessage") return this.#json({ ok: true, result: { message_id: this.nextMessage++ } });
			if (name === "getChatMember") return this.#json({ ok: true, result: { status: this.admins.has(body.user_id) ? "administrator" : "member" } });
			return this.#json({ ok: true, result: true });
		}
		if (url.startsWith("https://api.telegram.org/file/")) return new Response(new Uint8Array([104, 105]));

		const gh = /^https:\/\/api\.github\.com\/repos\/denson9874\/expressiveos-feedback(\/.*)$/.exec(url);
		if (gh) {
			const path = gh[1];
			if (this.failing.has(path) || this.failing.has(`${method} ${path.split("/")[1]}`)) return this.#json({ message: "boom" }, 502);
			if (method === "POST" && path === "/issues") {
				const n = this.nextIssue++;
				this.issues.set(n, { title: body.title, body: body.body, labels: body.labels, comments: [] });
				return this.#json({ number: n, body: body.body }, 201);
			}
			let m = /^\/issues\/(\d+)\/comments$/.exec(path);
			if (m && method === "POST") {
				this.issues.get(Number(m[1]))!.comments.push(body.body);
				return this.#json({ id: 1 }, 201);
			}
			m = /^\/issues\/(\d+)$/.exec(path);
			if (m && method === "GET") return this.#json({ number: Number(m[1]), body: this.issues.get(Number(m[1]))!.body });
			if (m && method === "PATCH") {
				this.issues.get(Number(m[1]))!.body = body.body;
				return this.#json({ number: Number(m[1]) });
			}
			m = /^\/contents\/(.+)$/.exec(path);
			if (m && method === "PUT") {
				const p = decodeURIComponent(m[1]);
				if (this.files.has(p)) return this.#json({ message: '"sha" wasn\'t supplied' }, 422);
				this.files.set(p, body.content);
				return this.#json({}, 201);
			}
			if (/^\/issues\/comments\/\d+\/reactions$/.test(path)) return this.#json({}, 201);
		}
		return this.#json({ message: `unexpected ${method} ${url}` }, 599);
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
export function post(topic: number, fields: Record<string, unknown> = {}): Record<string, any> {
	return {
		message_id: messageId++,
		date: Date.UTC(2026, 10, 5, 9, 30) / 1000, // 4:30 AM ET
		chat: { id: CHAT, type: "supergroup", title: "Expressive Group Chat", username: "ExpressiveLauncherFeedback" },
		from: { id: 42, first_name: "Ashray", username: "ashray" },
		is_topic_message: true,
		message_thread_id: topic,
		reply_to_message: { message_id: topic, forum_topic_created: { name: "Topic" }, chat: { id: CHAT } },
		...fields,
	};
}

export async function githubRequest(event: string, payload: Record<string, unknown>, secret = "gh-secret"): Promise<Request> {
	const raw = JSON.stringify({ repository: { full_name: "denson9874/expressiveos-feedback" }, ...payload });
	const enc = new TextEncoder();
	const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(raw)));
	const sig = `sha256=${[...mac].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
	return new Request("https://bot.example/github", {
		method: "POST",
		headers: { "X-GitHub-Event": event, "X-Hub-Signature-256": sig, "Content-Type": "application/json" },
		body: raw,
	});
}
