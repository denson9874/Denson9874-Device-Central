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

/** Confirmation when a held bug report is logged after the author replies with or edits in a log. */
export function loggedWithLog(issue: number, missing: Missing[]): string {
	return missing.length ? askForDetails(issue, missing) : `Thanks, logged as #${issue}.`;
}

/** Warning 1..(maxStrikes - 1) when someone posts a bug report in Bugs (753) without logs. */
export function missingLogWarning(strike: number, maxStrikes: number, muteHours: number): string {
	return [
		`⚠️ Warning ${strike}/${maxStrikes}: Bug reports in this topic must include logs.`,
		"",
		"Right after the problem happens, capture a log with:",
		"• PC: adb logcat -b all -d > log.txt",
		"• Root on phone: su -c \"logcat -b all -d > /sdcard/log.txt\"",
		`Which logs each problem needs: ${LOGS_LINK}`,
		"",
		`Reply to your post with the log file (or a paste link) to open your report. Posting ${maxStrikes} bug reports without logs mutes your posts for ${muteHours} hours.`,
	].join("\n");
}

/** Strike maxStrikes: user hit the missing-log limit and is muted for muteHours. */
export function mutedForMissingLogs(maxStrikes: number, muteHours: number, restricted: boolean): string {
	const action = restricted
		? `so your posts have been muted for ${muteHours} hours.`
		: `(mute threshold of ${muteHours} hours reached).`;
	return [
		`🔇 Warning ${maxStrikes}/${maxStrikes}: You reported ${maxStrikes} bugs without logs, ${action}`,
		"",
		`Once unmuted, attach a log file (adb logcat -b all -d > log.txt) or paste link with every bug report: ${LOGS_LINK}`,
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

/** For admins: answers to /track and /unwarn. */
export const TRACK_HOW = "Reply /track to the message you want to log (/track idea logs it as an idea).";
export const UNWARN_HOW = "Reply /unwarn to a member's message to clear their missing-log warnings.";
export const tracked = (issue: number, kind: Kind) => `Logged as #${issue} (${kind}).`;
export const alreadyLogged = (issue: number) => `Already logged as #${issue}.`;
export const unwarned = (name: string) => `Cleared missing-log warnings for ${name}.`;
