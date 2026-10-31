import { describe, expect, it } from "vitest";
import { PlanError, buildPlan, describe as describeStep } from "../src/flash/plan.ts";

const INFO = `version 1
flash boot
flash init_boot
flash dtbo
flash vendor_kernel_boot
flash --apply-vbmeta vbmeta
flash vbmeta_system
reboot fastboot
update-super
flash product
flash system
flash vendor
if-wipe erase userdata
if-wipe erase metadata
`;
const FILES = new Set(["android-info.txt", "fastboot-info.txt", "boot.img", "init_boot.img", "dtbo.img", "vendor_kernel_boot.img", "vbmeta.img", "vbmeta_system.img", "super_empty.img", "product.img", "system.img", "vendor.img"]);
const has = (n: string) => FILES.has(n);
const LOGICAL = ["product_a", "product_b", "system_a", "system_b", "vendor_a", "vendor_b"];

const kinds = (s: ReturnType<typeof buildPlan>) => s.map((x) => (x.kind === "flash" ? `flash ${x.partition}${x.slot === "other" ? " other" : ""}${x.image.kind === "stock-init-boot" ? " stock" : ""}${x.logical ? " logical" : ""}` : x.kind === "erase" ? `erase ${x.partition}` : x.kind === "reboot" ? `reboot ${x.target}` : x.kind));

describe("install plan", () => {
	it("follows fastboot-info.txt, root, clean install", () => {
		expect(kinds(buildPlan(INFO, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: true }))).toEqual([
			"set-active",
			"cancel-snapshot",
			"flash boot",
			"flash init_boot",
			"flash dtbo",
			"flash vendor_kernel_boot",
			"flash vbmeta",
			"flash vbmeta_system",
			"reboot fastbootd",
			"update-super",
			"resize-to-zero",
			"flash product logical",
			"flash system logical",
			"flash vendor logical",
			"erase userdata",
			"erase metadata",
			"start-android",
		]);
	});

	it("writes the stock init_boot to both slots without root", () => {
		const steps = buildPlan(INFO, has, LOGICAL, { wipe: false, root: false, hasStockInitBoot: true });
		const k = kinds(steps);
		expect(k).toContain("flash init_boot stock");
		expect(k).toContain("flash init_boot other stock");
		expect(k.some((x) => x.startsWith("erase"))).toBe(false);
		expect(steps.find((s) => s.kind === "update-super")).toEqual({ kind: "update-super", wipe: false });
		expect(k[k.length - 1]).toBe("start-android");
	});

	it("only shrinks the current slot's logical partitions", () => {
		const r = buildPlan(INFO, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false }).find((s) => s.kind === "resize-to-zero");
		expect(r).toEqual({ kind: "resize-to-zero", partitions: ["product", "system", "vendor"] });
	});

	it("uses AOSP's order without fastboot-info.txt", () => {
		const k = kinds(buildPlan(null, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false }));
		expect(k.slice(0, 4)).toEqual(["set-active", "cancel-snapshot", "flash boot", "flash init_boot"]);
		expect(k).toContain("reboot fastbootd");
		expect(k).toContain("flash system logical");
		expect(k.slice(-3)).toEqual(["erase userdata", "erase metadata", "start-android"]);
	});

	it("refuses what it can't do", () => {
		expect(() => buildPlan(INFO, (n) => n !== "android-info.txt" && has(n), LOGICAL, { wipe: true, root: true, hasStockInitBoot: true })).toThrow(PlanError);
		expect(() => buildPlan(INFO, (n) => n !== "vendor.img" && has(n), LOGICAL, { wipe: true, root: true, hasStockInitBoot: true })).toThrow(/vendor\.img/);
		expect(() => buildPlan(INFO, has, LOGICAL, { wipe: true, root: false, hasStockInitBoot: false })).toThrow(/stock init_boot/);
		expect(() => buildPlan("version 1\nflash boot\nreboot\nflash system\n", has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false })).toThrow(/Android/);
		expect(() => buildPlan("version 1\nerase userdata\n", has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false })).toThrow(/even without a wipe/);
		expect(() => buildPlan("version 1\nflash boot\n", has, LOGICAL, { wipe: true, root: false, hasStockInitBoot: true })).toThrow(/init_boot/);
	});

	it("describes each step", () => {
		for (const s of buildPlan(INFO, has, LOGICAL, { wipe: true, root: false, hasStockInitBoot: true })) expect(describeStep(s)).toMatch(/\S/);
	});
});
