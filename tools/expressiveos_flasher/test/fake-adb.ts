// A simulated Pixel running Android with USB debugging on, behind WebUSB's USBDevice: a composite
// device (an MTP interface, and the ADB interface with its own bulk endpoints) whose adbd behaves
// as AOSP's does (adb.cpp, daemon_auth.cpp, daemon/usb.cpp):
//
// - USB: bulk transfers are made of packets of the endpoint's size. A host read ends at a short
//   packet or when it's full, and one that isn't a whole number of packets is a babble. adbd reads
//   in 16 KiB blocks that also end only at a short packet, so a host write that fills its last
//   packet needs a zero-length packet after it, and a header must come as a transfer of its own
//   (adbd drops the connection over a block of the wrong size). The phone sends a header and its
//   payload as two writes, or as one (`joined`), with or without a zero-length packet (`zlp`).
// - Protocol: it checks magic and lengths, and checksums the way an older adbd (version
//   0x01000000) checks every one. A current one (which itself ignores them) requires them where
//   the host can't know the phone's version yet: on CNXN, and on AUTH until the phone has sent a
//   CNXN; and 0 on everything else.
// - Auth: a random token per try. A signature is checked against the keys it trusts (see
//   `verifySignature`; the default is plain BigInt arithmetic). An offered public key is decoded
//   and checked (n0inv and rr against the modulus), and "Allow USB debugging?" shows, which the
//   user answers with tapAllow() (or "Always allow from this computer") or tapCancel(), or the
//   `answer` option. Allowing sends a CNXN even when the host has gone, as adbd does.
// - Services: only reboot:bootloader does anything (the phone then drops off USB); every service
//   opened is recorded in `opened`.
//
// Nothing here needs Node, so the browser tests (e2e/fake-usb.ts) can use it as well.

const A_SYNC = 0x434e5953;
const A_CNXN = 0x4e584e43;
const A_AUTH = 0x48545541;
const A_OPEN = 0x4e45504f;
const A_OKAY = 0x59414b4f;
const A_CLSE = 0x45534c43;
const A_WRTE = 0x45545257;
const A_STLS = 0x534c5453;
const A_VERSION_MIN = 0x01000000;
const A_VERSION_SKIP_CHECKSUM = 0x01000001;
const MAX_PAYLOAD_V1 = 4096;
const TOKEN_SIZE = 20;
const ADBD_READ_SIZE = 16384;
const PUBKEY_SIZE = 524;
const SHA1_PREFIX = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14];

const NAMES: Record<number, string> = {
	[A_SYNC]: "SYNC",
	[A_CNXN]: "CNXN",
	[A_AUTH]: "AUTH",
	[A_OPEN]: "OPEN",
	[A_OKAY]: "OKAY",
	[A_CLSE]: "CLSE",
	[A_WRTE]: "WRTE",
	[A_STLS]: "STLS",
};

const enc = new TextEncoder();
const dec = new TextDecoder();

export const ADB_COMMANDS = { A_SYNC, A_CNXN, A_AUTH, A_OPEN, A_OKAY, A_CLSE, A_WRTE, A_STLS } as const;

/** A public key the phone was offered or trusts. */
export interface FakeAdbKey {
	/** The key in Android's format, in base64, as adb_keys keeps it. */
	base64: string;
	/** What follows it: the name the host gave. */
	name: string;
	/** The modulus, big-endian. */
	modulus: Uint8Array;
	exponent: number;
}

/** Checks a signature over a token with a public key. */
export type VerifySignature = (key: FakeAdbKey, token: Uint8Array, signature: Uint8Array) => boolean;

export interface HostMessage {
	command: string;
	arg0: number;
	arg1: number;
	/** The header's checksum field. */
	check: number;
	payload: Uint8Array;
}

export interface FakeAdbOptions {
	serial?: string;
	/** ro.product.device. */
	device?: string;
	model?: string;
	/** ro.product.name. */
	name?: string;
	features?: string;
	/** adbd's protocol version: 0x01000001, or 0x01000000 for one that checksums everything. */
	version?: number;
	maxPayload?: number;
	/** The ADB endpoints' packet size: 512 (high speed), 1024 (super speed) or 64 (full speed). */
	packetSize?: number;
	/** The ADB interface in alternate setting 1 instead of 0. */
	alternate?: number;
	/** Header and payload in one USB write. */
	joined?: boolean;
	/** A zero-length packet after a phone write that fills its last packet. */
	zlp?: boolean;
	/** ro.adb.secure: false lets any host in without a key. */
	authRequired?: boolean;
	/** Keys in Android's base64 format the phone already trusts. */
	trustedKeys?: string[];
	/** How the user answers "Allow USB debugging?" (default: not at all; a test taps). */
	answer?: "allow" | "always" | "deny" | "none";
	answerDelayMs?: number;
	verifySignature?: VerifySignature;
	/**
	 * What reboot:bootloader does: OKAY then the phone drops off USB (default), OKAY and CLSE
	 * first, CLSE alone (refused), OKAY then output and CLSE (the command failed), nothing while it
	 * drops off at once, or OKAY and the phone stays.
	 */
	reboot?: "okay" | "okay-close" | "refuse" | "output-close" | "vanish" | "linger";
	/** How long after its answer the phone drops off USB. */
	rebootDelayMs?: number;
	/** What claimInterface() and open() fail with, as Chrome does (an adb server holding it, a missing driver). */
	claimError?: DOMException;
	openError?: DOMException;
}

function u32(b: Uint8Array, off: number): number {
	return new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(off, true);
}

function sum(b: Uint8Array): number {
	let s = 0;
	for (const x of b) s += x;
	return s >>> 0;
}

function toBigInt(b: Uint8Array, littleEndian = false): bigint {
	const bytes = littleEndian ? [...b].reverse() : [...b];
	return BigInt(`0x${bytes.map((x) => x.toString(16).padStart(2, "0")).join("") || "0"}`);
}

function powMod(b: bigint, e: bigint, m: bigint): bigint {
	let r = 1n;
	b %= m;
	while (e > 0n) {
		if (e & 1n) r = (r * b) % m;
		e >>= 1n;
		b = (b * b) % m;
	}
	return r;
}

/** RSA_verify(NID_sha1, token, 20, sig, key) in plain arithmetic: s^e mod n is 00 01 FF..FF 00 DigestInfo token. */
export const verifyWithBigInt: VerifySignature = (key, token, signature) => {
	if (signature.byteLength !== key.modulus.byteLength) return false;
	const n = toBigInt(key.modulus);
	const m = powMod(toBigInt(signature), BigInt(key.exponent), n);
	const k = key.modulus.byteLength;
	const em = new Uint8Array(k).fill(0xff);
	em[0] = 0;
	em[1] = 1;
	em[k - 36] = 0;
	em.set(SHA1_PREFIX, k - 35);
	em.set(token, k - 20);
	return m === toBigInt(em);
};

/**
 * AUTH RSAPUBLICKEY's payload: "<base64 of RSAPublicKey> <name>\0", checked the way
 * android_pubkey_decode reads it, and then some: n0inv and rr must match the modulus.
 */
export function parseAndroidPublicKey(payload: Uint8Array): FakeAdbKey | string {
	const nul = payload.indexOf(0);
	if (nul < 0) return "the key isn't NUL-terminated";
	const text = dec.decode(payload.subarray(0, nul));
	const space = text.search(/[ \t]/);
	const base64 = space < 0 ? text : text.slice(0, space);
	const name = space < 0 ? "" : text.slice(space + 1);
	let raw: Uint8Array;
	try {
		raw = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
	} catch {
		return "the key isn't base64";
	}
	if (raw.byteLength !== PUBKEY_SIZE) return `the key is ${raw.byteLength} bytes, not ${PUBKEY_SIZE}`;
	if (u32(raw, 0) !== 64) return `modulus_size_words is ${u32(raw, 0)}`;
	const n = toBigInt(raw.subarray(8, 264), true);
	if (n >> 2047n !== 1n || (n & 1n) === 0n) return "the modulus isn't an odd 2048-bit number";
	if (BigInt.asUintN(32, BigInt(u32(raw, 4)) * n) !== 0xffffffffn) return "n0inv isn't -1/n mod 2^32";
	if (toBigInt(raw.subarray(264, 520), true) !== (1n << 4096n) % n) return "rr isn't 2^4096 mod n";
	const exponent = u32(raw, 520);
	if (exponent !== 65537) return `the exponent is ${exponent}`;
	return { base64, name, modulus: raw.slice(8, 264).reverse(), exponent };
}

type Endpoint = { endpointNumber: number; direction: "in" | "out"; type: "bulk" | "interrupt"; packetSize: number };

function alternate(alternateSetting: number, cls: number, sub: number, proto: number, endpoints: Endpoint[], interfaceName: string | null = null) {
	return { alternateSetting, interfaceClass: cls, interfaceSubclass: sub, interfaceProtocol: proto, interfaceName, endpoints };
}

const ADB_IN = 3;
const ADB_OUT = 2;
const ADB_INTERFACE = 1;

interface PendingIn {
	length: number;
	parts: Uint8Array[];
	size: number;
	resolve: (r: USBInTransferResult) => void;
	reject: (e: unknown) => void;
}

/** The phone as WebUSB shows it. Cast it to USBDevice. */
export class FakeAdbUsbDevice {
	readonly vendorId = 0x18d1;
	/** A Pixel with MTP and ADB. */
	readonly productId = 0x4ee2;
	readonly manufacturerName = "Google";
	readonly productName: string;
	readonly serialNumber: string;
	readonly deviceClass = 0;
	readonly deviceSubclass = 0;
	readonly deviceProtocol = 0;
	opened = false;
	gone = false;
	readonly configurations: unknown[];
	/** The phone's configuration is active from the start, as a computer configures it. */
	configuration: unknown;
	readonly claimed = new Set<number>();
	/** Every WebUSB call, in order. */
	readonly calls: string[] = [];
	/** Zero-length packets the host sent, and blocks adbd got that held nothing. */
	zlps = 0;
	emptyBlocks = 0;
	/** The host's OUT transfers, by size. */
	readonly writes: number[] = [];
	/** Bytes the phone sent that no host has read yet stay queued, as they do on a real phone. */
	private inQueue: Uint8Array[] = [];
	private pendingIn: PendingIn | null = null;
	private block: Uint8Array[] = [];
	private blockSize = 0;
	private work: Promise<void> = Promise.resolve();

	constructor(
		private readonly phone: FakeAdbPhone,
		readonly packetSize: number,
		adbAlternate: number,
	) {
		this.productName = phone.model;
		this.serialNumber = phone.serial;
		const ps = packetSize;
		const adb = alternate(adbAlternate, 0xff, 0x42, 0x01, [
			{ endpointNumber: ADB_IN, direction: "in", type: "bulk", packetSize: ps },
			{ endpointNumber: ADB_OUT, direction: "out", type: "bulk", packetSize: ps },
		], "ADB Interface");
		const adbAlternates = adbAlternate === 0 ? [adb] : [alternate(0, 0xff, 0x42, 0x01, []), adb];
		const config = {
			configurationValue: 1,
			configurationName: null,
			interfaces: [
				{
					interfaceNumber: 0,
					claimed: false,
					alternate: null,
					alternates: [
						alternate(0, 0x06, 0x01, 0x01, [
							{ endpointNumber: 1, direction: "in", type: "bulk", packetSize: ps },
							{ endpointNumber: 1, direction: "out", type: "bulk", packetSize: ps },
							{ endpointNumber: 2, direction: "in", type: "interrupt", packetSize: 28 },
						], "MTP"),
					],
				},
				{ interfaceNumber: ADB_INTERFACE, claimed: false, alternate: adbAlternates[0], alternates: adbAlternates },
			],
		};
		this.configurations = [config];
		this.configuration = config;
	}

	get usb(): USBDevice {
		return this as unknown as USBDevice;
	}

	private disconnected(): DOMException {
		return new DOMException("The device was disconnected.", "NotFoundError");
	}

	async open(): Promise<void> {
		this.calls.push("open");
		if (this.gone) throw this.disconnected();
		if (this.phone.opts.openError) throw this.phone.opts.openError;
		this.opened = true;
	}

	async close(): Promise<void> {
		this.calls.push("close");
		this.cancelIn();
		this.claimed.clear();
		this.opened = false;
		if (this.gone) throw this.disconnected();
	}

	async selectConfiguration(value: number): Promise<void> {
		this.calls.push(`selectConfiguration ${value}`);
		if (!this.opened) throw new DOMException("The device must be opened first.", "InvalidStateError");
	}

	async claimInterface(n: number): Promise<void> {
		this.calls.push(`claimInterface ${n}`);
		if (this.gone) throw this.disconnected();
		if (!this.opened) throw new DOMException("The device must be opened first.", "InvalidStateError");
		if (n === ADB_INTERFACE && this.phone.opts.claimError) throw this.phone.opts.claimError;
		this.claimed.add(n);
	}

	async releaseInterface(n: number): Promise<void> {
		this.calls.push(`releaseInterface ${n}`);
		if (n === ADB_INTERFACE) this.cancelIn();
		this.claimed.delete(n);
		if (this.gone) throw this.disconnected();
	}

	async selectAlternateInterface(n: number, alt: number): Promise<void> {
		this.calls.push(`selectAlternateInterface ${n} ${alt}`);
		if (!this.claimed.has(n)) throw new DOMException("The interface must be claimed first.", "InvalidStateError");
	}

	async clearHalt(direction: string, ep: number): Promise<void> {
		this.calls.push(`clearHalt ${direction} ${ep}`);
	}

	async reset(): Promise<void> {
		this.calls.push("reset");
	}

	private ready(ep: number, want: number, dir: "in" | "out") {
		if (this.gone) throw this.disconnected();
		if (!this.opened || !this.claimed.has(ADB_INTERFACE)) {
			this.phone.violation(`transfer ${dir} on an interface that isn't claimed`);
			throw new DOMException("The specified endpoint is not part of a claimed and selected alternate interface.", "NotFoundError");
		}
		if (ep !== want) {
			this.phone.violation(`transfer ${dir} on endpoint ${ep}, not the ADB interface's ${want}`);
			throw new DOMException("The specified endpoint is not part of a claimed and selected alternate interface.", "NotFoundError");
		}
	}

	transferIn(ep: number, length: number): Promise<USBInTransferResult> {
		try {
			this.ready(ep, ADB_IN, "in");
		} catch (e) {
			return Promise.reject(e);
		}
		if (length % this.packetSize !== 0) {
			// A full packet into a buffer with less room than a packet overflows
			this.phone.violation(`transferIn of ${length} bytes, not a whole number of ${this.packetSize}-byte packets`);
			return Promise.resolve({ status: "babble" } as USBInTransferResult);
		}
		if (this.pendingIn) this.phone.violation("two transferIn at once");
		return new Promise((resolve, reject) => {
			this.pendingIn = { length, parts: [], size: 0, resolve, reject };
			this.pumpIn();
		});
	}

	async transferOut(ep: number, data: BufferSource): Promise<USBOutTransferResult> {
		this.ready(ep, ADB_OUT, "out");
		const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
		const copy = bytes.slice();
		this.writes.push(copy.byteLength);
		const ps = this.packetSize;
		if (copy.byteLength === 0) {
			this.zlps++;
			this.outPacket(copy);
		}
		for (let off = 0; off < copy.byteLength; off += ps) this.outPacket(copy.subarray(off, off + ps));
		return { status: "ok", bytesWritten: copy.byteLength } as USBOutTransferResult;
	}

	/** A packet from the host into adbd's current read, which ends at a short packet or when full. */
	private outPacket(p: Uint8Array) {
		this.block.push(p);
		this.blockSize += p.byteLength;
		if (p.byteLength < this.packetSize || this.blockSize >= ADBD_READ_SIZE) {
			const block = new Uint8Array(this.blockSize);
			let off = 0;
			for (const b of this.block) {
				block.set(b, off);
				off += b.byteLength;
			}
			this.block = [];
			this.blockSize = 0;
			// adbd handles it on its own thread
			this.work = this.work.then(() => this.phone.readBlock(block)).catch((e) => this.phone.violation(`adbd failed: ${e}`));
		}
	}

	/** A write by the phone: packets on the IN endpoint. */
	deviceWrite(bytes: Uint8Array, zlp: boolean) {
		if (this.gone) return;
		const ps = this.packetSize;
		for (let off = 0; off < bytes.byteLength; off += ps) this.inQueue.push(bytes.slice(off, off + ps));
		if (bytes.byteLength === 0 || (zlp && bytes.byteLength % ps === 0)) this.inQueue.push(new Uint8Array(0));
		this.pumpIn();
	}

	private pumpIn() {
		const t = this.pendingIn;
		while (t && this.pendingIn === t && this.inQueue.length) {
			const p = this.inQueue.shift()!;
			t.parts.push(p);
			t.size += p.byteLength;
			if (p.byteLength < this.packetSize || t.size === t.length) {
				this.pendingIn = null;
				const data = new Uint8Array(t.size);
				let off = 0;
				for (const x of t.parts) {
					data.set(x, off);
					off += x.byteLength;
				}
				t.resolve({ status: "ok", data: new DataView(data.buffer) } as USBInTransferResult);
			}
		}
	}

	/** releaseInterface() and close() cancel a read in flight; what it had is lost. */
	private cancelIn() {
		const t = this.pendingIn;
		this.pendingIn = null;
		t?.reject(new DOMException("The transfer was cancelled.", "AbortError"));
	}

	/** The cable is pulled, or the phone restarts. */
	disconnect() {
		if (this.gone) return;
		this.gone = true;
		this.opened = false;
		this.claimed.clear();
		this.inQueue = [];
		const t = this.pendingIn;
		this.pendingIn = null;
		t?.reject(new DOMException("A transfer error has occurred.", "NetworkError"));
		this.phone.onDisconnect?.(this);
	}
}

export class FakeAdbPhone {
	readonly serial: string;
	readonly device: string;
	readonly model: string;
	readonly name: string;
	readonly features: string;
	readonly version: number;
	readonly maxPayload: number;
	mode: "android" | "bootloader" = "android";
	readonly trustedKeys: Set<string>;
	/** "Allow USB debugging?" as it shows now, and every time it showed. */
	prompt: FakeAdbKey | null = null;
	readonly prompts: FakeAdbKey[] = [];
	/** Everything the host sent, in order. */
	readonly received: HostMessage[] = [];
	/** Services the host opened, without the NUL. */
	readonly opened: string[] = [];
	/** What a real adbd would have dropped the connection over, or a host doing something adb doesn't. */
	readonly violations: string[] = [];
	tokens = 0;
	/** CNXNs the phone sent: the times it let a host in. */
	connections = 0;
	readonly usb: FakeAdbUsbDevice;
	onDisconnect?: (d: FakeAdbUsbDevice) => void;
	/** Sees each message from the host first; true when it handled it. */
	onMessage?: (m: HostMessage) => boolean;

	private negotiated = A_VERSION_MIN;
	private online = false;
	private broken = false;
	private token: Uint8Array | null = null;
	private header: { command: number; arg0: number; arg1: number; length: number; check: number } | null = null;
	private payload: Uint8Array[] = [];
	private payloadSize = 0;
	private nextId = 100;

	constructor(readonly opts: FakeAdbOptions = {}) {
		this.serial = opts.serial ?? "28161FDH2000AB";
		this.device = opts.device ?? "cheetah";
		this.model = opts.model ?? "Pixel 7 Pro";
		this.name = opts.name ?? opts.device ?? "cheetah";
		this.features = opts.features ?? "shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,sendrecv_v2_dry_run_send,openscreen_mdns,delayed_ack";
		this.version = opts.version ?? A_VERSION_SKIP_CHECKSUM;
		this.maxPayload = opts.maxPayload ?? 1024 * 1024;
		this.trustedKeys = new Set(opts.trustedKeys ?? []);
		this.usb = new FakeAdbUsbDevice(this, opts.packetSize ?? 512, opts.alternate ?? 0);
	}

	get banner(): string {
		return `device::ro.product.name=${this.name};ro.product.model=${this.model};ro.product.device=${this.device};features=${this.features}`;
	}

	violation(what: string) {
		this.violations.push(what);
	}

	/** adbd tears the connection down: it answers nothing more until the phone is plugged in again. */
	private kick(why: string) {
		this.violation(why);
		this.broken = true;
	}

	/** A block adbd read (daemon/usb.cpp's ProcessRead). */
	readBlock(block: Uint8Array) {
		if (this.broken) return;
		if (block.byteLength === 0) {
			this.usb.emptyBlocks++;
			return;
		}
		if (!this.header) {
			if (block.byteLength !== 24) return this.kick(`received a block of ${block.byteLength} bytes while reading a header`);
			const command = u32(block, 0);
			if (u32(block, 20) !== (command ^ 0xffffffff) >>> 0) return this.kick("a header with the wrong magic");
			const length = u32(block, 12);
			if (length > this.maxPayload) return this.kick(`a payload of ${length} bytes, over ${this.maxPayload}`);
			this.header = { command, arg0: u32(block, 4), arg1: u32(block, 8), length, check: u32(block, 16) };
			this.payload = [];
			this.payloadSize = 0;
		} else {
			if (block.byteLength > this.header.length - this.payloadSize) return this.kick("received too many bytes while waiting for a payload");
			this.payload.push(block);
			this.payloadSize += block.byteLength;
		}
		if (this.payloadSize === this.header.length) {
			const payload = new Uint8Array(this.payloadSize);
			let off = 0;
			for (const p of this.payload) {
				payload.set(p, off);
				off += p.byteLength;
			}
			const h = this.header;
			this.header = null;
			this.handle({ command: NAMES[h.command] ?? `0x${h.command.toString(16)}`, arg0: h.arg0, arg1: h.arg1, check: h.check, payload }, h.command);
		}
	}

	private handle(m: HostMessage, command: number) {
		this.received.push(m);
		if (this.onMessage?.(m)) return;
		const s = sum(m.payload);
		if (this.version < A_VERSION_SKIP_CHECKSUM) {
			if (m.check !== s) return this.kick(`${m.command} with checksum ${m.check}, not ${s}`);
		} else if (command === A_CNXN || (command === A_AUTH && !(m.check === 0 && this.connections > 0))) {
			// Sent before the host knows the phone's version (a host that read a CNXN from the phone,
			// even one left over from an earlier connection, knows it)
			if (m.check !== s) return this.kick(`${m.command} before the version is known with checksum ${m.check}, not ${s}`);
		} else if (m.check !== 0) {
			this.violation(`${m.command} with a checksum after both sides skip it`);
		}
		switch (command) {
			case A_CNXN:
				if (m.payload.byteLength > MAX_PAYLOAD_V1) this.violation("a CNXN over 4096 bytes");
				if (m.arg0 < A_VERSION_MIN) return this.kick(`a CNXN of version 0x${m.arg0.toString(16)}`);
				this.negotiated = Math.min(m.arg0, this.version);
				this.online = false;
				this.token = null;
				if (this.opts.authRequired === false) return this.letIn();
				return this.sendToken();
			case A_AUTH:
				if (m.payload.byteLength > MAX_PAYLOAD_V1) this.violation("an AUTH over 4096 bytes");
				if (m.arg0 === 2) {
					if (!this.token) return this.violation("a signature with no token out");
					const token = this.token;
					const verify = this.opts.verifySignature ?? verifyWithBigInt;
					for (const b64 of this.trustedKeys) {
						const key = parseAndroidPublicKey(enc.encode(`${b64}\0`));
						if (typeof key !== "string" && verify(key, token, m.payload)) return this.letIn();
					}
					return this.sendToken();
				}
				if (m.arg0 === 3) {
					const key = parseAndroidPublicKey(m.payload);
					if (typeof key === "string") return this.violation(`a bad public key: ${key}`);
					this.prompt = key;
					this.prompts.push(key);
					const answer = this.opts.answer ?? "none";
					if (answer !== "none") {
						setTimeout(() => {
							if (this.prompt !== key) return;
							if (answer === "deny") this.tapCancel();
							else this.tapAllow({ always: answer === "always" });
						}, this.opts.answerDelayMs ?? 20);
					}
					return;
				}
				return this.violation(`an AUTH of type ${m.arg0}`);
			case A_OPEN: {
				// adbd ignores streams until the host is let in
				if (!this.online) return;
				if (m.arg0 === 0 || m.arg1 !== 0) this.violation(`OPEN(${m.arg0}, ${m.arg1})`);
				if (m.payload[m.payload.byteLength - 1] !== 0) this.violation("an OPEN without a NUL");
				const service = dec.decode(m.payload).replace(/\0+$/, "");
				this.opened.push(service);
				if (service === "reboot:bootloader") return this.reboot(m.arg0);
				return this.send(A_CLSE, 0, m.arg0);
			}
			case A_OKAY:
			case A_CLSE:
			case A_WRTE:
				return;
			default:
				return this.violation(`an unexpected ${m.command}`);
		}
	}

	/** A message from the phone: its header and payload as two USB writes, or one. */
	send(command: number, arg0: number, arg1: number, payload: Uint8Array = new Uint8Array(0), o: { check?: number; magic?: number } = {}) {
		if (this.broken || this.usb.gone) return;
		const header = new Uint8Array(24);
		const v = new DataView(header.buffer);
		v.setUint32(0, command >>> 0, true);
		v.setUint32(4, arg0 >>> 0, true);
		v.setUint32(8, arg1 >>> 0, true);
		v.setUint32(12, payload.byteLength, true);
		v.setUint32(16, o.check ?? (this.negotiated >= A_VERSION_SKIP_CHECKSUM ? 0 : sum(payload)), true);
		v.setUint32(20, o.magic ?? (command ^ 0xffffffff) >>> 0, true);
		const zlp = this.opts.zlp ?? false;
		if (this.opts.joined && payload.byteLength) {
			const both = new Uint8Array(24 + payload.byteLength);
			both.set(header);
			both.set(payload, 24);
			this.usb.deviceWrite(both, zlp);
		} else {
			this.usb.deviceWrite(header, zlp);
			if (payload.byteLength) this.usb.deviceWrite(payload, zlp);
		}
	}

	/** Raw bytes on the IN endpoint, for malformed messages. */
	sendRaw(bytes: Uint8Array) {
		this.usb.deviceWrite(bytes, false);
	}

	sendToken() {
		this.token = crypto.getRandomValues(new Uint8Array(TOKEN_SIZE));
		this.tokens++;
		this.send(A_AUTH, 1, 0, this.token);
	}

	/** adbd_auth_verified: online, and a CNXN with the phone's banner. */
	private letIn() {
		if (this.broken || this.usb.gone) return;
		this.online = true;
		this.token = null;
		this.connections++;
		this.send(A_CNXN, this.version, this.maxPayload, enc.encode(this.banner));
	}

	/** The user taps Allow, with "Always allow from this computer" ticked or not. */
	tapAllow(o: { always?: boolean } = {}) {
		const key = this.prompt;
		if (!key) throw new Error("The phone isn't asking to allow USB debugging");
		this.prompt = null;
		if (o.always) this.trustedKeys.add(key.base64);
		this.letIn();
	}

	tapCancel() {
		if (!this.prompt) throw new Error("The phone isn't asking to allow USB debugging");
		this.prompt = null;
	}

	private reboot(hostId: number) {
		const id = this.nextId++;
		const reply = this.opts.reboot ?? "okay";
		const restart = () => {
			this.mode = "bootloader";
			this.usb.disconnect();
		};
		const later = () => setTimeout(restart, this.opts.rebootDelayMs ?? 20);
		switch (reply) {
			case "okay":
				this.send(A_OKAY, id, hostId);
				return later();
			case "okay-close":
				this.send(A_OKAY, id, hostId);
				this.send(A_CLSE, id, hostId);
				return later();
			case "refuse":
				return this.send(A_CLSE, 0, hostId);
			case "output-close":
				this.send(A_OKAY, id, hostId);
				this.send(A_WRTE, id, hostId, enc.encode("reboot: Operation not permitted\n"));
				return this.send(A_CLSE, id, hostId);
			case "vanish":
				return restart();
			case "linger":
				return this.send(A_OKAY, id, hostId);
		}
	}
}
