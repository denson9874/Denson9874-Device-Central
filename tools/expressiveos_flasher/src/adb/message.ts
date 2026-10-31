// The ADB wire format, from AOSP's system/core/adb (protocol.txt, adb.h, adb.cpp, transport.cpp):
// 24-byte little-endian message headers with an optional payload, read as a byte stream from a
// USB bulk pipe, and the banner a phone sends in its CNXN.

import { malformed } from "./error.ts";

export const A_SYNC = 0x434e5953;
export const A_CNXN = 0x4e584e43;
export const A_AUTH = 0x48545541;
export const A_OPEN = 0x4e45504f;
export const A_OKAY = 0x59414b4f;
export const A_CLSE = 0x45534c43;
export const A_WRTE = 0x45545257;
export const A_STLS = 0x534c5453;

const KNOWN = new Set([A_SYNC, A_CNXN, A_AUTH, A_OPEN, A_OKAY, A_CLSE, A_WRTE, A_STLS]);

/** The original version: every payload carries a checksum. */
export const A_VERSION_MIN = 0x01000000;
/** From this version on (Dec 2017), checksums are skipped once both sides have said so. */
export const A_VERSION_SKIP_CHECKSUM = 0x01000001;
export const A_VERSION = 0x01000001;

/** What a CNXN or AUTH may carry before the phone has said how much it takes. */
export const MAX_PAYLOAD_V1 = 4 * 1024;
/** The most this side takes, as it says in its CNXN. */
export const MAX_PAYLOAD = 1024 * 1024;

export const HEADER_SIZE = 24;

// AUTH's first argument
export const AUTH_TOKEN = 1;
export const AUTH_SIGNATURE = 2;
export const AUTH_RSAPUBLICKEY = 3;
export const TOKEN_SIZE = 20;

export interface AdbMessage {
	command: number;
	arg0: number;
	arg1: number;
	payload: Uint8Array;
}

/** The old checksum: the sum of the payload's bytes. */
export function checksum(payload: Uint8Array): number {
	let sum = 0;
	for (let i = 0; i < payload.byteLength; i++) sum += payload[i];
	return sum >>> 0;
}

/** CNXN, OKAY and so on, or the number in hex when it isn't text. */
export function commandName(command: number): string {
	const s = String.fromCharCode(command & 0xff, (command >>> 8) & 0xff, (command >>> 16) & 0xff, (command >>> 24) & 0xff);
	return /^[A-Z]{4}$/.test(s) ? s : `0x${(command >>> 0).toString(16).padStart(8, "0")}`;
}

/** A message's header; the checksum is left at 0 once both sides skip it. */
export function encodeHeader(m: AdbMessage, withChecksum: boolean): Uint8Array {
	const b = new Uint8Array(HEADER_SIZE);
	const v = new DataView(b.buffer);
	v.setUint32(0, m.command >>> 0, true);
	v.setUint32(4, m.arg0 >>> 0, true);
	v.setUint32(8, m.arg1 >>> 0, true);
	v.setUint32(12, m.payload.byteLength, true);
	v.setUint32(16, withChecksum ? checksum(m.payload) : 0, true);
	v.setUint32(20, (m.command ^ 0xffffffff) >>> 0, true);
	return b;
}

/** One side of a USB bulk pipe, as the reader needs it. */
export interface AdbReadPipe {
	/**
	 * One bulk IN transfer that may hold `want` bytes or more (the pipe asks for whole packets).
	 * It can return less, and a zero-length packet returns nothing.
	 */
	read(want: number): Promise<Uint8Array>;
}

// A phone that sends nothing but zero-length packets is broken, not slow
const MAX_EMPTY_READS = 64;

/**
 * Reads messages from the pipe as a byte stream: a header and its payload may come in one
 * transfer or several, and a transfer may end inside a header. The header is checked before its
 * payload is read, so a malformed one fails at once instead of waiting for bytes that never come.
 * A payload's checksum may be 0 (skipped, as a phone at version 0x01000001 sends) or the sum.
 */
export class MessageReader {
	private buf = new Uint8Array(0);
	private off = 0;

	constructor(private readonly pipe: AdbReadPipe) {}

	async next(): Promise<AdbMessage> {
		const h = new DataView((await this.take(HEADER_SIZE)).buffer);
		const command = h.getUint32(0, true);
		const length = h.getUint32(12, true);
		const check = h.getUint32(16, true);
		if (h.getUint32(20, true) !== (command ^ 0xffffffff) >>> 0) throw malformed("a message header whose check value is wrong");
		if (!KNOWN.has(command)) throw malformed(`a message of an unknown kind (${commandName(command)})`);
		if (length > MAX_PAYLOAD) throw malformed(`a ${commandName(command)} message of ${length} bytes, more than the 1 MiB this page takes`);
		const payload = length ? await this.take(length) : new Uint8Array(0);
		if (check !== 0 && check !== checksum(payload)) throw malformed(`a ${commandName(command)} message whose checksum doesn't match`);
		return { command, arg0: h.getUint32(4, true), arg1: h.getUint32(8, true), payload };
	}

	private async take(n: number): Promise<Uint8Array> {
		let empty = 0;
		while (this.buf.byteLength - this.off < n) {
			const chunk = await this.pipe.read(n - (this.buf.byteLength - this.off));
			if (chunk.byteLength === 0) {
				if (++empty > MAX_EMPTY_READS) throw malformed("nothing but empty USB packets");
				continue;
			}
			empty = 0;
			const rest = this.buf.subarray(this.off);
			const joined = new Uint8Array(rest.byteLength + chunk.byteLength);
			joined.set(rest);
			joined.set(chunk, rest.byteLength);
			this.buf = joined;
			this.off = 0;
		}
		const out = this.buf.slice(this.off, this.off + n);
		this.off += n;
		return out;
	}
}

/** What a phone says about itself in its CNXN. */
export interface AdbBanner {
	/** "device", "recovery", "sideload", "rescue" or "bootloader". */
	state: string;
	/** ro.product.device, the codename, such as cheetah. */
	device: string;
	/** ro.product.model, such as Pixel 7 Pro. */
	model: string;
	/** ro.product.name, the build's product, such as cheetah or lineage_cheetah. */
	name: string;
	features: string[];
}

/**
 * "device::ro.product.name=x;ro.product.model=y;ro.product.device=z;features=a,b", as adb.cpp's
 * parse_banner reads it: the properties were once ;-terminated rather than ;-separated, and
 * a payload may end in NULs.
 */
export function parseBanner(text: string): AdbBanner {
	const banner = text.split("\0")[0];
	const first = banner.indexOf(":");
	const state = first < 0 ? banner : banner.slice(0, first);
	const rest = first < 0 ? "" : banner.slice(first + 1);
	const second = rest.indexOf(":");
	const props = second < 0 ? "" : rest.slice(second + 1);
	const out: AdbBanner = { state, device: "", model: "", name: "", features: [] };
	for (const prop of props.split(";")) {
		const eq = prop.indexOf("=");
		if (eq < 0) continue;
		const key = prop.slice(0, eq);
		const value = prop.slice(eq + 1);
		if (key === "ro.product.name") out.name = value;
		else if (key === "ro.product.model") out.model = value;
		else if (key === "ro.product.device") out.device = value;
		else if (key === "features") out.features = value.split(",").filter(Boolean);
	}
	return out;
}
