// The feedback bot's Worker:
//   POST /telegram   Telegram's webhook (checked against TELEGRAM_WEBHOOK_SECRET)
//   POST /github     the feedback repo's webhook for issues and issue comments (HMAC with GITHUB_WEBHOOK_SECRET)
//   GET  /           a health check for setup.sh

import { Telegram } from "./clients.ts";
import type { BotEnv } from "./env.ts";
import { handleGitHub } from "./github.ts";
import { handleTelegram } from "./telegram.ts";

export default {
	async fetch(request: Request, env: BotEnv): Promise<Response> {
		const { pathname } = new URL(request.url);
		if (request.method === "GET" && pathname === "/") return new Response("ExpressiveOS feedback bot\n");
		if (request.method === "GET" && pathname === "/health") {
			const tg = new Telegram(env.TELEGRAM_BOT_TOKEN);
			const botId = Number(env.TELEGRAM_BOT_TOKEN.split(":")[0]);
			const [me, member] = await Promise.all([
				tg.call<{ username?: string }>("getMe", {}),
				tg.call<{ status?: string; can_restrict_members?: boolean }>("getChatMember", {
					chat_id: Number(env.CHAT_ID),
					user_id: botId,
				}),
			]);
			return Response.json({
				ok: true,
				bot: me.username ? `@${me.username}` : null,
				status: member.status ?? null,
				can_restrict_members: member.status === "creator" || Boolean(member.can_restrict_members),
			});
		}
		if (request.method === "POST" && pathname === "/telegram") return handleTelegram(request, env);
		if (request.method === "POST" && pathname === "/github") return handleGitHub(request, env);
		return new Response("Not Found", { status: 404 });
	},
};
