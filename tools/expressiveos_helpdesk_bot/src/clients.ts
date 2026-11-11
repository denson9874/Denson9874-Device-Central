// Thin clients for the two APIs the bot talks to. Errors never include the tokens.

import Anthropic from "@anthropic-ai/sdk";

export class ApiError extends Error {
	status: number;
	constructor(message: string, status: number) {
		super(message);
		this.status = status;
	}
}

export interface SendOptions {
	/** Topic of a forum chat; 0 or 1 (General) sends no thread id */
	topic?: number;
	replyTo?: number;
	/** Set to answer inside one of the owner's own chats (Telegram Business) */
	business?: string;
}

export class Telegram {
	#token: string;
	/** The bot's own user id: the part of the token before the colon */
	id: number;
	constructor(token: string) {
		this.#token = token;
		this.id = Number(token.split(":")[0]);
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

	#where(chatId: number, o: SendOptions): Record<string, unknown> {
		return {
			chat_id: chatId,
			...(o.business ? { business_connection_id: o.business } : {}),
			...(o.topic && o.topic > 1 ? { message_thread_id: o.topic } : {}),
		};
	}

	/** Sends plain text; returns the new message's id. */
	async send(chatId: number, text: string, o: SendOptions = {}): Promise<number> {
		const sent = await this.call<{ message_id: number }>("sendMessage", {
			...this.#where(chatId, o),
			text,
			...(o.replyTo ? { reply_parameters: { message_id: o.replyTo, allow_sending_without_reply: true } } : {}),
			link_preview_options: { is_disabled: true },
		});
		return sent.message_id;
	}

	/** "typing…" while Claude answers. Best effort. */
	async typing(chatId: number, o: SendOptions = {}): Promise<void> {
		try {
			await this.call("sendChatAction", { ...this.#where(chatId, o), action: "typing" });
		} catch (e) {
			console.warn(String(e));
		}
	}
}

export interface Turn {
	r: "user" | "assistant";
	c: string;
}

/** Asks Claude; returns the answer's text, or null when Claude declined or said nothing. */
export async function askClaude(apiKey: string, model: string, system: string, turns: Turn[]): Promise<string | null> {
	const client = new Anthropic({ apiKey, maxRetries: 1, timeout: 40_000 });
	const response = await client.beta.messages.create({
		model,
		max_tokens: 4000,
		system,
		// Short support answers: low effort keeps them quick and cheap
		output_config: { effort: "low" },
		// If the model's safety checks decline a message, a fallback model gets one try
		betas: ["server-side-fallback-2026-07-01"],
		fallbacks: "default",
		messages: turns.map((t) => ({ role: t.r, content: t.c })),
	});
	if (response.stop_reason === "refusal") return null;
	const text = response.content
		.filter((b) => b.type === "text")
		.map((b) => b.text)
		.join("")
		.trim();
	return text || null;
}
