// fastboot-info.txt: the build's own flashing steps, read as AOSP fastboot reads them
// (ParseFastbootInfo in fastboot.cpp, version 1):
//   version 1
//   flash [--apply-vbmeta] [--slot-other] <partition> [<image file>]
//   reboot [fastboot|bootloader|recovery]
//   update-super
//   if-wipe erase <partition>
// Lines starting with # are comments; "if-wipe" lines only count when data is being erased.

export type InfoTask =
	| { kind: "flash"; partition: string; image: string; applyVbmeta: boolean; otherSlot: boolean }
	| { kind: "reboot"; target: "" | "fastboot" | "bootloader" | "recovery" }
	| { kind: "update-super" }
	| { kind: "erase"; partition: string; ifWipe: boolean };

export const FASTBOOT_INFO_VERSION = 1;

export class FastbootInfoError extends Error {
	constructor(message: string) {
		super(`fastboot-info.txt: ${message}`);
		this.name = "FastbootInfoError";
	}
}

export function parseFastbootInfo(text: string, wantsWipe: boolean): InfoTask[] {
	const tasks: InfoTask[] = [];
	for (const raw of text.split("\n")) {
		let words = raw.replace(/\r$/, "").split(" ").filter((w) => w.length > 0);
		if (!words.length || words[0].startsWith("#")) continue;
		if (words.length > 1 && words[0] === "version") {
			if (words.length !== 2 || !/^\d+$/.test(words[1])) throw new FastbootInfoError(`bad version line "${raw}"`);
			if (Number(words[1]) > FASTBOOT_INFO_VERSION) throw new FastbootInfoError(`version ${words[1]} is newer than this installer understands`);
			continue;
		}
		let ifWipe = false;
		if (words.length >= 2 && words[0] === "if-wipe") {
			if (!wantsWipe) continue;
			ifWipe = true;
			words = words.slice(1);
		}
		const [cmd, ...args] = words;
		if (cmd === "flash") {
			let applyVbmeta = false;
			let otherSlot = false;
			let partition = "";
			let image = "";
			for (const a of args) {
				if (a === "--apply-vbmeta") applyVbmeta = true;
				else if (a === "--slot-other") otherSlot = true;
				else if (!partition) partition = a;
				else if (!image) image = a;
				else throw new FastbootInfoError(`unknown argument "${a}" in "${raw}"`);
			}
			if (!partition) throw new FastbootInfoError(`no partition in "${raw}"`);
			if (!/^[A-Za-z0-9_]+$/.test(partition)) throw new FastbootInfoError(`bad partition name in "${raw}"`);
			tasks.push({ kind: "flash", partition, image: image || `${partition}.img`, applyVbmeta, otherSlot });
		} else if (cmd === "reboot") {
			if (args.length > 1) throw new FastbootInfoError(`unknown arguments in "${raw}"`);
			const target = args[0] ?? "";
			if (target !== "" && target !== "fastboot" && target !== "bootloader" && target !== "recovery")
				throw new FastbootInfoError(`unknown reboot target in "${raw}"`);
			tasks.push({ kind: "reboot", target });
		} else if (cmd === "update-super" && args.length === 0) {
			tasks.push({ kind: "update-super" });
		} else if (cmd === "erase" && args.length === 1) {
			if (!/^[A-Za-z0-9_]+$/.test(args[0])) throw new FastbootInfoError(`bad partition name in "${raw}"`);
			tasks.push({ kind: "erase", partition: args[0], ifWipe });
		} else {
			throw new FastbootInfoError(`unknown command "${raw.trim()}"`);
		}
	}
	return tasks;
}
