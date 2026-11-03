// The pieces of USB debugging below the handshake: messages read as a byte stream, the phone's
// banner, and this browser's key (its signatures checked with Node's own RSA, and its Android
// public key decoded the way adbd decodes it).

import { constants, createPrivateKey, createPublicKey, privateEncrypt, publicDecrypt, randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { AdbError } from "../src/adb/error.ts";
import { AdbKey, KEY_STORAGE_NAME, type KeyStorage, loadAdbKey } from "../src/adb/key.ts";
import { A_AUTH, A_CNXN, A_OKAY, A_WRTE, type AdbReadPipe, MessageReader, checksum, commandName, encodeHeader, parseBanner } from "../src/adb/message.ts";
import { parseAndroidPublicKey, verifyWithBigInt } from "./fake-adb.ts";

// The DER DigestInfo for SHA-1, written out here rather than taken from the code under test
const SHA1_PREFIX = Buffer.from("3021300906052b0e03021a05000414", "hex");

/** A pipe that hands out the given chunks, one per read. */
function chunks(...parts: Uint8Array[]): AdbReadPipe & { wants: number[] } {
	const wants: number[] = [];
	return {
		wants,
		async read(want: number) {
			wants.push(want);
			const p = parts.shift();
			if (!p) throw new AdbError("usb", "no more data");
			return p;
		},
	};
}

function message(command: number, arg0: number, arg1: number, payload: Uint8Array, withChecksum = true): Uint8Array {
	const h = encodeHeader({ command, arg0, arg1, payload }, withChecksum);
	const out = new Uint8Array(h.byteLength + payload.byteLength);
	out.set(h);
	out.set(payload, h.byteLength);
	return out;
}

describe("messages", () => {
	const banner = new TextEncoder().encode("device::ro.product.name=cheetah;ro.product.model=Pixel 7 Pro;ro.product.device=cheetah;features=shell_v2,cmd");

	it("writes the header as adb does: little-endian words, the byte sum, and the command's complement", () => {
		const h = encodeHeader({ command: A_CNXN, arg0: 0x01000001, arg1: 1024 * 1024, payload: new TextEncoder().encode("host::\0") }, true);
		expect(Buffer.from(h).toString("hex")).toBe(
			["434e584e", "01000001", "00001000", "07000000", "32020000", "bcb1a7b1"].join(""),
		);
		expect(checksum(new TextEncoder().encode("host::\0"))).toBe(0x232);
		expect(new DataView(encodeHeader({ command: A_OKAY, arg0: 1, arg1: 2, payload: Uint8Array.of(9) }, false).buffer).getUint32(16, true)).toBe(0);
		expect(commandName(A_AUTH)).toBe("AUTH");
		expect(commandName(0x12345678)).toBe("0x12345678");
	});

	it("reads a header and its payload whether they come together, apart or a byte at a time", async () => {
		const bytes = message(A_CNXN, 0x01000001, 4096, banner, false);
		for (const split of [[bytes], [bytes.subarray(0, 24), bytes.subarray(24)], [...bytes].map((b) => Uint8Array.of(b))]) {
			const r = new MessageReader(chunks(...split));
			const m = await r.next();
			expect(m.command).toBe(A_CNXN);
			expect(m.arg0).toBe(0x01000001);
			expect(m.arg1).toBe(4096);
			expect(new TextDecoder().decode(m.payload)).toContain("Pixel 7 Pro");
		}
	});

	it("keeps what came after a message for the next one, and skips zero-length packets", async () => {
		const a = message(A_OKAY, 7, 1, new Uint8Array(0));
		const b = message(A_AUTH, 1, 0, new Uint8Array(20).fill(3));
		const both = new Uint8Array(a.byteLength + b.byteLength);
		both.set(a);
		both.set(b, a.byteLength);
		const pipe = chunks(both.subarray(0, 30), new Uint8Array(0), both.subarray(30));
		const r = new MessageReader(pipe);
		expect((await r.next()).command).toBe(A_OKAY);
		const auth = await r.next();
		expect(auth.command).toBe(A_AUTH);
		expect(auth.payload).toEqual(new Uint8Array(20).fill(3));
		// It asks for what's still due, never more than one message's worth
		expect(pipe.wants).toEqual([24, 18, 18]);
	});

	it("takes a checksum of 0 or the right one, and nothing else", async () => {
		await expect(new MessageReader(chunks(message(A_CNXN, 0x01000000, 4096, banner, true))).next()).resolves.toMatchObject({ command: A_CNXN });
		await expect(new MessageReader(chunks(message(A_CNXN, 0x01000001, 4096, banner, false))).next()).resolves.toMatchObject({ command: A_CNXN });
		const bad = message(A_CNXN, 0x01000000, 4096, banner, true);
		new DataView(bad.buffer).setUint32(16, 12345, true);
		const err = await new MessageReader(chunks(bad)).next().catch((e) => e);
		expect(err).toBeInstanceOf(AdbError);
		expect((err as AdbError).kind).toBe("protocol");
		expect((err as AdbError).message).toMatch(/checksum doesn't match/);
	});

	it("fails at once on a bad header, without waiting for its payload", async () => {
		const badMagic = message(A_AUTH, 1, 0, new Uint8Array(20));
		badMagic[20] ^= 1;
		const tooLong = encodeHeader({ command: A_WRTE, arg0: 1, arg1: 1, payload: new Uint8Array(0) }, false);
		new DataView(tooLong.buffer).setUint32(12, 2 * 1024 * 1024, true);
		const unknown = encodeHeader({ command: 0x5a5a5a5a, arg0: 0, arg1: 0, payload: new Uint8Array(0) }, false);
		for (const [bytes, what] of [
			[badMagic.subarray(0, 24), /check value is wrong/],
			[tooLong, /more than the 1 MiB/],
			[unknown, /unknown kind \(ZZZZ\)/],
		] as const) {
			const pipe = chunks(bytes);
			const err = await new MessageReader(pipe).next().catch((e) => e);
			expect((err as AdbError).kind).toBe("protocol");
			expect((err as AdbError).message).toMatch(what);
			expect(pipe.wants).toHaveLength(1);
		}
	});

	it("gives up on a pipe that sends nothing but zero-length packets", async () => {
		const pipe: AdbReadPipe = { read: async () => new Uint8Array(0) };
		await expect(new MessageReader(pipe).next()).rejects.toMatchObject({ kind: "protocol" });
	});
});

describe("the phone's banner", () => {
	it("reads the codename, model, product name and features", () => {
		expect(parseBanner("device::ro.product.name=lineage_cheetah;ro.product.model=Pixel 7 Pro;ro.product.device=cheetah;features=shell_v2,cmd,abb")).toEqual({
			state: "device",
			device: "cheetah",
			model: "Pixel 7 Pro",
			name: "lineage_cheetah",
			features: ["shell_v2", "cmd", "abb"],
		});
	});

	it("reads the old ;-terminated form, NULs at the end and a serial in the middle", () => {
		expect(parseBanner("device::ro.product.name=husky;ro.product.model=Pixel 8 Pro;ro.product.device=husky;\0")).toMatchObject({
			device: "husky",
			model: "Pixel 8 Pro",
			name: "husky",
			features: [],
		});
		expect(parseBanner("recovery:28161FDH2000AB:ro.product.device=kodiak;features=a=b")).toMatchObject({ state: "recovery", device: "kodiak", features: ["a=b"] });
	});

	it("takes a banner with no properties", () => {
		expect(parseBanner("device::")).toEqual({ state: "device", device: "", model: "", name: "", features: [] });
		expect(parseBanner("sideload")).toMatchObject({ state: "sideload", device: "" });
		expect(parseBanner("")).toMatchObject({ state: "" });
	});
});

function memoryStorage(): KeyStorage & { data: Map<string, string> } {
	const data = new Map<string, string>();
	return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v) };
}

describe("this browser's key", () => {
	let key: AdbKey;
	beforeAll(async () => {
		key = await AdbKey.generate();
	});

	it("signs a token exactly as RSA_sign(NID_sha1) does, and Node's RSA checks it", () => {
		const priv = createPrivateKey({ key: key.jwk, format: "jwk" });
		const pub = createPublicKey(priv);
		for (let i = 0; i < 5; i++) {
			const token = randomBytes(20);
			const sig = key.sign(token);
			expect(sig.byteLength).toBe(256);
			// PKCS#1 v1.5 type 1 padding is deterministic: OpenSSL's own signature of DigestInfo + token
			expect(Buffer.from(sig).equals(privateEncrypt({ key: priv, padding: constants.RSA_PKCS1_PADDING }, Buffer.concat([SHA1_PREFIX, token])))).toBe(true);
			expect(publicDecrypt({ key: pub, padding: constants.RSA_PKCS1_PADDING }, sig).equals(Buffer.concat([SHA1_PREFIX, token]))).toBe(true);
		}
		expect(() => key.sign(new Uint8Array(19))).toThrow(AdbError);
	});

	it("gives the phone its public key in Android's format, which adbd decodes to the same key", () => {
		const raw = key.androidPublicKey();
		expect(raw.byteLength).toBe(524);
		const payload = key.publicKeyPayload("ExpressiveOS Flasher@expressiveos-flash.example");
		expect(payload[payload.byteLength - 1]).toBe(0);
		const text = new TextDecoder().decode(payload.subarray(0, -1));
		expect(text).toMatch(/^[A-Za-z0-9+/]+=* ExpressiveOS Flasher@expressiveos-flash\.example$/);
		const parsed = parseAndroidPublicKey(payload);
		if (typeof parsed === "string") throw new Error(parsed);
		expect(parsed.name).toBe("ExpressiveOS Flasher@expressiveos-flash.example");
		expect(parsed.exponent).toBe(65537);
		expect(Buffer.from(parsed.modulus).toString("base64url")).toBe(key.jwk.n);
		// The fake phone's own check agrees with Node's
		const token = randomBytes(20);
		expect(verifyWithBigInt(parsed, token, key.sign(token))).toBe(true);
		expect(verifyWithBigInt(parsed, randomBytes(20), key.sign(token))).toBe(false);
	});

	it("keeps a name to printable text", () => {
		const text = new TextDecoder().decode(key.publicKeyPayload("Flasher\n@host\0x"));
		expect(text.endsWith(" Flasher@hostx\0")).toBe(true);
	});

	it("is kept in storage and found there next time", async () => {
		const storage = memoryStorage();
		const a = await loadAdbKey(storage);
		expect(JSON.parse(storage.data.get(KEY_STORAGE_NAME)!)).toMatchObject({ kty: "RSA", n: a.jwk.n });
		const b = await loadAdbKey(storage);
		expect(b.jwk.n).toBe(a.jwk.n);
	});

	it("is one key for two tabs that make it at the same time, in a browser without Web Locks", async () => {
		const storage = memoryStorage();
		// Each tab finds nothing kept, and makes a key: the one kept first is the one both use
		const [a, b] = await Promise.all([loadAdbKey(storage), loadAdbKey(storage)]);
		expect(b.jwk.n).toBe(a.jwk.n);
		expect(JSON.parse(storage.data.get(KEY_STORAGE_NAME)!).n).toBe(a.jwk.n);
	});

	it("is loaded or made by one tab at a time, under a Web Lock, or without it where the page can't take it", async () => {
		const storage = memoryStorage();
		const names: string[] = [];
		let queue: Promise<unknown> = Promise.resolve();
		let inside = 0;
		let most = 0;
		const locks = {
			request: (name: string, work: () => Promise<unknown>): Promise<unknown> => {
				names.push(name);
				const run = queue.then(async () => {
					most = Math.max(most, ++inside);
					try {
						return await work();
					} finally {
						inside--;
					}
				});
				queue = run.catch(() => {});
				return run;
			},
		};
		vi.stubGlobal("navigator", { locks });
		try {
			const [a, b] = await Promise.all([loadAdbKey(storage), loadAdbKey(storage)]);
			expect(names).toEqual([KEY_STORAGE_NAME, KEY_STORAGE_NAME]);
			expect(most).toBe(1);
			expect(b.jwk.n).toBe(a.jwk.n);
			locks.request = () => Promise.reject(new DOMException("The request is not allowed.", "SecurityError"));
			expect((await loadAdbKey(storage)).jwk.n).toBe(a.jwk.n);
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it("makes a new key when the stored one is damaged, and works with no storage at all", async () => {
		const storage = memoryStorage();
		storage.data.set(KEY_STORAGE_NAME, "{not json");
		const a = await loadAdbKey(storage);
		expect(JSON.parse(storage.data.get(KEY_STORAGE_NAME)!).n).toBe(a.jwk.n);

		// A key whose private half doesn't match its public half is never used
		storage.data.set(KEY_STORAGE_NAME, JSON.stringify({ ...key.jwk, dp: a.jwk.dp }));
		const b = await loadAdbKey(storage);
		expect(b.jwk.n).not.toBe(key.jwk.n);

		const blocked: KeyStorage = {
			getItem() {
				throw new DOMException("The operation is insecure.", "SecurityError");
			},
			setItem() {
				throw new DOMException("The quota has been exceeded.", "QuotaExceededError");
			},
		};
		const c = await loadAdbKey(blocked);
		const d = await loadAdbKey(null);
		expect(c.sign(new Uint8Array(20)).byteLength).toBe(256);
		expect(d.jwk.n).not.toBe(c.jwk.n);
	});

	it("only takes RSA-2048 keys with e = 65537", async () => {
		expect(AdbKey.fromJwk(key.jwk)).not.toBeNull();
		expect(AdbKey.fromJwk({ ...key.jwk, kty: "EC" })).toBeNull();
		expect(AdbKey.fromJwk({ ...key.jwk, qi: undefined })).toBeNull();
		const small = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent: Uint8Array.of(1, 0, 1), hash: "SHA-256" }, true, ["sign"]);
		expect(AdbKey.fromJwk(await crypto.subtle.exportKey("jwk", small.privateKey))).toBeNull();
		const e3 = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: Uint8Array.of(3), hash: "SHA-256" }, true, ["sign"]);
		expect(AdbKey.fromJwk(await crypto.subtle.exportKey("jwk", e3.privateKey))).toBeNull();
	});
});
