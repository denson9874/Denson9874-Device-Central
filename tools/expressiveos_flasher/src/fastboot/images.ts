// Turning an image file into what is sent to the phone, as AOSP fastboot does: small images go in
// one download, big ones are cut into sparse pieces; a raw image smaller than its (physical)
// partition gets its AVB footer moved to the partition's end, where the bootloader looks for it.

import { type Payload, payloadOf } from "./client.ts";
import { FILE_HEADER_SIZE, type Split, parseSparseHeader, rawChunks, readSparseChunks, splitSparse } from "./sparse.ts";

/** AOSP fastboot never sends more than 1 GiB in one download when it has to cut an image. */
export const RESPARSE_LIMIT = 1024 * 1024 * 1024;

export const AVB_FOOTER_SIZE = 64;
const AVB_FOOTER_MAGIC = [0x41, 0x56, 0x42, 0x66]; // "AVBf"

export interface ImageInfo {
	sparse: boolean;
	/** Bytes the image takes on the partition (a sparse image's expanded size). */
	imageSize: number;
}

export async function imageInfo(blob: Blob): Promise<ImageInfo> {
	const head = new Uint8Array(await blob.slice(0, FILE_HEADER_SIZE).arrayBuffer());
	const h = parseSparseHeader(head);
	if (h) return { sparse: true, imageSize: h.totalBlocks * h.blockSize };
	return { sparse: false, imageSize: blob.size };
}

/**
 * copy_avb_footer(): when a raw image is smaller than its physical partition and ends with an AVB
 * footer, the footer must also sit in the partition's last 64 bytes.
 */
export async function moveAvbFooter(blob: Blob, partitionSize: number): Promise<Blob> {
	if (blob.size < AVB_FOOTER_SIZE || !(partitionSize > blob.size)) return blob;
	const footer = new Uint8Array(await blob.slice(blob.size - AVB_FOOTER_SIZE).arrayBuffer());
	if (!AVB_FOOTER_MAGIC.every((b, i) => footer[i] === b)) return blob;
	const gap = partitionSize - AVB_FOOTER_SIZE - blob.size;
	// The image as it is, zeros up to the partition's last 64 bytes, and the footer there
	return new Blob(gap >= 0 ? [blob, new Uint8Array(gap), footer] : [blob.slice(0, partitionSize - AVB_FOOTER_SIZE), footer]);
}

export interface FlashPayloads {
	info: ImageInfo;
	pieces: Array<Payload | Split>;
}

/** What to download for one flash: the image whole if it fits maxDownload, else sparse pieces. */
export async function flashPayloads(blob: Blob, maxDownload: number): Promise<FlashPayloads> {
	const head = new Uint8Array(await blob.slice(0, FILE_HEADER_SIZE).arrayBuffer());
	const header = parseSparseHeader(head);
	const info: ImageInfo = header ? { sparse: true, imageSize: header.totalBlocks * header.blockSize } : { sparse: false, imageSize: blob.size };
	if (blob.size <= maxDownload) return { info, pieces: [payloadOf([blob])] };
	const limit = Math.min(maxDownload, RESPARSE_LIMIT);
	if (header) return { info, pieces: splitSparse(header, await readSparseChunks(blob, header), limit) };
	const raw = rawChunks(blob);
	return { info, pieces: splitSparse(raw.header, raw.chunks, limit) };
}
