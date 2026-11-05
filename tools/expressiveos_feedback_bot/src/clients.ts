// Thin clients for the two APIs the bot talks to. Errors never include the tokens.

import { Buffer } from "node:buffer";

export class ApiError extends Error {
	status: number;
	constructor(message: string, status: number) {
		super(message);
		this.status = status;
	}
}

export class Telegram {
	#token: string;
	constructor(token: string) {
		this.#token = token;
	}

	async call<T = unknown>(method: string, params: Record<string, unknown>): Promise<T> {
		const res = await fetch(`https://api.telegram.org/bot${this.#token}/${method}`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(params),
		});
		const data = (await res.json().catch(() => ({}))) as { ok?: boolean; result?: T; description?: string; error_code?: number };
		if (!data.ok) throw new ApiError(`Telegram ${method}: ${data.description ?? res.status}`, data.error_code ?? res.status);
		return data.result as T;
	}

	/** Downloads a file a message carries (bots may download files of up to 20 MB). */
	async download(fileId: string): Promise<Uint8Array> {
		const file = await this.call<{ file_path?: string }>("getFile", { file_id: fileId });
		if (!file.file_path) throw new ApiError("Telegram getFile: no file_path", 400);
		const res = await fetch(`https://api.telegram.org/file/bot${this.#token}/${file.file_path}`);
		if (!res.ok) throw new ApiError(`Telegram file download: ${res.status}`, res.status);
		return new Uint8Array(await res.arrayBuffer());
	}

	/** Sends text as a reply; returns the new message's id. */
	async reply(chatId: number, topic: number, replyTo: number, text: string): Promise<number> {
		const sent = await this.call<{ message_id: number }>("sendMessage", {
			chat_id: chatId,
			// Topic 1 is the chat's General topic, which takes no thread id
			...(topic > 1 ? { message_thread_id: topic } : {}),
			text,
			reply_parameters: { message_id: replyTo, allow_sending_without_reply: true },
			link_preview_options: { is_disabled: true },
		});
		return sent.message_id;
	}

	/** A reaction, best effort: the chat may not allow that emoji. */
	async react(chatId: number, messageId: number, emoji: string): Promise<void> {
		try {
			await this.call("setMessageReaction", { chat_id: chatId, message_id: messageId, reaction: [{ type: "emoji", emoji }] });
		} catch (e) {
			console.warn(String(e));
		}
	}
}

export interface Issue {
	number: number;
	body: string | null;
}

export class GitHub {
	#token: string;
	repo: string;
	constructor(token: string, repo: string) {
		this.#token = token;
		this.repo = repo;
	}

	async request<T = unknown>(method: string, path: string, body?: string | Record<string, unknown>): Promise<T> {
		const res = await fetch(`https://api.github.com/repos/${this.repo}${path}`, {
			method,
			headers: {
				Authorization: `Bearer ${this.#token}`,
				Accept: "application/vnd.github+json",
				"X-GitHub-Api-Version": "2022-11-28",
				"User-Agent": "expressiveos-feedback-bot",
				...(body === undefined ? {} : { "Content-Type": "application/json" }),
			},
			body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
		});
		if (!res.ok) throw new ApiError(`GitHub ${method} ${path}: ${res.status} ${(await res.text()).slice(0, 300)}`, res.status);
		return (res.status === 204 ? null : await res.json()) as T;
	}

	async createIssue(title: string, body: string, labels: string[]): Promise<number> {
		const issue = await this.request<Issue>("POST", "/issues", { title, body, labels });
		return issue.number;
	}

	comment(issue: number, body: string): Promise<unknown> {
		return this.request("POST", `/issues/${issue}/comments`, { body });
	}

	getIssue(issue: number): Promise<Issue> {
		return this.request<Issue>("GET", `/issues/${issue}`);
	}

	setBody(issue: number, body: string): Promise<unknown> {
		return this.request("PATCH", `/issues/${issue}`, { body });
	}

	reactToComment(commentId: number, content: "rocket" | "confused"): Promise<unknown> {
		return this.request("POST", `/issues/comments/${commentId}/reactions`, { content });
	}

	/** Commits a file to the default branch. A file already at that path (a retried update) counts as done. */
	async putFile(path: string, bytes: Uint8Array, message: string): Promise<void> {
		const encoded = path.split("/").map(encodeURIComponent).join("/");
		// Base64 has nothing JSON needs to escape, so the big string is joined, not stringified
		const body = `{"message":${JSON.stringify(message)},"content":"${Buffer.from(bytes).toString("base64")}"}`;
		try {
			await this.request("PUT", `/contents/${encoded}`, body);
		} catch (e) {
			// 422 "sha wasn't supplied": the file is there from an earlier try
			if (!(e instanceof ApiError && e.status === 422)) throw e;
		}
	}

	fileUrl(path: string): string {
		return `https://github.com/${this.repo}/blob/HEAD/${path.split("/").map(encodeURIComponent).join("/")}`;
	}
}
