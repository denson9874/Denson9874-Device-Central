// This browser's key for USB debugging: an RSA-2048 key (e = 65537), made with WebCrypto and kept
// in the browser, so a phone told "Always allow from this computer" knows it next time.
//
// adb answers a phone's AUTH token with RSA_sign(NID_sha1, token, 20, ...) (client_auth.cpp): a
// PKCS#1 v1.5 signature that takes the 20-byte token as if it were a SHA-1 digest. WebCrypto only
// signs what it hashes itself, so the signature is computed here with BigInt from the key's JWK
// (CRT from p, q, dp, dq and qi). The public key goes to the phone in Android's own format
// (libcrypto_utils' android_pubkey.cpp).

import { AdbError } from "./error.ts";
import { TOKEN_SIZE } from "./message.ts";

const MODULUS_BYTES = 256;
const EXPONENT = 65537n;
/** Android's RSAPublicKey struct: words, n0inv, modulus, rr, exponent. */
export const ANDROID_PUBKEY_SIZE = 4 + 4 + MODULUS_BYTES + MODULUS_BYTES + 4;
/** DER of DigestInfo for SHA-1, ahead of the 20 digest bytes. */
export const SHA1_DIGEST_INFO = Uint8Array.of(0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14);

/** Where the key is kept: localStorage's shape, so it can be passed as is. */
export interface KeyStorage {
	getItem(key: string): string | null;
	setItem(key: string, value: string): void;
}

export const KEY_STORAGE_NAME = "eos-flasher-adb-key";

function b64urlToBytes(s: string): Uint8Array {
	const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
	const bin = atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
	return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function bytesToBigInt(b: Uint8Array): bigint {
	let hex = "";
	for (const x of b) hex += x.toString(16).padStart(2, "0");
	return hex ? BigInt(`0x${hex}`) : 0n;
}

function bigIntToBytes(x: bigint, length: number, littleEndian = false): Uint8Array {
	const hex = x.toString(16).padStart(length * 2, "0");
	if (hex.length > length * 2) throw new RangeError("number too big");
	const out = new Uint8Array(length);
	for (let i = 0; i < length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
	return littleEndian ? out.reverse() : out;
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
	let result = 1n;
	let b = base % mod;
	let e = exp;
	while (e > 0n) {
		if (e & 1n) result = (result * b) % mod;
		e >>= 1n;
		if (e) b = (b * b) % mod;
	}
	return result;
}

/** EMSA-PKCS1-v1_5 of a SHA-1 "digest": 00 01 FF..FF 00, DigestInfo, the 20 bytes. */
export function pkcs1Sha1(digest: Uint8Array): Uint8Array {
	const em = new Uint8Array(MODULUS_BYTES).fill(0xff);
	em[0] = 0x00;
	em[1] = 0x01;
	const t = MODULUS_BYTES - SHA1_DIGEST_INFO.byteLength - digest.byteLength;
	em[t - 1] = 0x00;
	em.set(SHA1_DIGEST_INFO, t);
	em.set(digest, t + SHA1_DIGEST_INFO.byteLength);
	return em;
}

/** -1 / n mod 2^32, for an odd n (Newton's iteration doubles the correct bits each step). */
function n0inv(n: bigint): number {
	const a = BigInt.asUintN(32, n);
	let x = a;
	for (let i = 0; i < 5; i++) x = BigInt.asUintN(32, x * (2n - a * x));
	return Number(BigInt.asUintN(32, -x));
}

interface RsaNumbers {
	n: bigint;
	e: bigint;
	p: bigint;
	q: bigint;
	dp: bigint;
	dq: bigint;
	qi: bigint;
}

type PrivateJwk = Required<Pick<JsonWebKey, "kty" | "n" | "e" | "d" | "p" | "q" | "dp" | "dq" | "qi">>;

export class AdbKey {
	private constructor(
		/** The private key, as kept in storage. */
		readonly jwk: PrivateJwk,
		private readonly k: RsaNumbers,
	) {}

	/** A new key. */
	static async generate(): Promise<AdbKey> {
		const pair = await crypto.subtle.generateKey(
			{ name: "RSASSA-PKCS1-v1_5", modulusLength: MODULUS_BYTES * 8, publicExponent: Uint8Array.of(1, 0, 1), hash: "SHA-256" },
			true,
			["sign", "verify"],
		);
		const key = AdbKey.fromJwk(await crypto.subtle.exportKey("jwk", pair.privateKey));
		if (!key) throw new Error("This browser made a key for USB debugging that doesn't work.");
		return key;
	}

	/** A key from its JWK, or null when it isn't a whole, working RSA-2048 key with e = 65537. */
	static fromJwk(jwk: JsonWebKey): AdbKey | null {
		try {
			if (jwk.kty !== "RSA") return null;
			const { n, e, d, p, q, dp, dq, qi } = jwk;
			if (!n || !e || !d || !p || !q || !dp || !dq || !qi) return null;
			const nb = b64urlToBytes(n);
			if (nb.byteLength !== MODULUS_BYTES || nb[0] < 0x80) return null;
			const nums: RsaNumbers = {
				n: bytesToBigInt(nb),
				e: bytesToBigInt(b64urlToBytes(e)),
				p: bytesToBigInt(b64urlToBytes(p)),
				q: bytesToBigInt(b64urlToBytes(q)),
				dp: bytesToBigInt(b64urlToBytes(dp)),
				dq: bytesToBigInt(b64urlToBytes(dq)),
				qi: bytesToBigInt(b64urlToBytes(qi)),
			};
			if (nums.e !== EXPONENT || nums.p * nums.q !== nums.n) return null;
			const key = new AdbKey({ kty: "RSA", n, e, d, p, q, dp, dq, qi }, nums);
			// sign() checks its own result, so this proves the private numbers match the public ones
			key.sign(new Uint8Array(TOKEN_SIZE));
			return key;
		} catch {
			return null;
		}
	}

	/** The signature adb sends for a phone's AUTH token (256 bytes). */
	sign(token: Uint8Array): Uint8Array {
		if (token.byteLength !== TOKEN_SIZE) throw new AdbError("protocol", `USB debugging on the phone sent something this page can't read: a token of ${token.byteLength} bytes instead of ${TOKEN_SIZE}. Unplug the phone, plug it back in and try again.`);
		const { n, e, p, q, dp, dq, qi } = this.k;
		const m = bytesToBigInt(pkcs1Sha1(token));
		const m1 = modPow(m, dp, p);
		const m2 = modPow(m, dq, q);
		const h = (qi * (((m1 - m2) % p) + p)) % p;
		const s = m2 + h * q;
		// A fault in the arithmetic (or a damaged key) mustn't reach the phone
		if (modPow(s, e, n) !== m) throw new Error("The key for USB debugging gave a signature that doesn't check out.");
		return bigIntToBytes(s, MODULUS_BYTES);
	}

	/** The public key in Android's RSAPublicKey layout (android_pubkey_encode). */
	androidPublicKey(): Uint8Array {
		const { n, e } = this.k;
		const out = new Uint8Array(ANDROID_PUBKEY_SIZE);
		const v = new DataView(out.buffer);
		v.setUint32(0, MODULUS_BYTES / 4, true);
		v.setUint32(4, n0inv(n), true);
		out.set(bigIntToBytes(n, MODULUS_BYTES, true), 8);
		// R^2 mod n, R = 2^2048
		out.set(bigIntToBytes((1n << BigInt(MODULUS_BYTES * 8 * 2)) % n, MODULUS_BYTES, true), 8 + MODULUS_BYTES);
		v.setUint32(8 + 2 * MODULUS_BYTES, Number(e), true);
		return out;
	}

	/**
	 * AUTH RSAPUBLICKEY's payload: the key in base64, a space, the name the phone files it under,
	 * and a NUL (client_auth.cpp's send_auth_publickey).
	 */
	publicKeyPayload(name: string): Uint8Array {
		const bin = String.fromCharCode(...this.androidPublicKey());
		const clean = name.replace(/[^\x20-\x7e]/g, "").trim() || "ExpressiveOS Flasher";
		return new TextEncoder().encode(`${btoa(bin)} ${clean}\0`);
	}
}

/** localStorage, when the browser lets the page use it. */
export function browserStorage(): KeyStorage | null {
	try {
		return typeof localStorage === "undefined" ? null : localStorage;
	} catch {
		return null;
	}
}

/**
 * The key kept in `storage`, or a new one (kept there when it can be). Without storage this is a
 * fresh key each time, which only means the phone asks "Allow USB debugging?" again.
 *
 * Tabs share the storage, and making a key takes a moment: two tabs that each made their own would
 * each keep using theirs, though only the last one written is found next time, and a phone told to
 * always allow the other would ask again. So one tab at a time loads or makes it, under a Web Lock,
 * and a key another tab kept meanwhile (in a browser without Web Locks) is taken over this one's.
 */
export async function loadAdbKey(storage: KeyStorage | null = browserStorage()): Promise<AdbKey> {
	let ran = false;
	const run = () => {
		ran = true;
		return loadOrMake(storage);
	};
	const locks = typeof navigator === "undefined" ? undefined : navigator.locks;
	if (!storage || !locks) return run();
	try {
		return await locks.request(KEY_STORAGE_NAME, run);
	} catch (e) {
		// A page that may not take the lock still loads the key, without it
		if (ran) throw e;
		return run();
	}
}

/** The valid key in `storage`, if there is one. */
function storedKey(storage: KeyStorage | null): AdbKey | null {
	try {
		const saved = storage?.getItem(KEY_STORAGE_NAME);
		return saved ? AdbKey.fromJwk(JSON.parse(saved) as JsonWebKey) : null;
	} catch {
		/* unreadable: as good as none */
		return null;
	}
}

async function loadOrMake(storage: KeyStorage | null): Promise<AdbKey> {
	const saved = storedKey(storage);
	if (saved) return saved;
	const key = await AdbKey.generate();
	// Nothing awaits between this read and the write, so no other key lands in between from this page
	const kept = storedKey(storage);
	if (kept) return kept;
	try {
		storage?.setItem(KEY_STORAGE_NAME, JSON.stringify(key.jwk));
	} catch {
		/* storage full or blocked: the key lasts as long as the page */
	}
	return key;
}

let pageKey: Promise<AdbKey> | null = null;

/** This browser's key, loaded or made once per page. */
export function browserAdbKey(): Promise<AdbKey> {
	pageKey ??= loadAdbKey().catch((e) => {
		pageKey = null;
		throw e;
	});
	return pageKey;
}

/** The name a phone shows for this browser's key under Developer options. */
export function defaultKeyName(): string {
	let host = "";
	try {
		host = typeof location === "undefined" ? "" : location.hostname;
	} catch {
		/* no location */
	}
	return `ExpressiveOS Flasher@${host || "browser"}`;
}
