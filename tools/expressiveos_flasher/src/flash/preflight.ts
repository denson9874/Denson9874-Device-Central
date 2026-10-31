// What the phone says about itself before anything is written, and unlocking its bootloader.

import { type RequirementResult, checkRequirements, parseRequirements } from "../fastboot/android-info.ts";
import { FastbootError } from "../fastboot/client.ts";
import type { Phone } from "../fastboot/device.ts";

export interface PhoneReport {
	product: string | null;
	serial: string | null;
	unlocked: boolean | null;
	mode: "bootloader" | "fastbootd";
	currentSlot: string | null;
	bootloader: string | null;
	baseband: string | null;
	/** android-info.txt's requirements, each checked. */
	requirements: RequirementResult[];
	/**
	 * android-info.txt lines that couldn't be read. As in fastboot, they're a warning and don't
	 * stop the install (they aren't among reportProblems' problems).
	 */
	requirementErrors: string[];
	/** Whether there was an android-info.txt to check. */
	androidInfo: boolean;
}

export async function inspectPhone(phone: Phone, androidInfo: string | null): Promise<PhoneReport> {
	const g = (n: string) => phone.getVar(n);
	const unlocked = await g("unlocked");
	const parsed = androidInfo ? parseRequirements(androidInfo) : { requirements: [], errors: [] };
	return {
		product: await g("product"),
		serial: (await g("serialno")) ?? (phone.serial || null),
		unlocked: unlocked === null ? null : unlocked === "yes",
		mode: await phone.mode(),
		currentSlot: (await g("current-slot"))?.replace(/^_/, "") ?? null,
		bootloader: await g("version-bootloader"),
		baseband: await g("version-baseband"),
		requirements: await checkRequirements(parsed.requirements, g),
		requirementErrors: parsed.errors,
		androidInfo: androidInfo !== null,
	};
}

/** Why a phone can't take a build. */
export type Problem =
	/** It's another model. */
	| { kind: "product"; product: string | null }
	/**
	 * Asked for its model, it answered something that isn't one: what a phone still holding the
	 * reply to an earlier command gives (Chrome on Windows can't reset it).
	 */
	| { kind: "unexpected"; product: string | null }
	/** The build's zip has no android-info.txt to check it against. */
	| { kind: "no-android-info" }
	/** A line of android-info.txt it doesn't meet. */
	| { kind: "requirement"; result: RequirementResult }
	/** Its bootloader is locked. */
	| { kind: "locked" };

// What the bootloader and fastbootd answer to the other variables this page reads
const NOT_A_PRODUCT = new Set(["yes", "no", "raw", "ext4", "f2fs", "super", "none", "snapshotted", "merging"]);

/**
 * Whether the phone's answer for "product" looks like a codename (cheetah, sdm845_64), and not the
 * answer to another variable: yes or no, a slot letter, a size, a serial number or a version.
 */
export function plausibleProduct(product: string | null): boolean {
	return !!product && /^[a-z][a-z0-9_]+$/.test(product) && !NOT_A_PRODUCT.has(product);
}

/**
 * What in this report stops the phone taking a build for `codename` (the bootloader lock aside).
 * Lines of android-info.txt that can't be read aren't among them: fastboot only warns of those.
 */
export function reportProblems(r: PhoneReport, codename: string): Problem[] {
	if (!plausibleProduct(r.product)) return [{ kind: "unexpected", product: r.product }];
	if (r.product !== codename) return [{ kind: "product", product: r.product }];
	if (!r.androidInfo) return [{ kind: "no-android-info" }];
	return r.requirements.filter((x) => !x.ok && !x.skipped).map((result): Problem => ({ kind: "requirement", result }));
}

/**
 * Reads the phone again right before an install and checks it against the android-info.txt of
 * the zip about to be written, as AOSP's flashall does (CheckRequirements, before set_active).
 * Nothing may be written unless this comes back empty. A line that can't be read doesn't count,
 * as in CheckRequirements.
 */
export async function checkBeforeInstall(phone: Phone, androidInfo: string | null, codename: string): Promise<Problem[]> {
	const report = await inspectPhone(phone, androidInfo);
	const out = reportProblems(report, codename);
	// After an unexpected answer, what it says about its lock can't be trusted either
	if (report.unlocked === false && !out.some((p) => p.kind === "unexpected")) out.push({ kind: "locked" });
	return out;
}

/** The board a zip is for, from its "require board=" line. */
export function requiredBoards(androidInfo: string): string[] {
	const { requirements } = parseRequirements(androidInfo);
	return requirements.filter((r) => r.name === "product" && !r.invert && !r.product).flatMap((r) => r.options);
}

/** Whether "OEM unlocking" is on in the phone's Developer options (null if it can't tell). */
export async function canUnlock(phone: Phone): Promise<boolean | null> {
	try {
		const r = await phone.command("flashing get_unlock_ability");
		const m = /get_unlock_ability:\s*(\d)/.exec([...r.info, r.text].join("\n"));
		return m ? m[1] === "1" : null;
	} catch (e) {
		if (e instanceof FastbootError) return null;
		throw e;
	}
}

/**
 * Asks the phone to unlock: it shows a prompt the user answers with the volume and power keys,
 * and the reply comes once they have. Unlocking erases the phone.
 */
export async function unlockBootloader(phone: Phone): Promise<"unlocked" | "refused"> {
	try {
		await phone.command("flashing unlock", { timeoutMs: 0 });
	} catch (e) {
		if (e instanceof FastbootError) return "refused";
		throw e;
	}
	return "unlocked";
}
