// The helpdesk bot's Worker:
//   POST /telegram   Telegram's webhook (checked against TELEGRAM_WEBHOOK_SECRET)
//   GET  /           a health check for setup.sh

import { Telegram } from "./clients.ts";
import type { BotEnv } from "./env.ts";
import { handleTelegram } from "./telegram.ts";

export default {
	async fetch(request: Request, env: BotEnv): Promise<Response> {
		const { pathname } = new URL(request.url);
		if (request.method === "GET" && pathname === "/") return new Response("Expressive Helpdesk bot\n");
		if (request.method === "GET" && pathname === "/health") {
			const tg = new Telegram(env.TELEGRAM_BOT_TOKEN);
			const [me, member] = await Promise.all([
				tg.call<{ username?: string }>("getMe", {}),
				tg.call<{ status?: string }>("getChatMember", { chat_id: Number(env.CHAT_ID), user_id: tg.id }),
			]);
			return Response.json({
				ok: true,
				bot: me.username ? `@${me.username}` : null,
				status: member.status ?? null,
			});
		}
		if (request.method === "POST" && pathname === "/telegram") return handleTelegram(request, env);
		return new Response("Not Found", { status: 404 });
	},
};
