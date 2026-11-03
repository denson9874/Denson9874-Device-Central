// The install as a list of steps, worked out before the phone is touched: what `fastboot -w update`
// would do with the release's fastboot-info.txt, plus ExpressiveOS's own choices (root or not).

import { type InfoTask, parseFastbootInfo } from "../fastboot/fastboot-info.ts";
import { isLogical } from "../fastboot/lp.ts";

/** The image of a flash step: an entry of the zip, or the release's stock (no-root) init_boot. */
export type ImageRef = { kind: "zip"; name: string } | { kind: "stock-init-boot" };

export type Step =
	| { kind: "set-active" }
	| { kind: "cancel-snapshot" }
	| { kind: "flash"; partition: string; image: ImageRef; slot: "current" | "other"; logical: boolean }
	| { kind: "reboot"; target: "fastbootd" | "bootloader" }
	| { kind: "update-super"; wipe: boolean }
	| { kind: "resize-to-zero"; partitions: string[] }
	| { kind: "erase"; partition: string }
	| { kind: "flash-super"; partitions: Array<{ partition: string; image: string }> }
	| { kind: "start-android" };

export type FlashSuperStep = Extract<Step, { kind: "flash-super" }>;

export interface PlanOptions {
	/** Erase userdata and metadata (fastboot -w): a clean install. */
	wipe: boolean;
	/** Keep the zip's KernelSU Next init_boot; false writes the stock one to both slots. */
	root: boolean;
	/** Whether the release has a stock init_boot (it has root only when it does). */
	hasStockInitBoot: boolean;
	/**
	 * Write the dynamic partitions into super whole from the bootloader, as AOSP fastboot does
	 * when it can (OptimizedFlashSuperTask), instead of restarting into fastbootd for them.
	 */
	superFlash?: boolean;
}

export class PlanError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "PlanError";
	}
}

// When a zip has no fastboot-info.txt: AOSP's built-in order (boot images, then the super partition's)
const BOOT_IMAGES = ["boot", "init_boot", "dtbo", "dt", "vendor_kernel_boot", "recovery", "pvmfw", "vendor_boot", "vbmeta", "vbmeta_system", "vbmeta_vendor"];
const OS_IMAGES = ["odm", "odm_dlkm", "product", "system", "system_dlkm", "system_ext", "vendor", "vendor_dlkm"];

function defaultTasks(has: (name: string) => boolean, wipe: boolean): InfoTask[] {
	const t: InfoTask[] = [];
	for (const p of BOOT_IMAGES) if (has(`${p}.img`)) t.push({ kind: "flash", partition: p, image: `${p}.img`, applyVbmeta: false, otherSlot: false });
	if (has("super_empty.img")) t.push({ kind: "reboot", target: "fastboot" }, { kind: "update-super" });
	for (const p of OS_IMAGES) if (has(`${p}.img`)) t.push({ kind: "flash", partition: p, image: `${p}.img`, applyVbmeta: false, otherSlot: false });
	if (wipe) t.push({ kind: "erase", partition: "userdata", ifWipe: true }, { kind: "erase", partition: "metadata", ifWipe: true });
	return t;
}

/**
 * Builds the steps.
 * @param fastbootInfo the zip's fastboot-info.txt, or null when it has none
 * @param has whether the zip holds a file
 * @param logical super_empty.img's partition names (null: unknown, fastbootd is asked instead)
 */
export function buildPlan(fastbootInfo: string | null, has: (name: string) => boolean, logical: string[] | null, opts: PlanOptions): Step[] {
	if (!has("android-info.txt")) throw new PlanError("The zip has no android-info.txt, so there's no way to check it's for this phone");
	if (!opts.root && !opts.hasStockInitBoot) throw new PlanError("This build has no stock init_boot, so it can't be installed without root");
	const tasks = fastbootInfo !== null ? parseFastbootInfo(fastbootInfo, opts.wipe) : defaultTasks(has, opts.wipe);
	const isDynamic = (p: string) => (logical ? isLogical(logical, p) : OS_IMAGES.includes(p));

	const steps: Step[] = [{ kind: "set-active" }, { kind: "cancel-snapshot" }];
	const erased = new Set<string>();
	let sawInitBoot = false;
	for (const t of tasks) {
		switch (t.kind) {
			case "flash": {
				if (!has(t.image)) {
					throw new PlanError(`fastboot-info.txt writes ${t.partition} from ${t.image}, which isn't in the zip`);
				}
				let image: ImageRef = { kind: "zip", name: t.image };
				if (t.partition === "init_boot" && !t.otherSlot) {
					sawInitBoot = true;
					if (!opts.root) image = { kind: "stock-init-boot" };
				}
				steps.push({ kind: "flash", partition: t.partition, image, slot: t.otherSlot ? "other" : "current", logical: isDynamic(t.partition) });
				break;
			}
			case "reboot":
				if (t.target === "fastboot") steps.push({ kind: "reboot", target: "fastbootd" });
				else if (t.target === "bootloader") steps.push({ kind: "reboot", target: "bootloader" });
				else throw new PlanError(`fastboot-info.txt restarts the phone into ${t.target || "Android"} part way through, which this installer doesn't do`);
				break;
			case "update-super":
				if (!has("super_empty.img")) break; // fastboot skips it too
				steps.push({ kind: "update-super", wipe: opts.wipe });
				break;
			case "erase":
				if (!t.ifWipe) throw new PlanError(`fastboot-info.txt erases ${t.partition} even without a wipe, which this installer doesn't do`);
				erased.add(t.partition);
				steps.push({ kind: "erase", partition: t.partition });
				break;
		}
	}
	if (!sawInitBoot && !opts.root) {
		throw new PlanError("fastboot-info.txt doesn't write init_boot, so the no-root choice can't be applied");
	}

	// OptimizedFlashSuperTask::Initialize: when the steps restart into fastbootd, lay out super and
	// write a logical partition (CanOptimize), the restarts into fastbootd, the layout and the
	// logical partitions' writes become one write of super, after everything else
	if (opts.superFlash) {
		const logicalFlash = (s: Step | undefined): s is Extract<Step, { kind: "flash" }> => s?.kind === "flash" && s.logical;
		const pattern = steps.some((s, i) => s.kind === "reboot" && s.target === "fastbootd" && steps[i + 1]?.kind === "update-super" && logicalFlash(steps[i + 2]));
		const logical = steps.filter(logicalFlash);
		const partitions = logical.flatMap((s) => (s.slot === "current" && s.image.kind === "zip" ? [{ partition: s.partition, image: s.image.name }] : []));
		if (pattern && partitions.length === logical.length) {
			const kept = steps.filter((s) => !(s.kind === "reboot" && s.target === "fastbootd") && s.kind !== "update-super" && !logicalFlash(s));
			steps.splice(0, steps.length, ...kept, { kind: "flash-super", partitions });
		}
	}

	// Before the first logical partition is written, every logical partition the plan writes is
	// shrunk to nothing so each gets laid out afresh (AddResizeTasks in fastboot.cpp)
	const firstLogical = steps.findIndex((s) => s.kind === "flash" && s.logical);
	if (firstLogical >= 0) {
		const parts = [...new Set(steps.flatMap((s) => (s.kind === "flash" && s.logical && s.slot === "current" ? [s.partition] : [])))];
		steps.splice(firstLogical, 0, { kind: "resize-to-zero", partitions: parts });
	}

	// fastboot -w also wipes userdata and metadata after the update (cache too; Pixels have none).
	// Each erase must work, as in fastboot, which stops when one fails
	if (opts.wipe) {
		for (const p of ["userdata", "metadata"]) if (!erased.has(p)) steps.push({ kind: "erase", partition: p });
	}
	// No root: the stock init_boot on the other slot too, as the release notes say for both slots
	if (!opts.root) steps.push({ kind: "flash", partition: "init_boot", image: { kind: "stock-init-boot" }, slot: "other", logical: false });
	steps.push({ kind: "start-android" });
	return steps;
}

/** A short description of a step for the install list. */
export function describe(s: Step): string {
	switch (s.kind) {
		case "set-active":
			return "Make the current slot active";
		case "cancel-snapshot":
			return "Cancel any unfinished system update";
		case "flash": {
			const what = s.image.kind === "stock-init-boot" ? `${s.partition} (no root)` : s.partition === "init_boot" ? "init_boot (KernelSU Next)" : s.partition;
			return s.slot === "other" ? `Write ${what} to the other slot` : `Write ${what}`;
		}
		case "reboot":
			return s.target === "fastbootd" ? "Restart into fastbootd" : "Restart into the bootloader";
		case "update-super":
			return s.wipe ? "Lay out the dynamic partitions afresh" : "Update the dynamic partition layout";
		case "resize-to-zero":
			return "Make room for the system images";
		case "erase":
			return `Erase ${s.partition}`;
		case "flash-super":
			return `Write ${s.partitions.map((p) => p.partition).join(", ")} into super`;
		case "start-android":
			return "Start ExpressiveOS";
	}
}
