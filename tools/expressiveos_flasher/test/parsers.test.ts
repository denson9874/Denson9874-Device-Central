import { describe, expect, it } from "vitest";
import { checkRequirements, matches, parseRequirements } from "../src/fastboot/android-info.ts";
import { FastbootInfoError, parseFastbootInfo } from "../src/fastboot/fastboot-info.ts";
import { isLogical, logicalPartitions } from "../src/fastboot/lp.ts";
import { requiredBoards } from "../src/flash/preflight.ts";
import { makeSuperEmpty } from "./helpers.ts";

describe("android-info.txt", () => {
	it("reads require, reject and require-for-product lines", () => {
		const { requirements, errors } = parseRequirements(
			"require board=cheetah\nrequire version-bootloader=cloudripper-16.4*|cloudripper-16.3\nreject version-baseband=bad\nrequire-for-product:cheetah partition-exists=vendor_kernel_boot\nnonsense\n",
		);
		expect(errors).toEqual(["nonsense"]);
		expect(requirements.map((r) => [r.name, r.invert, r.product, r.options])).toEqual([
			["product", false, "", ["cheetah"]],
			["version-bootloader", false, "", ["cloudripper-16.4*", "cloudripper-16.3"]],
			["version-baseband", true, "", ["bad"]],
			["partition-exists", false, "cheetah", ["vendor_kernel_boot"]],
		]);
		expect(requiredBoards("require board=cheetah\n")).toEqual(["cheetah"]);
	});

	it("skips lines of only spaces or tabs, as they require nothing", () => {
		const { requirements, errors } = parseRequirements("require board=cheetah\n \n\t\n  \t \r\n\r\n");
		expect(errors).toEqual([]);
		expect(requirements.map((r) => r.line)).toEqual(["require board=cheetah"]);
		// A line fastboot can't read either is still reported (fastboot prints a syntax error for it)
		expect(parseRequirements("require board=cheetah\nrequire foo\n").errors).toEqual(["require foo"]);
	});

	it("matches prefixes with a trailing *", () => {
		expect(matches(["cloudripper-16.4*"], "cloudripper-16.4-1")).toBe(true);
		expect(matches(["cloudripper-16.4"], "cloudripper-16.4-1")).toBe(false);
	});

	it("checks requirements against the phone", async () => {
		const vars: Record<string, string> = { product: "husky", "version-bootloader": "ripcurrent-16.4-1", "has-slot:vendor_kernel_boot": "yes" };
		const g = async (n: string) => vars[n] ?? null;
		const { requirements } = parseRequirements("require board=cheetah\nrequire version-bootloader=ripcurrent-16.4*\nreject version-bootloader=ripcurrent-16.4-1\nrequire-for-product:cheetah version-baseband=x\nrequire partition-exists=vendor_kernel_boot\nrequire version-baseband=y\n");
		const r = await checkRequirements(requirements, g);
		expect(r.map((x) => [x.requirement.name, x.ok, !!x.skipped])).toEqual([
			["product", false, false],
			["version-bootloader", true, false],
			["version-bootloader", false, false],
			["version-baseband", true, true],
			["partition-exists", true, false],
			["version-baseband", false, false],
		]);
	});
});

describe("fastboot-info.txt", () => {
	const text = "# made by the build\nversion 1\nflash boot\nflash --apply-vbmeta vbmeta\nflash --slot-other init_boot init_boot_other.img\nreboot fastboot\nupdate-super\nflash system\nif-wipe erase userdata\nif-wipe erase metadata\n";

	it("reads every command", () => {
		expect(parseFastbootInfo(text, true)).toEqual([
			{ kind: "flash", partition: "boot", image: "boot.img", applyVbmeta: false, otherSlot: false },
			{ kind: "flash", partition: "vbmeta", image: "vbmeta.img", applyVbmeta: true, otherSlot: false },
			{ kind: "flash", partition: "init_boot", image: "init_boot_other.img", applyVbmeta: false, otherSlot: true },
			{ kind: "reboot", target: "fastboot" },
			{ kind: "update-super" },
			{ kind: "flash", partition: "system", image: "system.img", applyVbmeta: false, otherSlot: false },
			{ kind: "erase", partition: "userdata", ifWipe: true },
			{ kind: "erase", partition: "metadata", ifWipe: true },
		]);
	});

	it("drops if-wipe lines without a wipe", () => {
		expect(parseFastbootInfo(text, false).some((t) => t.kind === "erase")).toBe(false);
	});

	it("refuses what it doesn't understand", () => {
		expect(() => parseFastbootInfo("version 2\n", true)).toThrow(FastbootInfoError);
		expect(() => parseFastbootInfo("flash\n", true)).toThrow(FastbootInfoError);
		expect(() => parseFastbootInfo("oem unlock\n", true)).toThrow(FastbootInfoError);
		expect(() => parseFastbootInfo("flash ../boot\n", true)).toThrow(FastbootInfoError);
		expect(() => parseFastbootInfo("reboot android\n", true)).toThrow(FastbootInfoError);
	});
});

describe("super_empty.img", () => {
	it("lists the logical partitions", () => {
		const names = logicalPartitions(makeSuperEmpty(["system_a", "system_b", "vendor_a", "vendor_b"]));
		expect(names).toEqual(["system_a", "system_b", "vendor_a", "vendor_b"]);
		expect(isLogical(names!, "system")).toBe(true);
		expect(isLogical(names!, "boot")).toBe(false);
	});

	it("gives null for anything else", () => {
		expect(logicalPartitions(new Uint8Array(10000))).toBeNull();
		const bad = makeSuperEmpty(["sys tem"]);
		expect(logicalPartitions(bad)).toBeNull();
	});
});
