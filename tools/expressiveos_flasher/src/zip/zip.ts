// Reads a (Zip64) zip's central directory from a Blob and hands out its entries as Blob slices,
// so a 7 GB release is never loaded into memory: ExpressiveOS's fastboot zips are stored
// (zip -0), so each image is a byte range of the file. Deflated entries are inflated on demand.

export class ZipError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "ZipError";
	}
}

export interface ZipEntry {
	name: string;
	method: number;
	crc32: number;
	compressedSize: number;
	size: number;
	localHeaderOffset: number;
	flags: number;
}

const EOCD_SIG = 0x06054b50;
const ZIP64_LOCATOR_SIG = 0x07064b50;
const ZIP64_EOCD_SIG = 0x06064b50;
const CDH_SIG = 0x02014b50;
const LFH_SIG = 0x04034b50;
const MAX_U32 = 0xffffffff;
const MAX_U16 = 0xffff;

async function bytesAt(blob: Blob, start: number, end: number): Promise<Uint8Array> {
	if (start < 0 || end > blob.size || start > end) throw new ZipError("The zip is cut short");
	return new Uint8Array(await blob.slice(start, end).arrayBuffer());
}

function u64(v: DataView, at: number): number {
	const n = v.getBigUint64(at, true);
	if (n > BigInt(Number.MAX_SAFE_INTEGER)) throw new ZipError("A zip offset is too large");
	return Number(n);
}

export class ZipReader {
	private constructor(
		readonly source: Blob,
		readonly entries: ZipEntry[],
	) {}

	static async open(blob: Blob): Promise<ZipReader> {
		if (blob.size < 22) throw new ZipError("This isn't a zip file");
		// The end of central directory record is in the last 22 + 65535 (comment) bytes
		const tailStart = Math.max(0, blob.size - (22 + 0xffff + 20));
		const tail = await bytesAt(blob, tailStart, blob.size);
		const tv = new DataView(tail.buffer);
		let eocd = -1;
		for (let i = tail.byteLength - 22; i >= 0; i--) {
			if (tv.getUint32(i, true) === EOCD_SIG && i + 22 + tv.getUint16(i + 20, true) <= tail.byteLength) {
				eocd = i;
				break;
			}
		}
		if (eocd < 0) throw new ZipError("This isn't a zip file (no end of central directory)");
		let count = tv.getUint16(eocd + 10, true);
		let cdSize = tv.getUint32(eocd + 12, true);
		let cdOffset = tv.getUint32(eocd + 16, true);
		if (tv.getUint16(eocd + 4, true) !== 0 || tv.getUint16(eocd + 6, true) !== 0) throw new ZipError("Split (multi-part) zips aren't supported");
		// Zip64: the locator sits right before the EOCD record
		const loc = eocd - 20;
		if (loc >= 0 && tv.getUint32(loc, true) === ZIP64_LOCATOR_SIG) {
			const z64Offset = u64(tv, loc + 8);
			const z = await bytesAt(blob, z64Offset, z64Offset + 56);
			const zv = new DataView(z.buffer);
			if (zv.getUint32(0, true) !== ZIP64_EOCD_SIG) throw new ZipError("Bad Zip64 end of central directory");
			count = u64(zv, 32);
			cdSize = u64(zv, 40);
			cdOffset = u64(zv, 48);
		} else if (count === MAX_U16 || cdSize === MAX_U32 || cdOffset === MAX_U32) {
			throw new ZipError("Zip64 record missing");
		}
		if (cdSize > 64 * 1024 * 1024 || count > 100_000) throw new ZipError("The zip's central directory is too large");
		const cd = await bytesAt(blob, cdOffset, cdOffset + cdSize);
		const v = new DataView(cd.buffer);
		const dec = new TextDecoder();
		const entries: ZipEntry[] = [];
		let p = 0;
		for (let i = 0; i < count; i++) {
			if (p + 46 > cd.byteLength || v.getUint32(p, true) !== CDH_SIG) throw new ZipError("Bad central directory entry");
			const flags = v.getUint16(p + 8, true);
			const method = v.getUint16(p + 10, true);
			const crc32 = v.getUint32(p + 16, true);
			let compressedSize = v.getUint32(p + 20, true);
			let size = v.getUint32(p + 24, true);
			const nameLen = v.getUint16(p + 28, true);
			const extraLen = v.getUint16(p + 30, true);
			const commentLen = v.getUint16(p + 32, true);
			const disk = v.getUint16(p + 34, true);
			let localHeaderOffset = v.getUint32(p + 42, true);
			if (p + 46 + nameLen + extraLen + commentLen > cd.byteLength) throw new ZipError("Bad central directory entry");
			const name = dec.decode(cd.subarray(p + 46, p + 46 + nameLen));
			// Zip64 extended information: only the fields whose 32-bit value is all ones, in order
			let x = p + 46 + nameLen;
			const xEnd = x + extraLen;
			while (x + 4 <= xEnd) {
				const id = v.getUint16(x, true);
				const len = v.getUint16(x + 2, true);
				if (x + 4 + len > xEnd) break;
				if (id === 0x0001) {
					let f = x + 4;
					const take = () => {
						if (f + 8 > x + 4 + len) throw new ZipError(`Bad Zip64 field for ${name}`);
						const n = u64(v, f);
						f += 8;
						return n;
					};
					if (size === MAX_U32) size = take();
					if (compressedSize === MAX_U32) compressedSize = take();
					if (localHeaderOffset === MAX_U32) localHeaderOffset = take();
				}
				x += 4 + len;
			}
			if (disk !== 0 && disk !== MAX_U16) throw new ZipError("Split (multi-part) zips aren't supported");
			entries.push({ name, method, crc32, compressedSize, size, localHeaderOffset, flags });
			p += 46 + nameLen + extraLen + commentLen;
		}
		return new ZipReader(blob, entries);
	}

	entry(name: string): ZipEntry | undefined {
		return this.entries.find((e) => e.name === name);
	}

	/** Where the entry's data starts: after its local header, whose extra field can differ from the central one. */
	async dataOffset(e: ZipEntry): Promise<number> {
		const h = await bytesAt(this.source, e.localHeaderOffset, e.localHeaderOffset + 30);
		const v = new DataView(h.buffer);
		if (v.getUint32(0, true) !== LFH_SIG) throw new ZipError(`Bad local header for ${e.name}`);
		const start = e.localHeaderOffset + 30 + v.getUint16(26, true) + v.getUint16(28, true);
		if (start + e.compressedSize > this.source.size) throw new ZipError(`${e.name} runs past the end of the zip`);
		return start;
	}

	/** The entry's raw (stored) bytes as a slice of the zip, read lazily from disk. */
	async storedBlob(e: ZipEntry): Promise<Blob> {
		if (e.flags & 1) throw new ZipError(`${e.name} is encrypted`);
		if (e.method !== 0) throw new ZipError(`${e.name} is compressed`);
		if (e.compressedSize !== e.size) throw new ZipError(`${e.name}: stored sizes differ`);
		const start = await this.dataOffset(e);
		return this.source.slice(start, start + e.size);
	}

	/** The entry's contents: a slice when stored, inflated into memory when deflated (small files). */
	async blob(name: string, maxInflate = 512 * 1024 * 1024): Promise<Blob> {
		const e = this.entry(name);
		if (!e) throw new ZipError(`The zip has no ${name}`);
		if (e.method === 0) return this.storedBlob(e);
		if (e.flags & 1) throw new ZipError(`${e.name} is encrypted`);
		if (e.method !== 8) throw new ZipError(`${e.name} uses an unsupported compression (${e.method})`);
		if (e.size > maxInflate) throw new ZipError(`${e.name} is compressed and too large to unpack in the browser; use a zip made with "zip -0"`);
		const start = await this.dataOffset(e);
		const stream = this.source.slice(start, start + e.compressedSize).stream().pipeThrough(new DecompressionStream("deflate-raw"));
		const out = await new Response(stream).blob();
		if (out.size !== e.size) throw new ZipError(`${e.name} unpacked to ${out.size} bytes, not ${e.size}`);
		return out;
	}

	async text(name: string): Promise<string> {
		return (await this.blob(name, 1024 * 1024)).text();
	}

	async bytes(name: string, max = 64 * 1024 * 1024): Promise<Uint8Array> {
		const b = await this.blob(name, max);
		if (b.size > max) throw new ZipError(`${name} is too large`);
		return new Uint8Array(await b.arrayBuffer());
	}
}
