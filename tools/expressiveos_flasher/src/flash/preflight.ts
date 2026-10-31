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
	/** android-info.txt lines that couldn't be read. */
	requirementErrors: string[];
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
	};
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
