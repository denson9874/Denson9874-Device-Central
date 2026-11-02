// A simulated Pixel in fastboot mode: the bootloader and fastbootd, A/B slots, physical partitions
// of fixed sizes and logical ones in super, and the commands AOSP fastboot sends. Restarts hand
// out a new connection, as a real phone comes back as a new USB device.

import type { Transport } from "../src/fastboot/client.ts";
import type { Connector, Link } from "../src/fastboot/device.ts";
import { logicalPartitions } from "../src/fastboot/lp.ts";
import { applySparse } from "./sparse-apply.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

export interface FakeOptions {
	product?: string;
	serial?: string;
	unlocked?: boolean;
	slot?: "a" | "b";
	maxDownload?: number;
	/** Physical partitions (without slot suffix) and their sizes; slotted ones get _a and _b. */
	physical?: Record<string, number>;
	unslotted?: Record<string, number>;
	superSize?: number;
	/** Unlock prompt answer. */
	unlockAnswer?: "yes" | "no";
	unlockAbility?: 0 | 1;
	/** Fail this command (exact text) once with FAIL. */
	failOnce?: string;
}

export class FakePhone {
	mode: "bootloader" | "fastbootd" | "android" | "off" = "bootloader";
	product: string;
	serial: string;
	unlocked: boolean;
	slot: "a" | "b";
	maxDownload: number;
	physical = new Map<string, Uint8Array>();
	logical = new Map<string, Uint8Array>();
	superNames: string[] = [];
	superSize: number;
	commands: string[] = [];
	erased = new Set<string>();
	snapshotStatus = "none";
	unlockAnswer: "yes" | "no";
	unlockAbility: 0 | 1;
	failOnce: string | undefined;
	/** Every connection the phone has had; the current one is last. */
	links: FakeTransport[] = [];
	private buffer: Uint8Array | null = null;

	constructor(o: FakeOptions = {}) {
		this.product = o.product ?? "cheetah";
		this.serial = o.serial ?? "28161FDH2000AB";
		this.unlocked = o.unlocked ?? true;
		this.slot = o.slot ?? "a";
		this.maxDownload = o.maxDownload ?? 1024 * 1024;
		this.superSize = o.superSize ?? 64 * 1024 * 1024;
		this.unlockAnswer = o.unlockAnswer ?? "yes";
		this.unlockAbility = o.unlockAbility ?? 1;
		this.failOnce = o.failOnce;
		const physical = o.physical ?? { boot: 256 * 1024, init_boot: 128 * 1024, vendor_boot: 256 * 1024, dtbo: 64 * 1024, vbmeta: 64 * 1024, vbmeta_system: 16 * 1024 };
		for (const [p, size] of Object.entries(physical)) {
			this.physical.set(`${p}_a`, new Uint8Array(size).fill(0xee));
			this.physical.set(`${p}_b`, new Uint8Array(size).fill(0xee));
		}
		for (const [p, size] of Object.entries(o.unslotted ?? { userdata: 128 * 1024, metadata: 64 * 1024 })) this.physical.set(p, new Uint8Array(size).fill(0xdd));
		// What the phone had before: an old layout in super
		for (const p of ["system_a", "vendor_a", "product_a", "system_b", "vendor_b", "product_b", "old_a"]) this.logical.set(p, new Uint8Array(4096).fill(0xcc));
		this.superNames = [...this.logical.keys()];
	}

	connect(): FakeTransport {
		const t = new FakeTransport(this);
		this.links.push(t);
		return t;
	}

	get current(): FakeTransport {
		return this.links[this.links.length - 1];
	}

	private hasSlot(p: string): boolean {
		return this.physical.has(`${p}_a`) || this.logical.has(`${p}_a`) || this.superNames.includes(`${p}_a`);
	}

	private getvar(name: string): string | null {
		const [v, arg] = name.split(/:(.*)/s);
		switch (v) {
			case "product":
				return this.product;
			case "serialno":
				return this.serial;
			case "unlocked":
				return this.unlocked ? "yes" : "no";
			case "is-userspace":
				return this.mode === "fastbootd" ? "yes" : "no";
			case "max-download-size":
				return `0x${this.maxDownload.toString(16)}`;
			case "slot-count":
				return "2";
			case "current-slot":
				return this.slot;
			case "has-slot":
				return this.hasSlot(arg) ? "yes" : "no";
			case "super-partition-name":
				return "super";
			case "snapshot-update-status":
				return this.snapshotStatus;
			case "version-bootloader":
				return "cloudripper-16.4-13506318";
			case "version-baseband":
				return "g5300g-250909-251024-B-14326967";
			case "partition-size": {
				const p = this.physical.get(arg) ?? (this.mode === "fastbootd" ? this.logical.get(arg) : undefined);
				return p ? `0x${p.byteLength.toString(16)}` : null;
			}
			case "partition-type":
				if (arg === "userdata") return "f2fs";
				if (arg === "metadata") return "ext4";
				return this.physical.has(arg) || this.logical.has(arg) ? "raw" : null;
			case "is-logical":
				if (this.mode !== "fastbootd") return null;
				return this.logical.has(arg) ? "yes" : this.physical.has(arg) ? "no" : null;
			default:
				return null;
		}
	}

	/** Handles one command; returns the replies. */
	handle(cmd: string): string[] {
		this.commands.push(cmd);
		if (this.failOnce === cmd) {
			this.failOnce = undefined;
			return ["FAILsimulated failure"];
		}
		if (this.mode !== "bootloader" && this.mode !== "fastbootd") throw new Error(`command ${cmd} while ${this.mode}`);
		const [verb, rest = ""] = cmd.split(/:(.*)/s);
		switch (verb) {
			case "getvar": {
				const v = this.getvar(rest);
				return v === null ? ["FAILGetVar Variable Not found"] : [`OKAY${v}`];
			}
			case "download": {
				const n = parseInt(rest, 16);
				if (!(n > 0) || n > this.maxDownload) return ["FAILdata too large"];
				this.current.expectData(n);
				return [`DATA${rest}`];
			}
			case "flash":
				return this.flash(rest);
			case "erase": {
				const p = this.physical.get(rest);
				if (!p) return ["FAILno such partition"];
				p.fill(0);
				this.erased.add(rest);
				return ["OKAY"];
			}
			case "set_active":
				if (rest !== "a" && rest !== "b") return ["FAILbad slot"];
				this.slot = rest;
				return ["OKAY"];
			case "snapshot-update":
				if (rest !== "cancel") return ["FAILunknown"];
				this.snapshotStatus = "none";
				return ["OKAY"];
			case "reboot-fastboot":
				this.restart("fastbootd");
				return ["OKAY"];
			case "reboot-bootloader":
				this.restart("bootloader");
				return ["OKAY"];
			case "reboot":
				this.restart("android");
				return ["OKAY"];
			case "update-super": {
				if (this.mode !== "fastbootd") return ["FAILupdate-super is only in fastbootd"];
				const [name, wipe] = rest.split(":");
				if (name !== "super") return ["FAILno such super partition"];
				const names = this.buffer ? logicalPartitions(this.buffer) : null;
				if (!names) return ["FAILinvalid super_empty"];
				// The new layout: every listed partition, empty; old ones are dropped
				this.logical = new Map(names.map((n) => [n, new Uint8Array(0)]));
				this.superNames = names;
				this.lastSuperWipe = wipe === "wipe";
				return ["OKAY"];
			}
			case "resize-logical-partition": {
				if (this.mode !== "fastbootd") return ["FAILnot in fastbootd"];
				const [p, size] = rest.split(":");
				const cur = this.logical.get(p);
				if (!cur) return ["FAILno such logical partition"];
				// liblp rounds a logical partition up to the logical block size (MetadataBuilder::ResizePartition)
				const n = Math.ceil(Number(size) / 4096) * 4096;
				const used = [...this.logical.entries()].reduce((a, [k, v]) => a + (k === p ? 0 : v.byteLength), 0);
				if (used + n > this.superSize) return ["FAILnot enough space in super"];
				const next = new Uint8Array(n);
				next.set(cur.subarray(0, Math.min(n, cur.byteLength)));
				this.logical.set(p, next);
				return ["OKAY"];
			}
			default:
				if (cmd === "flashing unlock") {
					if (this.unlockAnswer === "no") return ["FAILuser cancelled"];
					this.unlocked = true;
					return ["INFOerasing userdata...", "OKAY"];
				}
				if (cmd === "flashing get_unlock_ability") return [`INFO(bootloader) get_unlock_ability: ${this.unlockAbility}`, "OKAY"];
				return ["FAILunknown command"];
		}
	}

	lastSuperWipe = false;

	private flash(name: string): string[] {
		if (!this.unlocked) return ["FAILFlashing is not allowed in Lock State"];
		const img = this.buffer;
		if (!img) return ["FAILno data downloaded"];
		const sparse = new DataView(img.buffer, img.byteOffset, img.byteLength).getUint32(0, true) === 0xed26ff3a;
		let target = this.physical.get(name);
		if (!target) {
			if (this.logical.has(name) || this.superNames.includes(name)) {
				if (this.mode !== "fastbootd") return [`FAILpartition (${name}) not found`];
				target = this.logical.get(name)!;
			} else {
				return [`FAILpartition (${name}) not found`];
			}
		}
		if (sparse) {
			try {
				applySparse(img, target);
			} catch (e) {
				return [`FAIL${(e as Error).message}`];
			}
		} else {
			if (img.byteLength > target.byteLength) return [`FAILimage (${img.byteLength}) is larger than the partition (${target.byteLength})`];
			target.set(img, 0);
		}
		this.writes.push(name);
		return ["OKAY"];
	}

	writes: string[] = [];

	receiveData(data: Uint8Array) {
		this.buffer = data;
	}

	private restart(to: "bootloader" | "fastbootd" | "android") {
		this.current.disconnectAfterReply();
		this.mode = "off";
		this.nextMode = to;
	}

	nextMode: "bootloader" | "fastbootd" | "android" = "bootloader";

	/** The phone finishes restarting. */
	boot() {
		this.mode = this.nextMode;
	}
}

export class FakeTransport implements Transport {
	private replies: Uint8Array[] = [];
	private waiter: ((b: Uint8Array) => void) | null = null;
	private dataLeft = 0;
	private data: Uint8Array[] = [];
	private dying = false;
	closed = false;
	gone = false;
	/** Bytes per bulk OUT transfer seen. */
	transferSizes: number[] = [];

	constructor(private readonly phone: FakePhone) {}

	expectData(n: number) {
		this.dataLeft = n;
		this.data = [];
	}

	disconnectAfterReply() {
		this.dying = true;
	}

	private push(r: string) {
		const b = enc.encode(r);
		if (this.waiter) {
			const w = this.waiter;
			this.waiter = null;
			w(b);
		} else this.replies.push(b);
	}

	async send(data: Uint8Array): Promise<void> {
		if (this.gone || this.closed) throw new DOMException("The device was disconnected.", "NetworkError");
		this.transferSizes.push(data.byteLength);
		if (this.dataLeft > 0) {
			if (data.byteLength > this.dataLeft) throw new Error("sent more data than announced");
			this.data.push(data.slice());
			this.dataLeft -= data.byteLength;
			if (this.dataLeft === 0) {
				const n = this.data.reduce((a, d) => a + d.byteLength, 0);
				const all = new Uint8Array(n);
				let o = 0;
				for (const d of this.data) {
					all.set(d, o);
					o += d.byteLength;
				}
				this.phone.receiveData(all);
				this.push("OKAY");
			}
			return;
		}
		const cmd = dec.decode(data);
		for (const r of this.phone.handle(cmd)) this.push(r);
	}

	async receive(): Promise<Uint8Array> {
		if (this.replies.length) {
			const r = this.replies.shift()!;
			if (this.dying && !this.replies.length) this.gone = true;
			return r;
		}
		if (this.gone || this.closed) throw new DOMException("The device was disconnected.", "NetworkError");
		return new Promise((resolve) => (this.waiter = resolve));
	}
}

/** Restarts the simulated phone and connects to it again. */
export class FakeConnector implements Connector {
	restarts: string[] = [];
	/** Runs while the phone is off, before it comes back (a test's chance to change what it boots). */
	whileOff: ((phone: FakePhone) => void) | null = null;

	constructor(private readonly phone: FakePhone) {}

	link(): Link {
		const t = this.phone.connect();
		return {
			transport: t,
			serial: this.phone.serial,
			close: async () => {
				t.closed = true;
			},
		};
	}

	async restart(link: Link, send: () => Promise<void>): Promise<Link> {
		await send();
		await link.close();
		this.restarts.push(this.phone.nextMode);
		this.whileOff?.(this.phone);
		this.phone.boot();
		if (this.phone.mode === "android") throw new Error("the phone started Android instead of fastboot");
		return this.link();
	}

	async release(link: Link, send: () => Promise<void>): Promise<void> {
		await send();
		await link.close();
		this.phone.boot();
	}
}
