// Test fixtures: sparse images, zips (stored, deflated, Zip64), super_empty.img, and bytes.

import { deflateRawSync } from "node:zlib";
import { applySparse } from "./sparse-apply.ts";

export { applySparse };

/** Deterministic pseudo-random bytes. */
export function bytes(n: number, seed = 1): Uint8Array<ArrayBuffer> {
	const out = new Uint8Array(n);
	let x = seed >>> 0 || 1;
	for (let i = 0; i < n; i++) {
		x ^= x << 13;
		x ^= x >>> 17;
		x ^= x << 5;
		out[i] = x & 0xff;
	}
	return out;
}

export function concat(parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
	const n = parts.reduce((a, p) => a + p.byteLength, 0);
	const out = new Uint8Array(n);
	let o = 0;
	for (const p of parts) {
		out.set(p, o);
		o += p.byteLength;
	}
	return out;
}

export async function blobBytes(b: Blob | Uint8Array): Promise<Uint8Array> {
	return b instanceof Uint8Array ? b : new Uint8Array(await b.arrayBuffer());
}

export type SparseSpec =
	| { raw: Uint8Array } // whole blocks of data
	| { fill: number; blocks: number }
	| { skip: number }
	| { crc: number };

/** A sparse image made of these chunks. */
export function makeSparse(blockSize: number, spec: SparseSpec[]): Uint8Array<ArrayBuffer> {
	let total = 0;
	const body: Uint8Array[] = [];
	for (const c of spec) {
		const h = new Uint8Array(12);
		const v = new DataView(h.buffer);
		if ("raw" in c) {
			if (c.raw.byteLength % blockSize) throw new Error("raw data must be whole blocks");
			const blocks = c.raw.byteLength / blockSize;
			v.setUint16(0, 0xcac1, true);
			v.setUint32(4, blocks, true);
			v.setUint32(8, 12 + c.raw.byteLength, true);
			body.push(h, c.raw);
			total += blocks;
		} else if ("fill" in c) {
			v.setUint16(0, 0xcac2, true);
			v.setUint32(4, c.blocks, true);
			v.setUint32(8, 16, true);
			const val = new Uint8Array(4);
			new DataView(val.buffer).setUint32(0, c.fill, true);
			body.push(h, val);
			total += c.blocks;
		} else if ("skip" in c) {
			v.setUint16(0, 0xcac3, true);
			v.setUint32(4, c.skip, true);
			v.setUint32(8, 12, true);
			body.push(h);
			total += c.skip;
		} else {
			v.setUint16(0, 0xcac4, true);
			v.setUint32(4, 0, true);
			v.setUint32(8, 16, true);
			const val = new Uint8Array(4);
			new DataView(val.buffer).setUint32(0, c.crc, true);
			body.push(h, val);
		}
	}
	const fh = new Uint8Array(28);
	const v = new DataView(fh.buffer);
	v.setUint32(0, 0xed26ff3a, true);
	v.setUint16(4, 1, true);
	v.setUint16(8, 28, true);
	v.setUint16(10, 12, true);
	v.setUint32(12, blockSize, true);
	v.setUint32(16, total, true);
	v.setUint32(20, spec.length, true);
	return concat([fh, ...body]);
}

/** A sparse image's full contents. */
export function expandSparse(img: Uint8Array): Uint8Array<ArrayBuffer> {
	const v = new DataView(img.buffer, img.byteOffset, img.byteLength);
	const out = new Uint8Array(v.getUint32(16, true) * v.getUint32(12, true));
	applySparse(img, out);
	return out;
}

const CRC_TABLE = (() => {
	const t = new Uint32Array(256);
	for (let n = 0; n < 256; n++) {
		let c = n;
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		t[n] = c >>> 0;
	}
	return t;
})();

export function crc32(b: Uint8Array): number {
	let c = 0xffffffff;
	for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
	return (c ^ 0xffffffff) >>> 0;
}

/** A zip of these files: stored unless deflate is set; with Zip64 records when zip64 is set. */
export function makeZip(files: Array<{ name: string; data: Uint8Array; deflate?: boolean }>, opts: { zip64?: boolean; comment?: string } = {}): Uint8Array<ArrayBuffer> {
	const z64 = !!opts.zip64;
	const enc = new TextEncoder();
	const locals: Uint8Array[] = [];
	const central: Uint8Array[] = [];
	let offset = 0;
	for (const f of files) {
		const name = enc.encode(f.name);
		const comp = f.deflate ? new Uint8Array(deflateRawSync(f.data)) : f.data;
		const crc = crc32(f.data);
		const lExtra = z64 ? new Uint8Array(20) : new Uint8Array(0);
		if (z64) {
			const e = new DataView(lExtra.buffer);
			e.setUint16(0, 1, true);
			e.setUint16(2, 16, true);
			e.setBigUint64(4, BigInt(f.data.byteLength), true);
			e.setBigUint64(12, BigInt(comp.byteLength), true);
		}
		const lh = new Uint8Array(30);
		const lv = new DataView(lh.buffer);
		lv.setUint32(0, 0x04034b50, true);
		lv.setUint16(4, z64 ? 45 : 20, true);
		lv.setUint16(8, f.deflate ? 8 : 0, true);
		lv.setUint32(14, crc, true);
		lv.setUint32(18, z64 ? 0xffffffff : comp.byteLength, true);
		lv.setUint32(22, z64 ? 0xffffffff : f.data.byteLength, true);
		lv.setUint16(26, name.byteLength, true);
		lv.setUint16(28, lExtra.byteLength, true);
		const local = concat([lh, name, lExtra, comp]);
		const cExtra = z64 ? new Uint8Array(28) : new Uint8Array(0);
		if (z64) {
			const e = new DataView(cExtra.buffer);
			e.setUint16(0, 1, true);
			e.setUint16(2, 24, true);
			e.setBigUint64(4, BigInt(f.data.byteLength), true);
			e.setBigUint64(12, BigInt(comp.byteLength), true);
			e.setBigUint64(20, BigInt(offset), true);
		}
		const ch = new Uint8Array(46);
		const cv = new DataView(ch.buffer);
		cv.setUint32(0, 0x02014b50, true);
		cv.setUint16(4, z64 ? 45 : 20, true);
		cv.setUint16(6, z64 ? 45 : 20, true);
		cv.setUint16(10, f.deflate ? 8 : 0, true);
		cv.setUint32(16, crc, true);
		cv.setUint32(20, z64 ? 0xffffffff : comp.byteLength, true);
		cv.setUint32(24, z64 ? 0xffffffff : f.data.byteLength, true);
		cv.setUint16(28, name.byteLength, true);
		cv.setUint16(30, cExtra.byteLength, true);
		cv.setUint32(42, z64 ? 0xffffffff : offset, true);
		central.push(concat([ch, name, cExtra]));
		locals.push(local);
		offset += local.byteLength;
	}
	const cd = concat(central);
	const tail: Uint8Array[] = [];
	if (z64) {
		const r = new Uint8Array(56);
		const v = new DataView(r.buffer);
		v.setUint32(0, 0x06064b50, true);
		v.setBigUint64(4, 44n, true);
		v.setUint16(12, 45, true);
		v.setUint16(14, 45, true);
		v.setBigUint64(24, BigInt(files.length), true);
		v.setBigUint64(32, BigInt(files.length), true);
		v.setBigUint64(40, BigInt(cd.byteLength), true);
		v.setBigUint64(48, BigInt(offset), true);
		const loc = new Uint8Array(20);
		const lv = new DataView(loc.buffer);
		lv.setUint32(0, 0x07064b50, true);
		lv.setBigUint64(8, BigInt(offset + cd.byteLength), true);
		lv.setUint32(16, 1, true);
		tail.push(r, loc);
	}
	const comment = enc.encode(opts.comment ?? "");
	const eocd = new Uint8Array(22);
	const ev = new DataView(eocd.buffer);
	ev.setUint32(0, 0x06054b50, true);
	ev.setUint16(8, z64 ? 0xffff : files.length, true);
	ev.setUint16(10, z64 ? 0xffff : files.length, true);
	ev.setUint32(12, z64 ? 0xffffffff : cd.byteLength, true);
	ev.setUint32(16, z64 ? 0xffffffff : offset, true);
	ev.setUint16(20, comment.byteLength, true);
	return concat([...locals, cd, ...tail, eocd, comment]);
}

/** A super_empty.img (liblp metadata) listing these logical partitions. */
export function makeSuperEmpty(names: string[]): Uint8Array<ArrayBuffer> {
	const out = new Uint8Array(4096 + 256 + names.length * 52 + 4096);
	const v = new DataView(out.buffer);
	v.setUint32(0, 0x616c4467, true); // geometry
	v.setUint32(4, 52, true);
	const h = 4096;
	v.setUint32(h, 0x414c5030, true);
	v.setUint16(h + 4, 10, true);
	v.setUint16(h + 6, 2, true);
	v.setUint32(h + 8, 256, true); // header size
	v.setUint32(h + 80, 0, true); // partitions table offset
	v.setUint32(h + 84, names.length, true);
	v.setUint32(h + 88, 52, true);
	const enc = new TextEncoder();
	names.forEach((n, i) => out.set(enc.encode(n), h + 256 + i * 52));
	return out;
}

/** A raw image ending in an AVB footer ("AVBf"). */
export function withAvbFooter(data: Uint8Array): Uint8Array<ArrayBuffer> {
	const footer = new Uint8Array(64);
	footer.set([0x41, 0x56, 0x42, 0x66]);
	footer.fill(7, 4);
	return concat([data, footer]);
}
