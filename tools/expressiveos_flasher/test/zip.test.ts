import { describe, expect, it } from "vitest";
import { ZipError, ZipReader } from "../src/zip/zip.ts";
import { blobBytes, bytes, makeZip } from "./helpers.ts";

const files = [
	{ name: "android-info.txt", data: new TextEncoder().encode("require board=cheetah\n") },
	{ name: "boot.img", data: bytes(70_000, 3) },
	{ name: "fastboot-info.txt", data: new TextEncoder().encode("version 1\nflash boot\n"), deflate: true },
];

describe("zip reader", () => {
	for (const zip64 of [false, true]) {
		it(`reads entries of a ${zip64 ? "Zip64" : "plain"} zip as slices`, async () => {
			const z = await ZipReader.open(new Blob([makeZip(files, { zip64, comment: "ExpressiveOS" })]));
			expect(z.entries.map((e) => e.name)).toEqual(files.map((f) => f.name));
			expect(await z.text("android-info.txt")).toBe("require board=cheetah\n");
			const boot = await blobBytes(await z.blob("boot.img"));
			expect(Buffer.compare(boot, files[1].data)).toBe(0);
			// Deflated entries are inflated
			expect(await z.text("fastboot-info.txt")).toBe("version 1\nflash boot\n");
		});
	}

	it("refuses what isn't a zip", async () => {
		await expect(ZipReader.open(new Blob([bytes(5000)]))).rejects.toThrow(ZipError);
		await expect(ZipReader.open(new Blob([new Uint8Array(4)]))).rejects.toThrow(ZipError);
	});

	it("says which entry is missing", async () => {
		const z = await ZipReader.open(new Blob([makeZip(files)]));
		await expect(z.blob("system.img")).rejects.toThrow(/system\.img/);
	});

	it("refuses a compressed entry too big to unpack", async () => {
		const z = await ZipReader.open(new Blob([makeZip([{ name: "a.img", data: bytes(4096), deflate: true }])]));
		await expect(z.blob("a.img", 100)).rejects.toThrow(/too large/);
	});

	it("notices a zip cut short", async () => {
		const full = makeZip(files);
		// Drop the middle: the central directory points past what's there
		const cut = new Uint8Array([...full.subarray(0, 100), ...full.subarray(full.byteLength - 300)]);
		await expect((async () => (await ZipReader.open(new Blob([cut]))).blob("boot.img"))()).rejects.toThrow();
	});
});
