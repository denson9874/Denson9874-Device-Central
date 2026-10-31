// Android sparse images (libsparse's format): reading their chunk lists from disk without loading
// the data, and cutting an image into pieces that each fit the phone's download buffer. Each
// piece is itself a whole sparse image of the partition that writes only its own blocks (the rest
// is "don't care"), which is how AOSP fastboot sends images bigger than max-download-size.

import { type Part, type Payload, payloadOf } from "./client.ts";

export const SPARSE_MAGIC = 0xed26ff3a;
export const FILE_HEADER_SIZE = 28;
export const CHUNK_HEADER_SIZE = 12;

export const enum ChunkType {
	Raw = 0xcac1,
	Fill = 0xcac2,
	DontCare = 0xcac3,
	Crc32 = 0xcac4,
}

export interface SparseHeader {
	blockSize: number;
	totalBlocks: number;
	totalChunks: number;
	fileHeaderSize: number;
	chunkHeaderSize: number;
}

/** A chunk whose data is described by parts (Blob slices, or bytes for fill values and padding). */
export interface Chunk {
	type: ChunkType.Raw | ChunkType.Fill | ChunkType.DontCare;
	blocks: number;
	data: Part[];
	dataSize: number;
}

export class ImageError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "ImageError";
	}
}

export function parseSparseHeader(bytes: Uint8Array): SparseHeader | null {
	if (bytes.byteLength < FILE_HEADER_SIZE) return null;
	const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	if (v.getUint32(0, true) !== SPARSE_MAGIC) return null;
	const major = v.getUint16(4, true);
	const fileHeaderSize = v.getUint16(8, true);
	const chunkHeaderSize = v.getUint16(10, true);
	const blockSize = v.getUint32(12, true);
	if (major !== 1) throw new ImageError(`Unsupported sparse image version ${major}`);
	if (fileHeaderSize < FILE_HEADER_SIZE || chunkHeaderSize < CHUNK_HEADER_SIZE)
		throw new ImageError(`Bad sparse header sizes ${fileHeaderSize}/${chunkHeaderSize}`);
	if (blockSize === 0 || blockSize % 4 !== 0) throw new ImageError(`Bad sparse block size ${blockSize}`);
	return {
		blockSize,
		totalBlocks: v.getUint32(16, true),
		totalChunks: v.getUint32(20, true),
		fileHeaderSize,
		chunkHeaderSize,
	};
}

/** Reads a Blob through a window, so consecutive small headers cost one disk read. */
class WindowReader {
	private start = 0;
	private bytes = new Uint8Array(0);
	constructor(
		private readonly blob: Blob,
		private readonly windowSize = 64 * 1024,
	) {}
	async read(offset: number, length: number): Promise<Uint8Array> {
		if (offset < this.start || offset + length > this.start + this.bytes.byteLength) {
			const end = Math.min(this.blob.size, offset + Math.max(length, this.windowSize));
			this.bytes = new Uint8Array(await this.blob.slice(offset, end).arrayBuffer());
			this.start = offset;
			if (this.bytes.byteLength < length) throw new ImageError("The sparse image is cut short");
		}
		return this.bytes.subarray(offset - this.start, offset - this.start + length);
	}
}

/** The chunk list of a sparse image (CRC chunks dropped: splitting would invalidate them). */
export async function readSparseChunks(blob: Blob, header: SparseHeader): Promise<Chunk[]> {
	const r = new WindowReader(blob);
	const chunks: Chunk[] = [];
	let pos = header.fileHeaderSize;
	let blocks = 0;
	for (let i = 0; i < header.totalChunks; i++) {
		const h = await r.read(pos, CHUNK_HEADER_SIZE);
		const v = new DataView(h.buffer, h.byteOffset, h.byteLength);
		const type = v.getUint16(0, true);
		const chunkBlocks = v.getUint32(4, true);
		const totalSize = v.getUint32(8, true);
		const dataStart = pos + header.chunkHeaderSize;
		const dataSize = totalSize - header.chunkHeaderSize;
		if (dataSize < 0 || dataStart + dataSize > blob.size) throw new ImageError(`Sparse chunk ${i} runs past the end of the image`);
		switch (type) {
			case ChunkType.Raw:
				if (dataSize !== chunkBlocks * header.blockSize) throw new ImageError(`Sparse raw chunk ${i} has ${dataSize} bytes for ${chunkBlocks} blocks`);
				chunks.push({ type, blocks: chunkBlocks, data: [blob.slice(dataStart, dataStart + dataSize)], dataSize });
				break;
			case ChunkType.Fill:
				if (dataSize !== 4) throw new ImageError(`Sparse fill chunk ${i} has ${dataSize} data bytes`);
				chunks.push({ type, blocks: chunkBlocks, data: [(await r.read(dataStart, 4)).slice()], dataSize: 4 });
				break;
			case ChunkType.DontCare:
				if (dataSize !== 0) throw new ImageError(`Sparse skip chunk ${i} has data`);
				chunks.push({ type, blocks: chunkBlocks, data: [], dataSize: 0 });
				break;
			case ChunkType.Crc32:
				if (dataSize !== 4) throw new ImageError(`Sparse CRC chunk ${i} has ${dataSize} data bytes`);
				break;
			default:
				throw new ImageError(`Unknown sparse chunk type 0x${type.toString(16)}`);
		}
		blocks += type === ChunkType.Crc32 ? 0 : chunkBlocks;
		pos = dataStart + dataSize;
	}
	if (blocks !== header.totalBlocks) throw new ImageError(`The sparse image's chunks cover ${blocks} blocks, not ${header.totalBlocks}`);
	return chunks;
}

/** A raw image as one raw chunk (the last block padded with zeros, as libsparse does). */
export function rawChunks(blob: Blob, blockSize = 4096): { header: SparseHeader; chunks: Chunk[] } {
	const blocks = Math.ceil(blob.size / blockSize);
	const pad = blocks * blockSize - blob.size;
	const data: Part[] = [blob];
	if (pad) data.push(new Uint8Array(pad));
	return {
		header: { blockSize, totalBlocks: blocks, totalChunks: 1, fileHeaderSize: FILE_HEADER_SIZE, chunkHeaderSize: CHUNK_HEADER_SIZE },
		chunks: [{ type: ChunkType.Raw, blocks, data, dataSize: blocks * blockSize }],
	};
}

/** Byte range [start, end) of a list of parts. */
export function sliceParts(parts: Part[], start: number, end: number): Part[] {
	const out: Part[] = [];
	let off = 0;
	for (const p of parts) {
		const len = p instanceof Blob ? p.size : p.byteLength;
		const a = Math.max(start, off);
		const b = Math.min(end, off + len);
		if (a < b) out.push(p instanceof Blob ? p.slice(a - off, b - off) : p.subarray(a - off, b - off));
		off += len;
		if (off >= end) break;
	}
	return out;
}

function fileHeader(h: SparseHeader, chunks: number): Uint8Array {
	const b = new Uint8Array(FILE_HEADER_SIZE);
	const v = new DataView(b.buffer);
	v.setUint32(0, SPARSE_MAGIC, true);
	v.setUint16(4, 1, true);
	v.setUint16(6, 0, true);
	v.setUint16(8, FILE_HEADER_SIZE, true);
	v.setUint16(10, CHUNK_HEADER_SIZE, true);
	v.setUint32(12, h.blockSize, true);
	v.setUint32(16, h.totalBlocks, true);
	v.setUint32(20, chunks, true);
	v.setUint32(24, 0, true);
	return b;
}

function chunkHeader(type: ChunkType, blocks: number, dataSize: number): Uint8Array {
	const b = new Uint8Array(CHUNK_HEADER_SIZE);
	const v = new DataView(b.buffer);
	v.setUint16(0, type, true);
	v.setUint32(4, blocks, true);
	v.setUint32(8, CHUNK_HEADER_SIZE + dataSize, true);
	return b;
}

export interface Split extends Payload {
	/** Blocks this piece writes (raw and fill), for progress. */
	writesBlocks: number;
}

/**
 * Cuts a sparse image into sparse images of at most maxSize bytes each. Every piece covers the
 * whole partition: a leading and trailing don't-care chunk skip what other pieces write. Raw
 * chunks bigger than a piece are cut at block boundaries.
 */
export function splitSparse(header: SparseHeader, chunks: Chunk[], maxSize: number): Split[] {
	const bs = header.blockSize;
	// Room for the file header and a leading and trailing don't-care chunk
	const overhead = FILE_HEADER_SIZE + 2 * CHUNK_HEADER_SIZE;
	if (maxSize < overhead + CHUNK_HEADER_SIZE + bs) throw new ImageError(`The phone's download buffer (${maxSize} bytes) is too small`);
	const splits: Split[] = [];
	let cur: Chunk[] = [];
	let curSize = overhead;
	let startBlock = 0; // the first block cur covers
	let curBlocks = 0;

	const finish = () => {
		if (!cur.length) return;
		const parts: Part[] = [];
		const body: Part[] = [];
		let n = 0;
		if (startBlock > 0) {
			body.push(chunkHeader(ChunkType.DontCare, startBlock, 0));
			n++;
		}
		let writes = 0;
		for (const c of cur) {
			body.push(chunkHeader(c.type, c.blocks, c.dataSize), ...c.data);
			n++;
			if (c.type !== ChunkType.DontCare) writes += c.blocks;
		}
		const rest = header.totalBlocks - startBlock - curBlocks;
		if (rest > 0) {
			body.push(chunkHeader(ChunkType.DontCare, rest, 0));
			n++;
		}
		parts.push(fileHeader(header, n), ...body);
		splits.push({ ...payloadOf(parts), writesBlocks: writes });
		startBlock += curBlocks;
		cur = [];
		curSize = overhead;
		curBlocks = 0;
	};

	for (let c of chunks) {
		for (;;) {
			const need = CHUNK_HEADER_SIZE + c.dataSize;
			if (curSize + need <= maxSize) {
				// A don't-care chunk at the start or end of a piece is folded into the piece's own
				if (c.type === ChunkType.DontCare && cur.length === 0) {
					startBlock += c.blocks;
				} else {
					cur.push(c);
					curSize += need;
					curBlocks += c.blocks;
				}
				break;
			}
			if (c.type === ChunkType.Raw) {
				const fit = Math.floor((maxSize - curSize - CHUNK_HEADER_SIZE) / bs);
				if (fit >= 1) {
					const head: Chunk = { type: ChunkType.Raw, blocks: fit, data: sliceParts(c.data, 0, fit * bs), dataSize: fit * bs };
					cur.push(head);
					curSize += CHUNK_HEADER_SIZE + head.dataSize;
					curBlocks += fit;
					finish();
					c = { type: ChunkType.Raw, blocks: c.blocks - fit, data: sliceParts(c.data, fit * bs, c.dataSize), dataSize: c.dataSize - fit * bs };
					continue;
				}
			}
			if (!cur.length) throw new ImageError("A sparse chunk doesn't fit the phone's download buffer");
			finish();
		}
	}
	// Drop a trailing don't-care-only tail: it writes nothing
	while (cur.length && cur[cur.length - 1].type === ChunkType.DontCare) {
		const c = cur.pop()!;
		curSize -= CHUNK_HEADER_SIZE;
		curBlocks -= c.blocks;
	}
	finish();
	if (!splits.length) {
		// An image of nothing but don't-care: one piece that writes nothing, as the phone expects a flash
		splits.push({ ...payloadOf([fileHeader(header, 1), chunkHeader(ChunkType.DontCare, header.totalBlocks, 0)]), writesBlocks: 0 });
	}
	return splits;
}
