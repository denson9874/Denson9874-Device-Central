import { describe, expect, it } from "vitest";
import { payloadOf } from "../src/fastboot/client.ts";
import { RESPARSE_LIMIT, flashPayloads, imageInfo, moveAvbFooter } from "../src/fastboot/images.ts";
import { parseSparseHeader, rawChunks, readSparseChunks, splitSparse } from "../src/fastboot/sparse.ts";
import { applySparse, blobBytes, bytes, concat, expandSparse, makeSparse, withAvbFooter } from "./helpers.ts";

async function pieceBytes(p: { parts: Array<Uint8Array | Blob> }): Promise<Uint8Array> {
	return concat(await Promise.all(p.parts.map(blobBytes)));
}

const BS = 4096;
const image = makeSparse(BS, [
	{ raw: bytes(BS * 3, 1) },
	{ skip: 5 },
	{ fill: 0xdeadbeef, blocks: 4 },
	{ crc: 0x12345678 },
	{ raw: bytes(BS * 40, 2) },
	{ skip: 2 },
	{ fill: 0, blocks: 1 },
	{ raw: bytes(BS, 3) },
	{ skip: 9 },
]);

describe("sparse images", () => {
	it("reads the header and chunks, dropping CRC chunks", async () => {
		const blob = new Blob([image]);
		const h = parseSparseHeader(image)!;
		expect(h.blockSize).toBe(BS);
		expect(h.totalBlocks).toBe(3 + 5 + 4 + 40 + 2 + 1 + 1 + 9);
		const chunks = await readSparseChunks(blob, h);
		expect(chunks.map((c) => c.blocks)).toEqual([3, 5, 4, 40, 2, 1, 1, 9]);
	});

	it("isn't sparse when the magic is missing", () => {
		expect(parseSparseHeader(bytes(64))).toBeNull();
	});

	for (const max of [BS * 2 + 100, BS * 5, BS * 11 + 7, BS * 100, 1 << 20]) {
		it(`splits into pieces of at most ${max} bytes that write the same image`, async () => {
			const h = parseSparseHeader(image)!;
			const pieces = splitSparse(h, await readSparseChunks(new Blob([image]), h), max);
			const target = new Uint8Array(h.totalBlocks * BS).fill(0x55);
			const seen = new Set<number>();
			for (const p of pieces) {
				expect(p.size).toBeLessThanOrEqual(max);
				const b = await pieceBytes(p);
				expect(b.byteLength).toBe(p.size);
				// Each piece is a sparse image of the whole partition
				expect(parseSparseHeader(b)!.totalBlocks).toBe(h.totalBlocks);
				const written = applySparse(b, target);
				expect(written.length).toBe(p.writesBlocks);
				for (const w of written) {
					expect(seen.has(w)).toBe(false);
					seen.add(w);
				}
			}
			// What the pieces wrote is what the image writes, and don't-care blocks are untouched
			const want = new Uint8Array(h.totalBlocks * BS).fill(0x55);
			applySparse(image, want);
			expect(Buffer.compare(target, want)).toBe(0);
		});
	}

	it("refuses a buffer too small for one block", async () => {
		const h = parseSparseHeader(image)!;
		expect(() => splitSparse(h, [], 100)).toThrow(/too small/);
	});

	it("cuts a raw image bigger than the buffer into sparse pieces, padding the last block", async () => {
		const raw = bytes(BS * 7 + 123, 9);
		const { header, chunks } = rawChunks(new Blob([raw]));
		const pieces = splitSparse(header, chunks, BS * 3);
		expect(pieces.length).toBeGreaterThan(2);
		const target = new Uint8Array(header.totalBlocks * BS);
		for (const p of pieces) applySparse(await pieceBytes(p), target);
		expect(Buffer.compare(target.subarray(0, raw.byteLength), raw)).toBe(0);
		expect(target.subarray(raw.byteLength).every((b) => b === 0)).toBe(true);
	});

	it("sends an image whole when it fits, and caps pieces at 1 GiB", async () => {
		const small = new Blob([bytes(1000)]);
		const r = await flashPayloads(small, 4096);
		expect(r.pieces.length).toBe(1);
		expect(r.info).toEqual({ sparse: false, imageSize: 1000 });
		expect(RESPARSE_LIMIT).toBe(1 << 30);
		const sp = await flashPayloads(new Blob([image]), BS * 6);
		expect(sp.info.sparse).toBe(true);
		expect(sp.pieces.length).toBeGreaterThan(1);
		const out = new Uint8Array(sp.info.imageSize);
		for (const p of sp.pieces) applySparse(await pieceBytes(p), out);
		expect(Buffer.compare(out, expandSparse(image))).toBe(0);
	});

	it("knows a sparse image's expanded size", async () => {
		expect(await imageInfo(new Blob([image]))).toEqual({ sparse: true, imageSize: parseSparseHeader(image)!.totalBlocks * BS });
	});
});

describe("AVB footer", () => {
	it("moves the footer to the end of a bigger partition", async () => {
		const img = withAvbFooter(bytes(1000));
		const moved = await blobBytes(await moveAvbFooter(new Blob([img]), 4096));
		expect(moved.byteLength).toBe(4096);
		expect(Buffer.compare(moved.subarray(0, img.byteLength), img)).toBe(0);
		expect(Buffer.compare(moved.subarray(4096 - 64), img.subarray(img.byteLength - 64))).toBe(0);
		expect(moved.subarray(img.byteLength, 4096 - 64).every((b) => b === 0)).toBe(true);
	});

	it("leaves an image alone without a footer, or when it fills the partition", async () => {
		const plain = new Blob([bytes(1000)]);
		expect(await moveAvbFooter(plain, 4096)).toBe(plain);
		const full = new Blob([withAvbFooter(bytes(1000))]);
		expect(await moveAvbFooter(full, full.size)).toBe(full);
		expect(await moveAvbFooter(full, 0)).toBe(full);
	});
});

describe("payloads", () => {
	it("counts sizes of mixed parts", () => {
		expect(payloadOf([new Uint8Array(3), new Blob([new Uint8Array(5)])]).size).toBe(8);
	});
});
