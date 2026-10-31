// Restarting a phone that runs Android into Fastboot Mode over USB debugging, against a simulated
// adbd (test/fake-adb.ts) behind a composite USB device. Signatures are checked with Node's RSA.

import { constants, createPublicKey, publicDecrypt } from "node:crypto";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { ADB_FILTER, AdbError, type ConnectOptions, connectAdb, isAdbDevice } from "../src/adb/adb.ts";
import { AdbKey } from "../src/adb/key.ts";
import { adbOpenFailure } from "../src/adb/usb.ts";
import { ADB_COMMANDS, FakeAdbPhone, type FakeAdbOptions, type HostMessage, type VerifySignature } from "./fake-adb.ts";

const { A_AUTH, A_CNXN, A_STLS, A_WRTE } = ADB_COMMANDS;
const SHA1_PREFIX = Buffer.from("3021300906052b0e03021a05000414", "hex");

/** adbd's RSA_verify(NID_sha1, token, 20, sig, key), done by Node: the signature opens to DigestInfo + token. */
const nodeVerify: VerifySignature = (key, token, signature) => {
	const pub = createPublicKey({ key: { kty: "RSA", n: Buffer.from(key.modulus).toString("base64url"), e: "AQAB" }, format: "jwk" });
	try {
		return publicDecrypt({ key: pub, padding: constants.RSA_PKCS1_PADDING }, signature).equals(Buffer.concat([SHA1_PREFIX, token]));
	} catch {
		return false;
	}
};

let key: AdbKey;
let otherKey: AdbKey;
const b64 = (k: AdbKey) => Buffer.from(k.androidPublicKey()).toString("base64");

beforeAll(async () => {
	[key, otherKey] = await Promise.all([AdbKey.generate(), AdbKey.generate()]);
});

const phones: FakeAdbPhone[] = [];

function phone(o: FakeAdbOptions = {}): FakeAdbPhone {
	const p = new FakeAdbPhone({ verifySignature: nodeVerify, ...o });
	phones.push(p);
	return p;
}

afterEach(() => {
	// Whatever a test did, the page never opened a service but the restart
	for (const p of phones) for (const s of p.opened) expect(s).toBe("reboot:bootloader");
	phones.length = 0;
});

function opts(o: ConnectOptions = {}): ConnectOptions {
	return { key, keyName: "ExpressiveOS Flasher@test", answerTimeoutMs: 1000, allowTimeoutMs: 2000, settleMs: 50, os: "linux", ...o };
}

const kinds = (p: FakeAdbPhone) => p.received.map((m) => (m.command === "AUTH" ? `AUTH ${m.arg0}` : m.command));
const sum = (b: Uint8Array) => b.reduce((a, x) => a + x, 0);

function expectClosed(p: FakeAdbPhone) {
	expect(p.usb.calls.slice(-2)).toEqual(["releaseInterface 1", "close"]);
	expect(p.usb.opened).toBe(false);
}

describe("finding the phone", () => {
	it("knows a phone with USB debugging on by its ADB interface among the others", () => {
		expect(ADB_FILTER).toEqual({ classCode: 0xff, subclassCode: 0x42, protocolCode: 0x01 });
		expect(isAdbDevice(phone().usb.usb)).toBe(true);
		const fastboot = {
			configurations: [{ configurationValue: 1, interfaces: [{ interfaceNumber: 0, alternates: [{ alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x03, endpoints: [] }] }] }],
		} as unknown as USBDevice;
		expect(isAdbDevice(fastboot)).toBe(false);
	});

	it("rejects a device without the ADB interface", async () => {
		const err = await connectAdb({ configurations: [] } as unknown as USBDevice, opts()).catch((e) => e);
		expect(err).toMatchObject({ kind: "usb" });
	});
});

describe("a phone that knows this browser's key", () => {
	it("connects with one signature, reads the phone from its banner, and restarts it into Fastboot Mode", async () => {
		const p = phone({ trustedKeys: [b64(key)], device: "husky", model: "Pixel 8 Pro", name: "expressive_husky", serial: "35021FDH300ABC" });
		let prompted = 0;
		const c = await connectAdb(p.usb.usb, opts({ onAllowPrompt: () => prompted++ }));
		expect(c).toMatchObject({ serial: "35021FDH300ABC", product: "husky", model: "Pixel 8 Pro", name: "expressive_husky", state: "device" });
		expect(c.features).toContain("shell_v2");
		expect(prompted).toBe(0);
		expect(kinds(p)).toEqual(["CNXN", "AUTH 2"]);
		expect(p.prompts).toHaveLength(0);
		// The page's CNXN: the newest version, 1 MiB, and adb's plain host banner
		expect(p.received[0]).toMatchObject({ arg0: 0x01000001, arg1: 1024 * 1024 });
		expect(new TextDecoder().decode(p.received[0].payload)).toBe("host::\0");
		// The composite phone is already configured, and stays so; only the ADB interface is claimed
		expect(p.usb.calls).toEqual(["open", "claimInterface 1"]);

		await c.rebootToBootloader();
		expect(p.opened).toEqual(["reboot:bootloader"]);
		expect(p.mode).toBe("bootloader");
		const open = p.received.find((m) => m.command === "OPEN")!;
		expect(open).toMatchObject({ arg0: 1, arg1: 0, check: 0 });
		expect(new TextDecoder().decode(open.payload)).toBe("reboot:bootloader\0");
		expect(p.violations).toEqual([]);
		// Every header went as a transfer of its own, and no zero-length packet was needed at 512 bytes
		expect(p.usb.zlps).toBe(0);
		expect(p.usb.emptyBlocks).toBe(0);
		expect(p.usb.writes.filter((n) => n === 24).length).toBe(p.received.length);
		expectClosed(p);
		await c.close();
	});

	it("checksums everything for an older adbd (version 0x01000000), and takes its checksums", async () => {
		const p = phone({ trustedKeys: [b64(key)], version: 0x01000000, maxPayload: 4096 });
		const c = await connectAdb(p.usb.usb, opts());
		await c.rebootToBootloader();
		expect(p.violations).toEqual([]);
		const open = p.received.find((m) => m.command === "OPEN")!;
		expect(open.check).toBe(sum(open.payload));
		expect(p.mode).toBe("bootloader");
	});

	it("checksums what it sends before the phone's version is known, and not after", async () => {
		const p = phone({ trustedKeys: [b64(key)] });
		const c = await connectAdb(p.usb.usb, opts());
		await c.rebootToBootloader();
		for (const m of p.received) expect(m.check).toBe(m.command === "CNXN" || m.command === "AUTH" ? sum(m.payload) : 0);
	});

	it("works at full speed, where its 256-byte signature fills four packets and needs a zero-length one", async () => {
		const p = phone({ trustedKeys: [b64(key)], packetSize: 64 });
		const c = await connectAdb(p.usb.usb, opts());
		expect(p.usb.zlps).toBe(1);
		expect(p.usb.emptyBlocks).toBe(0);
		await c.rebootToBootloader();
		expect(p.violations).toEqual([]);
		expect(p.mode).toBe("bootloader");
	});

	for (const [what, o] of [
		["header and payload in one transfer", { joined: true }],
		["zero-length packets after full ones", { zlp: true, packetSize: 64 }],
		["header and payload in one transfer with zero-length packets, at super speed", { joined: true, zlp: true, packetSize: 1024 }],
		["its ADB interface in an alternate setting", { alternate: 1 }],
	] as const) {
		it(`reads a phone that sends ${what}`, async () => {
			const p = phone({ trustedKeys: [b64(key)], ...o });
			const c = await connectAdb(p.usb.usb, opts());
			expect(c.product).toBe("cheetah");
			await c.rebootToBootloader();
			expect(p.violations).toEqual([]);
			expect(p.mode).toBe("bootloader");
			if ("alternate" in o) expect(p.usb.calls).toContain("selectAlternateInterface 1 1");
		});
	}

	it("reads a message that ends on a packet boundary with no zero-length packet after it", async () => {
		// A read longer than what's due would wait for packets the phone won't send until the page
		// answers, so the banner is padded to end exactly at a packet's end
		for (const joined of [false, true]) {
			const base = new FakeAdbPhone({ features: "" }).banner.length + (joined ? 24 : 0);
			const pad = "x".repeat(64 - (base % 64) + 64);
			const p = phone({ trustedKeys: [b64(key)], packetSize: 64, joined, features: pad });
			expect((p.banner.length + (joined ? 24 : 0)) % 64).toBe(0);
			const c = await connectAdb(p.usb.usb, opts({ answerTimeoutMs: 500 }));
			expect(c.features).toEqual([pad]);
			await c.rebootToBootloader();
			expect(p.violations).toEqual([]);
		}
	});

	it("connects to a phone that doesn't ask for a key at all", async () => {
		const p = phone({ authRequired: false });
		const c = await connectAdb(p.usb.usb, opts());
		expect(kinds(p)).toEqual(["CNXN"]);
		await c.rebootToBootloader();
		expect(p.mode).toBe("bootloader");
	});
});

describe("a phone that doesn't know the key yet", () => {
	it("offers the key after the phone turns down its signature, says the phone is asking, and goes on once the user allows it", async () => {
		// It trusts another computer's key, not this browser's
		const p = phone({ answer: "allow", answerDelayMs: 50, trustedKeys: [b64(otherKey)] });
		let prompted = 0;
		const c = await connectAdb(p.usb.usb, opts({ onAllowPrompt: () => prompted++ }));
		expect(prompted).toBe(1);
		expect(kinds(p)).toEqual(["CNXN", "AUTH 2", "AUTH 3"]);
		expect(p.prompts).toHaveLength(1);
		expect(p.prompts[0].name).toBe("ExpressiveOS Flasher@test");
		expect(p.prompts[0].base64).toBe(b64(key));
		expect(p.tokens).toBe(2);
		await c.rebootToBootloader();
		expect(p.opened).toEqual(["reboot:bootloader"]);
		expect(p.violations).toEqual([]);
	});

	it("signs straight away next time once the user ticked Always allow", async () => {
		const p = phone({ answer: "always" });
		await (await connectAdb(p.usb.usb, opts())).close();
		expect(p.prompts).toHaveLength(1);
		p.received.length = 0;
		let prompted = 0;
		const again = await connectAdb(p.usb.usb, opts({ onAllowPrompt: () => prompted++ }));
		expect(kinds(p)).toEqual(["CNXN", "AUTH 2"]);
		expect(prompted).toBe(0);
		expect(p.prompts).toHaveLength(1);
		await again.rebootToBootloader();
		expect(p.mode).toBe("bootloader");
	});

	it("is asked again next time when the user allowed it only once", async () => {
		const p = phone({ answer: "allow" });
		await (await connectAdb(p.usb.usb, opts())).close();
		await (await connectAdb(p.usb.usb, opts())).close();
		expect(p.prompts).toHaveLength(2);
	});

	it("says the phone didn't allow it when nobody answers in time, and lets go of the phone", async () => {
		const p = phone({ answer: "none" });
		let prompted = 0;
		const start = Date.now();
		const err = await connectAdb(p.usb.usb, opts({ allowTimeoutMs: 300, onAllowPrompt: () => prompted++ })).catch((e) => e);
		expect(err).toBeInstanceOf(AdbError);
		expect(err).toMatchObject({ kind: "unauthorized" });
		expect((err as AdbError).message).toMatch(/tap Allow when it asks "Allow USB debugging\?"/);
		expect(Date.now() - start).toBeGreaterThanOrEqual(290);
		expect(prompted).toBe(1);
		expectClosed(p);
		expect(p.opened).toEqual([]);
	});

	it("says the same when the user taps Cancel", async () => {
		const p = phone({ answer: "deny" });
		const err = await connectAdb(p.usb.usb, opts({ allowTimeoutMs: 300 })).catch((e) => e);
		expect(err).toMatchObject({ kind: "unauthorized" });
		expect(p.prompt).toBeNull();
	});

	it("stops waiting for the user when the page cancels", async () => {
		const p = phone({ answer: "none" });
		const ac = new AbortController();
		const pending = connectAdb(p.usb.usb, opts({ allowTimeoutMs: 0, signal: ac.signal, onAllowPrompt: () => setTimeout(() => ac.abort(), 30) }));
		const err = await pending.catch((e) => e);
		expect(err).toBeInstanceOf(DOMException);
		expect((err as DOMException).name).toBe("AbortError");
		expectClosed(p);
		// A signal that has already fired doesn't touch the phone
		const q = phone();
		await expect(connectAdb(q.usb.usb, opts({ signal: AbortSignal.abort() }))).rejects.toMatchObject({ name: "AbortError" });
		expect(q.usb.calls).toEqual([]);
	});

	it("says so when the phone keeps refusing the key", async () => {
		const p = phone();
		// A phone that answers the offered key with yet another token
		p.onMessage = (m) => {
			if (m.command !== "AUTH" || m.arg0 !== 3) return false;
			p.sendToken();
			return true;
		};
		let prompted = 0;
		const err = await connectAdb(p.usb.usb, opts({ onAllowPrompt: () => prompted++ })).catch((e) => e);
		expect(err).toMatchObject({ kind: "unauthorized" });
		expect((err as AdbError).message).toMatch(/Revoke USB debugging authorizations/);
		expect(p.tokens).toBe(9);
		// The key went to the phone four times, but the page heard once that the phone is asking
		expect(p.received.filter((m) => m.command === "AUTH" && m.arg0 === 3)).toHaveLength(4);
		expect(prompted).toBe(1);
	});

	/** onAllowPrompt for a user who taps Allow (only once) a moment after the phone asks. */
	const allowSoon = (p: FakeAdbPhone, counter: { prompted: number }) => () => {
		counter.prompted++;
		setTimeout(() => p.prompt && p.tapAllow(), 30);
	};

	/** The page stops waiting while the phone asks; the user then taps Allow, and the phone's CNXN waits on USB. */
	async function givenUpOn(p: FakeAdbPhone) {
		await expect(connectAdb(p.usb.usb, opts({ allowTimeoutMs: 100 }))).rejects.toMatchObject({ kind: "unauthorized" });
	}

	it("reads away the CNXN of an Allow tapped after the page gave up, and asks for a key allowed only once itself", async () => {
		const p = phone();
		await givenUpOn(p);
		p.tapAllow();
		const before = p.received.length;
		const n = { prompted: 0 };
		const c = await connectAdb(p.usb.usb, opts({ onAllowPrompt: allowSoon(p, n) }));
		// That CNXN answered an earlier connection: this one doesn't take it as its own
		expect(n.prompted).toBe(1);
		expect(kinds(p).slice(before)).toEqual(["CNXN", "AUTH 2", "AUTH 3"]);
		await c.rebootToBootloader();
		expect(n.prompted).toBe(1);
		expect(p.received.filter((m) => m.command === "OPEN")).toHaveLength(1);
		expect(p.opened).toEqual(["reboot:bootloader"]);
		expect(p.mode).toBe("bootloader");
		expect(p.violations).toEqual([]);
		expectClosed(p);
	});

	// Detect connects, reads the phone and lets go: a connection that came online from a stale CNXN
	// left the token for its own CNXN unread, and the next one signed that instead of the phone's
	for (const always of [true, false]) {
		it(`signs the phone's own token after Detect, once the user allowed a connection the page gave up on${always ? " with Always allow" : ""}`, async () => {
			const p = phone();
			await givenUpOn(p);
			p.tapAllow({ always });
			const detected = { prompted: 0 };
			await (await connectAdb(p.usb.usb, opts({ onAllowPrompt: allowSoon(p, detected) }))).close();
			const before = p.received.length;
			const prompts = p.prompts.length;
			const n = { prompted: 0 };
			const c = await connectAdb(p.usb.usb, opts({ onAllowPrompt: allowSoon(p, n) }));
			if (always) {
				// The phone trusts the key: one signature, and no question for it
				expect(detected.prompted).toBe(0);
				expect(kinds(p).slice(before)).toEqual(["CNXN", "AUTH 2"]);
				expect(n.prompted).toBe(0);
				expect(p.prompts).toHaveLength(prompts);
			} else {
				// Asked once, and the key offered once: adbd keeps only its newest question, so a second
				// one would make the user's first Allow count for nothing
				expect(kinds(p).slice(before)).toEqual(["CNXN", "AUTH 2", "AUTH 3"]);
				expect(n.prompted).toBe(1);
				expect(p.prompts).toHaveLength(prompts + 1);
			}
			expect(p.prompt).toBeNull();
			await c.rebootToBootloader();
			expect(p.mode).toBe("bootloader");
			expect(p.violations).toEqual([]);
		});
	}

	/**
	 * A connection that comes online from a stale CNXN: the user taps Allow on the question an
	 * earlier connection left on the phone just as this one's CNXN reaches it, so the phone's CNXN for
	 * that Allow comes first, then the token for this CNXN.
	 */
	async function onlineFromStaleCnxn(p: FakeAdbPhone, onAllowPrompt: () => void) {
		await givenUpOn(p);
		p.onMessage = (m) => {
			if (m.command === "CNXN" && p.prompt) p.tapAllow();
			return false;
		};
		return connectAdb(p.usb.usb, opts({ onAllowPrompt }));
	}

	it("asks for the restart again when the phone had started over, after the user allows it", async () => {
		const p = phone();
		const n = { prompted: 0 };
		const c = await onlineFromStaleCnxn(p, allowSoon(p, n));
		expect(n.prompted).toBe(0);
		await c.rebootToBootloader();
		// The phone dropped the first OPEN while it asked for the key again, and took the second
		expect(n.prompted).toBe(1);
		expect(p.received.filter((m) => m.command === "OPEN")).toHaveLength(2);
		expect(p.opened).toEqual(["reboot:bootloader"]);
		expect(p.mode).toBe("bootloader");
		expect(p.violations).toEqual([]);
		expectClosed(p);
	});

	it("says the phone went away, not that it restarted, when it's unplugged while it asks again after the request", async () => {
		const p = phone();
		let prompted = 0;
		const c = await onlineFromStaleCnxn(p, () => {
			prompted++;
			setTimeout(() => p.usb.disconnect(), 30);
		});
		expect(prompted).toBe(0);
		const err = await c.rebootToBootloader().catch((e) => e);
		// The phone ignored the OPEN, so losing it is no restart
		expect(err).toBeInstanceOf(AdbError);
		expect(err).toMatchObject({ kind: "usb" });
		expect(prompted).toBe(1);
		expect(p.opened).toEqual([]);
		expect(p.mode).toBe("android");
	});
});

describe("a phone that misbehaves", () => {
	/** A phone that answers the page's CNXN with `reply`. */
	function answering(reply: (p: FakeAdbPhone, m: HostMessage) => void, o: FakeAdbOptions = {}) {
		const p = phone(o);
		p.onMessage = (m) => {
			if (m.command !== "CNXN") return false;
			reply(p, m);
			return true;
		};
		return p;
	}

	const header = (command: number, length: number, magic = (command ^ 0xffffffff) >>> 0) => {
		const b = new Uint8Array(24);
		const v = new DataView(b.buffer);
		v.setUint32(0, command, true);
		v.setUint32(12, length, true);
		v.setUint32(20, magic, true);
		return b;
	};

	for (const [what, reply, message] of [
		["a header with the wrong magic", (p: FakeAdbPhone) => p.sendRaw(header(A_AUTH, 20, 0x12345678)), /check value is wrong/],
		["a payload over 1 MiB", (p: FakeAdbPhone) => p.sendRaw(header(A_WRTE, 2 * 1024 * 1024)), /more than the 1 MiB/],
		["a payload whose checksum is wrong", (p: FakeAdbPhone) => p.send(A_AUTH, 1, 0, new Uint8Array(20).fill(1), { check: 7 }), /checksum doesn't match/],
		["a command no adb has", (p: FakeAdbPhone) => p.sendRaw(header(0x41414141, 0)), /unknown kind \(AAAA\)/],
		["a token of the wrong size", (p: FakeAdbPhone) => p.send(A_AUTH, 1, 0, new Uint8Array(10)), /token of 10 bytes/],
		["an AUTH of an unknown type", (p: FakeAdbPhone) => p.send(A_AUTH, 5, 0, new Uint8Array(20)), /AUTH message of type 5/],
		["a CNXN older than any adb", (p: FakeAdbPhone) => p.send(A_CNXN, 0x00ffffff, 4096, new TextEncoder().encode("device::")), /CNXN of version 0xffffff/],
		["a request for an encrypted connection", (p: FakeAdbPhone) => p.send(A_STLS, 0x01000000, 0), /encrypted connection/],
	] as const) {
		it(`fails at once on ${what}`, async () => {
			const p = answering(reply);
			const start = Date.now();
			const err = await connectAdb(p.usb.usb, opts({ answerTimeoutMs: 5000 })).catch((e) => e);
			expect(err).toBeInstanceOf(AdbError);
			expect(err).toMatchObject({ kind: "protocol" });
			expect((err as AdbError).message).toMatch(message);
			expect(Date.now() - start).toBeLessThan(1000);
			expectClosed(p);
		});
	}

	it("says the phone didn't answer when it says nothing", async () => {
		const p = answering(() => {});
		const err = await connectAdb(p.usb.usb, opts({ answerTimeoutMs: 200 })).catch((e) => e);
		expect(err).toMatchObject({ kind: "timeout" });
		expect((err as AdbError).message).toMatch(/didn't answer over USB debugging/);
		expectClosed(p);
	});

	it("ignores what comes before the phone's CNXN, as protocol.txt says", async () => {
		const p = answering((p) => {
			p.send(ADB_COMMANDS.A_OKAY, 5, 1);
			p.send(A_WRTE, 5, 1, new TextEncoder().encode("stray"));
			p.sendToken();
		}, { trustedKeys: [b64(key)] });
		const c = await connectAdb(p.usb.usb, opts());
		expect(c.product).toBe("cheetah");
		await c.close();
	});

	it("says the phone went away when it's unplugged while it waits for the user", async () => {
		const p = phone({ answer: "none" });
		const err = await connectAdb(p.usb.usb, opts({ onAllowPrompt: () => setTimeout(() => p.usb.disconnect(), 20) })).catch((e) => e);
		expect(err).toMatchObject({ kind: "usb" });
		expect((err as AdbError).message).toMatch(/stopped answering over USB/);
	});

	it("never reads a part of a packet, and never two reads at once", async () => {
		const p = phone({ trustedKeys: [b64(key)], packetSize: 64, joined: true });
		const c = await connectAdb(p.usb.usb, opts());
		await c.rebootToBootloader();
		expect(p.violations).toEqual([]);
	});
});

describe("restarting into Fastboot Mode", () => {
	async function connected(o: FakeAdbOptions = {}, co: ConnectOptions = {}) {
		const p = phone({ trustedKeys: [b64(key)], ...o });
		return { p, c: await connectAdb(p.usb.usb, opts(co)) };
	}

	it("takes OKAY then CLSE as done", async () => {
		const { p, c } = await connected({ reboot: "okay-close", rebootDelayMs: 500 });
		const start = Date.now();
		await c.rebootToBootloader();
		expect(Date.now() - start).toBeLessThan(400);
		expectClosed(p);
	});

	it("takes the phone dropping off USB right after the request as the restart", async () => {
		const { p, c } = await connected({ reboot: "vanish" });
		await c.rebootToBootloader();
		expect(p.mode).toBe("bootloader");
		expect(p.usb.gone).toBe(true);
	});

	it("lets go of a phone that accepted and is still shutting down", async () => {
		const { p, c } = await connected({ reboot: "linger" }, { settleMs: 100 });
		await c.rebootToBootloader();
		expectClosed(p);
	});

	it("says the phone refused when it closes the stream instead", async () => {
		const { p, c } = await connected({ reboot: "refuse" });
		const err = await c.rebootToBootloader().catch((e) => e);
		expect(err).toMatchObject({ kind: "refused" });
		expect((err as AdbError).message).toMatch(/Turn the phone off\. Then hold Power and Volume down together until you see Fastboot Mode\./);
		expectClosed(p);
	});

	it("passes on what the phone said when the restart failed", async () => {
		const { p, c } = await connected({ reboot: "output-close" });
		const err = await c.rebootToBootloader().catch((e) => e);
		expect(err).toMatchObject({ kind: "refused" });
		expect((err as AdbError).message).toMatch(/The phone said: reboot: Operation not permitted$/);
		// The output was acknowledged on the page's own stream, as adb does
		const okay = p.received.filter((m) => m.command === "OKAY");
		expect(okay).toHaveLength(1);
		expect(okay[0]).toMatchObject({ arg0: 1, arg1: 100 });
		expect(p.mode).toBe("android");
	});

	it("says the phone didn't answer the request when it doesn't", async () => {
		const { p, c } = await connected({}, { answerTimeoutMs: 200 });
		p.onMessage = (m) => m.command === "OPEN";
		const err = await c.rebootToBootloader().catch((e) => e);
		expect(err).toMatchObject({ kind: "timeout" });
		expect((err as AdbError).message).toMatch(/didn't answer the request to restart into Fastboot Mode/);
		expectClosed(p);
	});

	it("can't be asked twice, or after the connection is closed", async () => {
		const { c } = await connected();
		await c.rebootToBootloader();
		await expect(c.rebootToBootloader()).rejects.toMatchObject({ kind: "usb" });
		const { c: d } = await connected();
		await d.close();
		await expect(d.rebootToBootloader()).rejects.toMatchObject({ kind: "usb" });
	});

	it("never opens anything but reboot:bootloader", async () => {
		const { p, c } = await connected();
		await c.rebootToBootloader();
		const opens = p.received.filter((m) => m.command === "OPEN").map((m) => new TextDecoder().decode(m.payload));
		expect(opens).toEqual(["reboot:bootloader\0"]);
		expect(p.received.map((m) => m.command)).toEqual(["CNXN", "AUTH", "OPEN"]);
	});
});

describe("opening the phone's USB debugging interface", () => {
	const claimed = new DOMException("Unable to claim interface.", "NetworkError");
	const denied = new DOMException("Access denied.", "SecurityError");

	it("tells the user to stop the adb server holding the phone", async () => {
		const p = phone({ claimError: claimed });
		const err = await connectAdb(p.usb.usb, opts({ os: "mac" })).catch((e) => e);
		expect(err).toBeInstanceOf(AdbError);
		expect(err).toMatchObject({ kind: "in-use" });
		expect((err as AdbError).message).toMatch(/usually an adb server started by adb, Android Studio or scrcpy\. Close Android Studio and scrcpy if they're open, and any other tab using the phone\. Then run adb kill-server in a terminal and try again\./);
		expect((err as AdbError).message).toMatch(/The browser said: Unable to claim interface\.$/);
		// The page opened the device, so it closes it again
		expect(p.usb.calls).toEqual(["open", "claimInterface 1", "close"]);
		expect(adbOpenFailure("claim", claimed, "android").message).toMatch(/^Another app or tab is using the phone's USB debugging connection/);
	});

	it("names both a missing driver and adb on Windows, and a udev rule on Linux", async () => {
		const win = await connectAdb(phone({ openError: denied }).usb.usb, opts({ os: "windows" })).catch((e) => e);
		expect(win).toMatchObject({ kind: "access" });
		expect((win as AdbError).message).toMatch(/run adb kill-server/);
		expect((win as AdbError).message).toMatch(/install the Google USB Driver/);
		expect((win as AdbError).message).not.toMatch(/Fastboot Mode/);
		const linux = await connectAdb(phone({ openError: denied }).usb.usb, opts({ os: "linux" })).catch((e) => e);
		expect(linux).toMatchObject({ kind: "access" });
		expect((linux as AdbError).message).toMatch(/udev rule for Google's USB vendor id 18d1/);
	});

	it("reports anything else as a USB failure", () => {
		const err = adbOpenFailure("open", new DOMException("The device was disconnected.", "NotFoundError"), "linux");
		expect(err).toMatchObject({ kind: "usb", message: "Couldn't open the phone. The browser said: The device was disconnected." });
	});
});

describe("the browser's own key", () => {
	it("is made when none is given, and works without storage", async () => {
		const p = phone({ answer: "allow" });
		const c = await connectAdb(p.usb.usb, { answerTimeoutMs: 2000, allowTimeoutMs: 2000, settleMs: 50 });
		expect(p.prompts).toHaveLength(1);
		expect(p.prompts[0].name).toBe("ExpressiveOS Flasher@browser");
		await c.close();
	});
});
