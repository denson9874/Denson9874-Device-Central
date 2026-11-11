// The helpdesk bot's Worker:
//   POST /telegram   Telegram's webhook (checked against TELEGRAM_WEBHOOK_SECRET)
//   GET  /           a health check for setup.sh

import type { BotEnv } from "./env.ts";
import { handleTelegram } from "./telegram.ts";

export default {
	async fetch(request: Request, env: BotEnv): Promise<Response> {
		const { pathname } = new URL(request.url);
		if (request.method === "GET" && pathname === "/") return new Response("Expressive Helpdesk bot\n");
		if (request.method === "POST" && pathname === "/telegram") return handleTelegram(request, env);
		return new Response("Not Found", { status: 404 });
	},
};
