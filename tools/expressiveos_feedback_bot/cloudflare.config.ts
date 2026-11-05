import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// The Telegram feedback bot: Bugs and Ideas posts in Expressive Group Chat become issues in a
// private GitHub repo, and closing or labelling an issue answers the post. See README.md.
// Deploy (and set the secrets) with ./setup.sh; later code changes deploy with `npm run deploy`.
export default defineConfig({
	worker: {
		name: "expressiveos-feedback-bot",
		compatibilityDate: "2026-10-06",
		// node:buffer, for fast base64 of attachments
		compatibilityFlags: ["nodejs_compat"],
		entrypoint,
		workersDev: true,
		observability: { enabled: true },
		env: {
			// Small JSON records only (which Telegram message belongs to which issue), no files.
			// R2 rather than KV because a record must be readable the moment it's written.
			STATE: bindings.r2({ name: "expressiveos-feedback-bot" }),
			CHAT_ID: bindings.text("-1004427242312"), // Expressive Group Chat
			BUGS_TOPIC: bindings.text("753"),
			IDEAS_TOPIC: bindings.text("751"),
			GITHUB_REPO: bindings.text("denson9874/expressiveos-feedback"),
			// GitHub logins whose "/reply <text>" issue comments the bot posts in Telegram
			REPLY_LOGINS: bindings.text("denson9874"),
			// Telegram lets a bot download files of up to 20 MB
			MAX_ATTACHMENT_MB: bindings.text("10"),
			TELEGRAM_BOT_TOKEN: bindings.secret(),
			TELEGRAM_WEBHOOK_SECRET: bindings.secret(),
			GITHUB_TOKEN: bindings.secret(),
			GITHUB_WEBHOOK_SECRET: bindings.secret(),
		},
	},
});
