// Writing super whole from the bootloader, as AOSP fastboot does (its optimized super flash):
// the layout and pieces checked against what fastboot itself sent, the metadata read back, and an
// install on the simulated phone that never restarts into fastbootd.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { Phone } from "../src/fastboot/device.ts";
import { logicalPartitions } from "../src/fastboot/lp.ts";
import { splitSparse } from "../src/fastboot/sparse.ts";
import { SuperLayoutError, buildSuperImage, readLpMetadata } from "../src/fastboot/super-image.ts";
import { buildPlan } from "../src/flash/plan.ts";
import { type ImageSource, runPlan, superImageFor } from "../src/flash/runner.ts";
import { ZipReader } from "../src/zip/zip.ts";
import { FakeConnector, FakePhone } from "./fake-phone.ts";
import { concat, makeSparse, makeSuperEmpty, makeZip } from "./helpers.ts";
import { applySparse } from "./sparse-apply.ts";

/** An ExpressiveOS kodiak build's super_empty.img (10 GiB super, 3 metadata slots, Virtual A/B). */
const EMPTY = new Uint8Array(readFileSync(new URL("./fixtures/kodiak-super_empty.img", import.meta.url)));
const SUPER = 10 * 1024 ** 3;

// The images fastboot was given, made the same way here
const ORDER = ["product", "system", "system_dlkm", "system_ext", "vendor", "vendor_dlkm"];
const SIZES: Record<string, number> = { product: 135168, system: 266240, system_dlkm: 8192, system_ext: 102400, vendor: 69632, vendor_dlkm: 12288 };
function pattern(j: number, n: number): Uint8Array<ArrayBuffer> {
	const b = new Uint8Array(n);
	for (let i = 0; i < n; i++) b[i] = (i * 7 + j * 13 + (i >> 12)) & 0xff;
	return b;
}
const IMAGES = Object.fromEntries(ORDER.map((p, j) => [p, pattern(j, SIZES[p])]));

async function pieceBytes(p: { parts: Array<Uint8Array | Blob> }) {
	return new Uint8Array(await new Blob(p.parts as BlobPart[]).arrayBuffer());
}

/** The geometry and metadata at super's start, as an image file (geometry, then metadata). */
function metadataOf(superBytes: Uint8Array) {
	return readLpMetadata(concat([superBytes.subarray(4096, 8192), superBytes.subarray(12288, 12288 + 65536)]));
}

describe("super written from the bootloader", () => {
	it("sends what AOSP fastboot sends", async () => {
		// fastboot 34.0.4 (`fastboot update`, max-download-size 0x20000) laid these out in this order
		// and sent five pieces; these are their sizes and the SHA-256 of all of them in turn
		const parts = ORDER.map((p) => ({ name: `${p}_a`, blob: new Blob([IMAGES[p]]) }));
		const img = await buildSuperImage(EMPTY, parts, "super", SUPER);
		const pieces = await Promise.all(splitSparse(img.header, img.chunks, 0x20000).map(pieceBytes));
		expect(pieces.map((p) => p.byteLength)).toEqual([127212, 127064, 127040, 127088, 118884]);
		const h = createHash("sha256");
		for (const p of pieces) h.update(p);
		expect(h.digest("hex")).toBe("f4a4011ec89740f542d285810c558d633435b7cc8c64c3fe1c73eadfc16953e2");
	});

	it("lays the partitions out where the metadata says, in every metadata copy", async () => {
		const order = ["system", "system_dlkm", "system_ext", "product", "vendor", "vendor_dlkm"]; // fastboot-info.txt's
		const parts = order.map((p) => ({ name: `${p}_b`, blob: new Blob([IMAGES[p]]) }));
		const img = await buildSuperImage(EMPTY, parts, "super", SUPER);
		const out = new Uint8Array(img.header.totalBlocks * 4096).fill(0xbb);
		for (const p of splitSparse(img.header, img.chunks, 0x20000)) applySparse(await pieceBytes(p), out);

		// The reserved block is zeros; the backup geometry and every metadata copy match the first
		expect(out.subarray(0, 4096).every((b) => b === 0)).toBe(true);
		expect(Buffer.compare(out.subarray(4096, 8192), out.subarray(8192, 12288))).toBe(0);
		const first = out.subarray(12288, 12288 + 4096);
		for (let i = 1; i < 6; i++) expect(Buffer.compare(out.subarray(12288 + i * 65536, 12288 + i * 65536 + 4096), first)).toBe(0);

		const meta = await metadataOf(out);
		expect(meta.minorVersion).toBe(2);
		expect(meta.flags).toBe(1); // Virtual A/B, as super_empty.img says
		let at = 2048; // the first logical sector, then each next 1 MiB boundary
		for (const p of order) {
			const part = meta.partitions.find((x) => x.name === `${p}_b`)!;
			const sectors = Math.ceil(SIZES[p] / 4096) * 8;
			expect(part.extents).toEqual([{ start: at, sectors }]);
			expect(img.layout).toContainEqual({ partition: `${p}_b`, start: at, sectors });
			expect(Buffer.compare(out.subarray(at * 512, at * 512 + SIZES[p]), IMAGES[p])).toBe(0);
			at = Math.ceil((at + sectors) / 2048) * 2048;
		}
		for (const p of meta.partitions.filter((x) => x.name.endsWith("_a"))) expect(p.extents).toEqual([]);
	});

	it("pads an image that ends part way through a block", async () => {
		const img = await buildSuperImage(EMPTY, [{ name: "system_a", blob: new Blob([IMAGES.system.subarray(0, 5000)]) }], "super", SUPER);
		const out = new Uint8Array(img.header.totalBlocks * 4096).fill(0xbb);
		for (const p of splitSparse(img.header, img.chunks, 0x20000)) applySparse(await pieceBytes(p), out);
		const at = 2048 * 512;
		expect(Buffer.compare(out.subarray(at, at + 5000), IMAGES.system.subarray(0, 5000))).toBe(0);
		expect(out.subarray(at + 5000, at + 8192).every((b) => b === 0)).toBe(true);
	});

	it("says why when super can't be written whole", async () => {
		const sys = { name: "system_a", blob: new Blob([IMAGES.system]) };
		await expect(buildSuperImage(EMPTY, [{ name: "system_a", blob: new Blob([makeSparse(4096, [{ raw: IMAGES.system.subarray(0, 8192) }])]) }], "super", SUPER)).rejects.toThrow(
			/system_a's image is sparse/,
		);
		await expect(buildSuperImage(EMPTY, [sys], "super", SUPER / 2)).rejects.toThrow(/is for a super of 10737418240 bytes, but the phone's is 5368709120/);
		await expect(buildSuperImage(EMPTY, [sys], "super", 0)).rejects.toThrow(/didn't say how big super is/);
		await expect(buildSuperImage(EMPTY, [{ name: "odm_a", blob: sys.blob }], "super", SUPER)).rejects.toThrow(/has no odm_a/);
		const broken = EMPTY.slice();
		broken[4096 + 256] ^= 1; // a partition's name, under the tables' checksum
		await expect(buildSuperImage(broken, [sys], "super", SUPER)).rejects.toThrow(/tables checksum/);
		await expect(buildSuperImage(makeSuperEmpty(["system_a"]), [sys], "super", SUPER)).rejects.toBeInstanceOf(SuperLayoutError);
		// 8 metadata slots of 64 KiB don't fit before the first logical sector (1 MiB): liblp refuses it too
		const slots8 = EMPTY.slice();
		new DataView(slots8.buffer).setUint32(44, 8, true);
		slots8.fill(0, 8, 40);
		slots8.set(createHash("sha256").update(slots8.subarray(0, 52)).digest(), 8);
		await expect(buildSuperImage(slots8, [sys], "super", SUPER)).rejects.toThrow(/the metadata overlaps the partitions/);
	});
});

const INFO = `version 1
flash boot
flash init_boot
flash vendor_boot
flash --apply-vbmeta vbmeta
reboot fastboot
update-super
flash system
flash system_dlkm
flash system_ext
flash product
flash vendor
flash vendor_dlkm
if-wipe erase userdata
if-wipe erase metadata
`;
const PHYSICAL = { "boot.img": pattern(40, 8192), "init_boot.img": pattern(41, 4096), "vendor_boot.img": pattern(42, 12288), "vbmeta.img": pattern(43, 4096) };
const has = (n: string) => n === "android-info.txt" || n === "super_empty.img" || n in PHYSICAL || n.replace(/\.img$/, "") in IMAGES;
const LOGICAL = logicalPartitions(EMPTY);

describe("install plan with super written from the bootloader", () => {
	it("writes super after everything else, with no restart into fastbootd", () => {
		const steps = buildPlan(INFO, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false, superFlash: true });
		expect(steps.map((s) => (s.kind === "flash" ? `flash ${s.partition}` : s.kind === "erase" ? `erase ${s.partition}` : s.kind))).toEqual([
			"set-active",
			"cancel-snapshot",
			"flash boot",
			"flash init_boot",
			"flash vendor_boot",
			"flash vbmeta",
			"erase userdata",
			"erase metadata",
			"flash-super",
			"start-android",
		]);
		expect(steps.find((s) => s.kind === "flash-super")).toEqual({
			kind: "flash-super",
			partitions: ["system", "system_dlkm", "system_ext", "product", "vendor", "vendor_dlkm"].map((p) => ({ partition: p, image: `${p}.img` })),
		});
	});

	it("goes through fastbootd when told not to, or when fastboot-info.txt doesn't restart into it first", () => {
		const off = buildPlan(INFO, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false });
		expect(off.some((s) => s.kind === "reboot" && s.target === "fastbootd")).toBe(true);
		expect(off.some((s) => s.kind === "flash-super")).toBe(false);
		const noRestart = INFO.replace("reboot fastboot\nupdate-super\n", "");
		const steps = buildPlan(noRestart, has, LOGICAL, { wipe: true, root: true, hasStockInitBoot: false, superFlash: true });
		expect(steps.some((s) => s.kind === "flash-super")).toBe(false);
		expect(steps.some((s) => s.kind === "resize-to-zero")).toBe(true);
	});
});

describe("install on a simulated phone, super from the bootloader", () => {
	async function setup(o: { mode?: "bootloader" | "fastbootd"; slot?: "a" | "b" } = {}) {
		const zipBytes = makeZip([
			{ name: "android-info.txt", data: new TextEncoder().encode("require board=kodiak\n") },
			{ name: "fastboot-info.txt", data: new TextEncoder().encode(INFO) },
			{ name: "super_empty.img", data: EMPTY },
			...Object.entries(PHYSICAL).map(([name, data]) => ({ name, data })),
			...ORDER.map((p) => ({ name: `${p}.img`, data: IMAGES[p] })),
		]);
		const fake = new FakePhone({ product: "kodiak", slot: o.slot, maxDownload: 0x20000, bootloaderSuper: { reported: SUPER, bytes: 8 * 1024 * 1024 } });
		if (o.mode) fake.mode = o.mode;
		const connector = new FakeConnector(fake);
		const phone = new Phone(connector.link(), connector);
		const zip = await ZipReader.open(new Blob([zipBytes]));
		const source: ImageSource = {
			image: async (ref) => zip.blob(ref.kind === "zip" ? ref.name : "init_boot.img"),
			superEmpty: () => zip.blob("super_empty.img"),
			size: (ref) => (ref.kind === "zip" ? zip.entry(ref.name)!.size : 0),
		};
		const steps = buildPlan(await zip.text("fastboot-info.txt"), (n) => !!zip.entry(n), LOGICAL, { wipe: true, root: true, hasStockInitBoot: false, superFlash: true });
		return { fake, connector, phone, source, steps };
	}

	it("installs without restarting into fastbootd", async () => {
		const { fake, connector, phone, source, steps } = await setup();
		const notes: string[] = [];
		await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: (t) => notes.push(t) });
		expect(fake.mode).toBe("android");
		expect(connector.restarts).toEqual([]);
		expect(fake.commands).not.toContain("reboot-fastboot");
		expect(fake.commands.filter((c) => c === "flash:super").length).toBeGreaterThan(1);
		expect(notes).toContain("super: piece 1 of 5");
		expect(fake.commands.filter((c) => c.startsWith("download:")).every((c) => parseInt(c.slice(9), 16) <= fake.maxDownload)).toBe(true);
		// Erased before super is written, as fastboot does
		expect(fake.commands.indexOf("erase:metadata")).toBeLessThan(fake.commands.indexOf("flash:super"));

		const sup = fake.superBytes!;
		const meta = await metadataOf(sup);
		for (const p of ORDER) {
			const [e] = meta.partitions.find((x) => x.name === `${p}_a`)!.extents;
			expect(Buffer.compare(sup.subarray(e.start * 512, e.start * 512 + SIZES[p]), IMAGES[p])).toBe(0);
		}
		expect(Buffer.compare(fake.physical.get("boot_a")!.subarray(0, 8192), PHYSICAL["boot.img"])).toBe(0);
		expect([...fake.erased].sort()).toEqual(["metadata", "userdata"]);
	});

	it("puts the images in the current slot's partitions on a slot b phone", async () => {
		const { fake, phone, source, steps } = await setup({ slot: "b" });
		await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} });
		expect(fake.mode).toBe("android");
		expect(fake.commands).toContain("set_active:b");
		const sup = fake.superBytes!;
		const meta = await metadataOf(sup);
		for (const p of ORDER) {
			const [e] = meta.partitions.find((x) => x.name === `${p}_b`)!.extents;
			expect(Buffer.compare(sup.subarray(e.start * 512, e.start * 512 + SIZES[p]), IMAGES[p])).toBe(0);
		}
		for (const p of meta.partitions.filter((x) => x.name.endsWith("_a"))) expect(p.extents).toEqual([]);
		expect(Buffer.compare(fake.physical.get("boot_b")!.subarray(0, 8192), PHYSICAL["boot.img"])).toBe(0);
	});

	it("won't write super whole from fastbootd", async () => {
		const { phone, source, steps } = await setup({ mode: "fastbootd" });
		const step = steps.find((s) => s.kind === "flash-super")!;
		expect(step.kind).toBe("flash-super");
		await expect(superImageFor(phone, step as Extract<typeof step, { kind: "flash-super" }>, source)).rejects.toThrow(/isn't in the bootloader/);
	});
});
