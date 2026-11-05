// Everything the bot says in Telegram, in one place. The bot never writes anything else on its
// own: free text only goes out from a "/reply <text>" issue comment by a REPLY_LOGINS login.

import type { Kind } from "./env.ts";

const LOGS_LINK = "https://t.me/ExpressiveGroup/112";
const CHAT_LINK = "https://t.me/ExpressiveLauncherFeedback";

export type Missing = "phone" | "build" | "log";

const MISSING_TEXT: Record<Missing, string> = {
	phone: "your phone model",
	build: "your build date (Settings > About phone), or your Expressive Launcher version",
	log: "a log taken right after it happens: adb logcat -b all -d > log.txt",
};

/** A new bug that lacks what the pinned template asks for. Sent once, as a reply to the post. */
export function askForDetails(issue: number, missing: Missing[]): string {
	return [
		`Thanks, logged as #${issue}. To fix it we also need:`,
		...missing.map((m) => `• ${MISSING_TEXT[m]}`),
		"Just reply to your post with them.",
	].join("\n");
}

/** "ExpressiveOS 1.1, out Dec 3" from an issue's milestone. */
function release(milestone?: { title: string; due?: string }): string | null {
	if (!milestone) return null;
	return milestone.due ? `${milestone.title}, out ${milestone.due}` : milestone.title;
}

/** The issue was closed as completed. */
export function fixed(kind: Kind, milestone?: { title: string; due?: string }): string {
	const where = release(milestone);
	if (kind === "idea") {
		return where ? `✅ Added in ${where}. Thanks for the idea!` : "✅ Done. It comes in the next update. Thanks for the idea!";
	}
	return where ? `✅ Fixed in ${where}. Thanks for reporting it!` : "✅ Fixed. It comes in the next update. Thanks for reporting it!";
}

/** The issue got the "planned" label. */
export function planned(kind: Kind, milestone?: { title: string; due?: string }): string {
	const where = release(milestone);
	if (kind === "idea") {
		return where ? `📌 Planned for ${where}. Thanks for the idea!` : "📌 Planned for an upcoming update. Thanks for the idea!";
	}
	return where ? `📌 We're on it: planned for ${where}.` : "📌 We're on it: planned for an upcoming update.";
}

/** The issue got the "needs-logs" label. */
export const NEEDS_LOGS =
	"To track this down we need a log. Right after it happens, run adb logcat -b all -d > log.txt " +
	`and reply to your post with the file. Which logs each problem needs: ${LOGS_LINK}`;

/** Anyone who messages the bot directly. */
export const DM_POINTER =
	"Hi! I log bugs and ideas for ExpressiveOS and Expressive Launcher. " +
	`Post them in the Bugs or Ideas topic of Expressive Group Chat: ${CHAT_LINK}`;

/** For admins: answers to /track. */
export const TRACK_HOW = "Reply /track to the message you want to log (/track idea logs it as an idea).";
export const tracked = (issue: number, kind: Kind) => `Logged as #${issue} (${kind}).`;
export const alreadyLogged = (issue: number) => `Already logged as #${issue}.`;
