import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// Expressive Helpdesk: the Telegram bot @expressive_helpdesk_bot answers questions about ExpressiveOS
// and Expressive Launcher with Claude. See README.md.
// Deploy (and set the secrets) with ./setup.sh; later code changes deploy with `npm run deploy`.
export default defineConfig({
	worker: {
		name: "expressiveos-helpdesk-bot",
		compatibilityDate: "2026-10-06",
		compatibilityFlags: ["nodejs_compat"],
		entrypoint,
		workersDev: true,
		observability: { enabled: true },
		env: {
			// Small JSON records only: recent turns per chat, counters, the on/off switch.
			STATE: bindings.r2({ name: "expressiveos-helpdesk-bot" }),
			CHAT_ID: bindings.text("-1004427242312"), // Expressive Group Chat
			// ROM Support, Launcher Support, Install & Updates. Bugs (753) and Ideas (751) belong to the feedback bot.
			SUPPORT_TOPICS: bindings.text("755,754,752"),
			MODEL: bindings.text("claude-sonnet-5-5"),
			// Spending guards: answers per person per hour, and answers per day in total
			MAX_REPLIES_PER_USER_HOUR: bindings.text("10"),
			MAX_REPLIES_PER_DAY: bindings.text("300"),
			// In Daryl's own chats the bot stays quiet this long after he writes there himself
			OWNER_QUIET_HOURS: bindings.text("12"),
			TELEGRAM_BOT_TOKEN: bindings.secret(),
			TELEGRAM_WEBHOOK_SECRET: bindings.secret(),
			ANTHROPIC_API_KEY: bindings.secret(),
		},
	},
});
