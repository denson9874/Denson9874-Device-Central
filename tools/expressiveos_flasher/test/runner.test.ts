// A whole install on the simulated phone: the zip's images, read the way the page reads them,
// written by the plan the page builds, and what ends up on each partition checked byte for byte.

import { describe, expect, it } from "vitest";
import { FastbootClient, FastbootError, ProtocolError, type Transport, payloadOf } from "../src/fastboot/client.ts";
import { Phone } from "../src/fastboot/device.ts";
import { logicalPartitions } from "../src/fastboot/lp.ts";
import { buildPlan } from "../src/flash/plan.ts";
import { canUnlock, inspectPhone, unlockBootloader } from "../src/flash/preflight.ts";
import { EraseError, type ImageSource, InstallError, runPlan, stepWeights } from "../src/flash/runner.ts";
import { ZipReader } from "../src/zip/zip.ts";
import { FakeConnector, FakePhone } from "./fake-phone.ts";
import { bytes, expandSparse, makeSparse, makeSuperEmpty, makeZip, withAvbFooter } from "./helpers.ts";

const BS = 4096;
const INFO = `version 1
flash boot
flash init_boot
flash vendor_boot
flash dtbo
flash --apply-vbmeta vbmeta
flash vbmeta_system
reboot fastboot
update-super
flash product
flash system
flash vendor
if-wipe erase userdata
if-wipe erase metadata
`;

const images = {
	"boot.img": withAvbFooter(bytes(100_000, 11)),
	"init_boot.img": bytes(90_000, 12), // KernelSU Next's
	"vendor_boot.img": bytes(256 * 1024, 13), // fills its partition
	"dtbo.img": bytes(20_000, 14),
	"vbmeta.img": bytes(8192, 15),
	"vbmeta_system.img": bytes(4096, 16),
	// system: sparse, bigger than the download buffer
	"system.img": makeSparse(BS, [{ raw: bytes(BS * 300, 17) }, { skip: 50 }, { fill: 0x11223344, blocks: 20 }, { raw: bytes(BS * 200, 18) }, { skip: 30 }]),
	// vendor: raw, bigger than the download buffer
	"vendor.img": bytes(BS * 400 + 1000, 19),
	"product.img": makeSparse(BS, [{ raw: bytes(BS * 10, 20) }, { skip: 6 }]),
	"super_empty.img": makeSuperEmpty(["product_a", "product_b", "system_a", "system_b", "vendor_a", "vendor_b"]),
};
const STOCK = bytes(70_000, 99);
const zipBytes = makeZip(
	[
		{ name: "android-info.txt", data: new TextEncoder().encode("require board=cheetah\n") },
		{ name: "fastboot-info.txt", data: new TextEncoder().encode(INFO) },
		...Object.entries(images).map(([name, data]) => ({ name, data })),
	],
	{ zip64: true },
);

async function setup(opts: { wipe: boolean; root: boolean }, phoneOpts: ConstructorParameters<typeof FakePhone>[0] = {}) {
	const fake = new FakePhone(phoneOpts);
	const connector = new FakeConnector(fake);
	const phone = new Phone(connector.link(), connector);
	const zip = await ZipReader.open(new Blob([zipBytes]));
	const has = (n: string) => !!zip.entry(n);
	const logical = logicalPartitions(await zip.bytes("super_empty.img"));
	const steps = buildPlan(await zip.text("fastboot-info.txt"), has, logical, { ...opts, hasStockInitBoot: true });
	const source: ImageSource = {
		image: async (ref) => (ref.kind === "zip" ? zip.blob(ref.name) : new Blob([STOCK])),
		superEmpty: () => zip.blob("super_empty.img"),
		size: (ref) => (ref.kind === "zip" ? zip.entry(ref.name)!.size : STOCK.byteLength),
	};
	return { fake, connector, phone, steps, source };
}

const same = (a: Uint8Array, b: Uint8Array) => Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0;

describe("install on a simulated phone", () => {
	it("installs with root and a wipe", async () => {
		const { fake, connector, phone, steps, source } = await setup({ wipe: true, root: true });
		const states: string[] = [];
		let last = -1;
		const weights = stepWeights(steps, source);
		expect(weights.every((w) => w > 0)).toBe(true);
		await runPlan(phone, steps, source, {
			step: (i, s) => states.push(`${i}:${s}`),
			progress: (_i, f) => {
				expect(f).toBeGreaterThanOrEqual(0);
				expect(f).toBeLessThanOrEqual(1);
				last = f;
			},
			note: () => {},
		});
		expect(last).toBe(1);
		expect(fake.mode).toBe("android");
		expect(connector.restarts).toEqual(["fastbootd"]);

		// Physical partitions, current slot (a)
		expect(same(fake.physical.get("init_boot_a")!.subarray(0, 90_000), images["init_boot.img"])).toBe(true);
		expect(same(fake.physical.get("vendor_boot_a")!, images["vendor_boot.img"])).toBe(true);
		expect(fake.physical.get("init_boot_b")!.every((b) => b === 0xee)).toBe(true);
		// boot's AVB footer is also at the partition's end
		const boot = fake.physical.get("boot_a")!;
		const img = images["boot.img"];
		expect(same(boot.subarray(0, img.byteLength), img)).toBe(true);
		expect(same(boot.subarray(boot.byteLength - 64), img.subarray(img.byteLength - 64))).toBe(true);

		// Logical partitions, laid out afresh, each exactly its image
		expect([...fake.logical.keys()].sort()).toEqual(["product_a", "product_b", "system_a", "system_b", "vendor_a", "vendor_b"]);
		expect(same(fake.logical.get("system_a")!, expandSparse(images["system.img"]))).toBe(true);
		expect(same(fake.logical.get("product_a")!, expandSparse(images["product.img"]))).toBe(true);
		const vendor = fake.logical.get("vendor_a")!;
		expect(vendor.byteLength).toBe(Math.ceil(images["vendor.img"].byteLength / BS) * BS);
		expect(same(vendor.subarray(0, images["vendor.img"].byteLength), images["vendor.img"])).toBe(true);
		expect(fake.logical.get("system_b")!.byteLength).toBe(0);
		expect(fake.lastSuperWipe).toBe(true);

		// Wiped, from fastbootd as fastboot-info.txt says
		expect([...fake.erased].sort()).toEqual(["metadata", "userdata"]);
		// Pieces never went over the download buffer, nor transfers over 256 KiB
		expect(fake.commands.filter((c) => c.startsWith("download:")).every((c) => parseInt(c.slice(9), 16) <= fake.maxDownload)).toBe(true);
		for (const t of fake.links) expect(Math.max(...t.transferSizes)).toBeLessThanOrEqual(256 * 1024);
		// Big images went in several pieces
		expect(fake.writes.filter((w) => w === "system_a").length).toBeGreaterThan(1);
		expect(fake.writes.filter((w) => w === "vendor_a").length).toBeGreaterThan(1);
		expect(fake.commands).toContain("set_active:a");
		expect(fake.commands.indexOf("update-super:super:wipe")).toBeLessThan(fake.commands.indexOf("flash:system_a"));
		expect(fake.commands).toContain("resize-logical-partition:system_a:0");
		expect(states.filter((s) => s.endsWith(":done")).length + states.filter((s) => s.endsWith(":skipped")).length).toBe(steps.length);
	});

	it("installs without root, keeping data, on slot b", async () => {
		const { fake, phone, steps, source } = await setup({ wipe: false, root: false }, { slot: "b" });
		await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} });
		expect(same(fake.physical.get("init_boot_b")!.subarray(0, STOCK.byteLength), STOCK)).toBe(true);
		expect(same(fake.physical.get("init_boot_a")!.subarray(0, STOCK.byteLength), STOCK)).toBe(true);
		expect(fake.erased.size).toBe(0);
		expect(fake.lastSuperWipe).toBe(false);
		expect(same(fake.logical.get("system_b")!, expandSparse(images["system.img"]))).toBe(true);
		expect(fake.physical.get("userdata")!.every((b) => b === 0xdd)).toBe(true);
	});

	it("cancels an unfinished system update first", async () => {
		const { fake, phone, steps, source } = await setup({ wipe: true, root: true });
		fake.snapshotStatus = "merging";
		await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} });
		expect(fake.commands).toContain("snapshot-update:cancel");
	});

	it("stops at the step the phone refuses, saying which", async () => {
		const { phone, steps, source } = await setup({ wipe: true, root: true }, { failOnce: "flash:dtbo_a" });
		const err = await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} }).catch((e) => e);
		expect(err).toBeInstanceOf(InstallError);
		expect((err as InstallError).step).toMatchObject({ kind: "flash", partition: "dtbo" });
		expect((err as InstallError).cause).toBeInstanceOf(FastbootError);
	});

	it("refuses to write a locked phone", async () => {
		const { phone, steps, source } = await setup({ wipe: true, root: true }, { unlocked: false });
		const err = await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} }).catch((e) => e);
		expect(String(err)).toMatch(/Lock State/);
	});

	it("stops when the phone comes back from the restart into fastbootd on the other slot", async () => {
		const { fake, connector, phone, steps, source } = await setup({ wipe: true, root: true });
		// The boot images just written to slot a don't start, so the bootloader falls back to slot
		// b, whose fastbootd answers with the same serial number
		connector.whileOff = (p) => {
			if (p.nextMode === "fastbootd") p.slot = "b";
		};
		const err = await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} }).catch((e) => e);
		expect(err).toBeInstanceOf(InstallError);
		expect((err as InstallError).step).toEqual({ kind: "reboot", target: "fastbootd" });
		expect((err as InstallError).cause).toBeInstanceOf(ProtocolError);
		expect((err as InstallError).message).toMatch(/slot B instead of slot A/);
		// Nothing went to slot b, super's layout wasn't touched, nothing was erased
		expect(fake.writes.filter((w) => w.endsWith("_b"))).toEqual([]);
		expect(fake.commands.some((c) => c.startsWith("update-super") || c.startsWith("resize-logical-partition"))).toBe(false);
		expect(fake.erased.size).toBe(0);
		expect(fake.mode).toBe("fastbootd");
	});

	it("stops a clean install when metadata can't be erased, as fastboot does", async () => {
		const { fake, phone, steps, source } = await setup({ wipe: true, root: true }, { failOnce: "erase:metadata" });
		const err = await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} }).catch((e) => e);
		expect(err).toBeInstanceOf(InstallError);
		expect((err as InstallError).step).toEqual({ kind: "erase", partition: "metadata" });
		expect((err as InstallError).cause).toBeInstanceOf(EraseError);
		expect((err as InstallError).message).toMatch(/couldn't erase metadata \(simulated failure\)\. A clean install has to erase it/);
		expect(fake.erased.has("userdata")).toBe(true);
		// It never said it was done: the phone wasn't told to start Android
		expect(fake.commands).not.toContain("reboot");
		expect(fake.mode).toBe("fastbootd");
	});

	it("stops a clean install when userdata can't be erased", async () => {
		const { fake, phone, steps, source } = await setup({ wipe: true, root: true }, { failOnce: "erase:userdata" });
		const err = await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} }).catch((e) => e);
		expect((err as InstallError).step).toEqual({ kind: "erase", partition: "userdata" });
		expect((err as InstallError).cause).toBeInstanceOf(EraseError);
		expect(fake.commands).not.toContain("erase:metadata");
	});

	it("goes on from fastbootd after an earlier attempt stopped there", async () => {
		const { fake, connector, phone, steps, source } = await setup({ wipe: true, root: true });
		fake.mode = "fastbootd";
		await runPlan(phone, steps, source, { step: () => {}, progress: () => {}, note: () => {} });
		// Already in fastbootd: no restart needed for the logical partitions
		expect(connector.restarts).toEqual([]);
		expect(same(fake.logical.get("system_a")!, expandSparse(images["system.img"]))).toBe(true);
		expect(same(fake.physical.get("init_boot_a")!.subarray(0, 90_000), images["init_boot.img"])).toBe(true);
	});
});

describe("before installing", () => {
	it("reports the phone and checks android-info.txt", async () => {
		const fake = new FakePhone({ product: "husky", unlocked: false });
		const c = new FakeConnector(fake);
		const r = await inspectPhone(new Phone(c.link(), c), "require board=cheetah\n");
		expect(r.product).toBe("husky");
		expect(r.unlocked).toBe(false);
		expect(r.mode).toBe("bootloader");
		expect(r.requirements[0].ok).toBe(false);
	});

	it("unlocks when the user says yes, and not when they say no", async () => {
		const yes = new FakePhone({ unlocked: false });
		const c1 = new FakeConnector(yes);
		const p1 = new Phone(c1.link(), c1);
		expect(await canUnlock(p1)).toBe(true);
		expect(await unlockBootloader(p1)).toBe("unlocked");
		expect(yes.unlocked).toBe(true);
		const no = new FakePhone({ unlocked: false, unlockAnswer: "no", unlockAbility: 0 });
		const c2 = new FakeConnector(no);
		const p2 = new Phone(c2.link(), c2);
		expect(await canUnlock(p2)).toBe(false);
		expect(await unlockBootloader(p2)).toBe("refused");
	});
});

describe("fastboot protocol", () => {
	it("gives null for a variable the phone doesn't have", async () => {
		const fake = new FakePhone();
		const c = new FastbootClient(fake.connect());
		expect(await c.getVar("nope")).toBeNull();
		expect(await c.getVar("product")).toBe("cheetah");
	});

	it("refuses commands that are too long or not text", async () => {
		const c = new FastbootClient(new FakePhone().connect());
		await expect(c.command(`getvar:${"x".repeat(80)}`)).rejects.toThrow(ProtocolError);
		await expect(c.command("getvar:\nproduct")).rejects.toThrow(ProtocolError);
	});

	it("gives up on a phone that stops answering, and stays given up", async () => {
		let abandoned = 0;
		const silent: Transport = { send: async () => {}, receive: () => new Promise<Uint8Array>(() => {}), abandon: () => abandoned++ };
		const c = new FastbootClient(silent);
		const err = await c.command("getvar:product", { timeoutMs: 50 }).catch((e) => e);
		expect(err).toBeInstanceOf(ProtocolError);
		// A late reply may still come, so the next connection resets the phone, and the user is told
		// how to restart it where that isn't possible
		expect((err as Error).message).toMatch(/Restart it into Fastboot Mode by holding Power and Volume down/);
		expect(c.isBroken).toBe(true);
		expect(abandoned).toBe(1);
		await expect(c.command("getvar:product")).rejects.toThrow(/lost/);
	});

	it("finishes a download it can't read to the end, so the phone takes the next command", async () => {
		const MiB = 1024 * 1024;
		const fake = new FakePhone({ maxDownload: 4 * MiB });
		const t = fake.connect();
		let abandoned = 0;
		const c = new FastbootClient({ send: (d) => t.send(d), receive: () => t.receive(), abandon: () => abandoned++ });
		// The stored file changes under its snapshot after 1 MiB, as a File can in the browser
		class Unreadable extends Blob {
			override slice(start?: number, end?: number, type?: string): Blob {
				const b = super.slice(start, end, type);
				if ((start ?? 0) < MiB) return b;
				return Object.assign(b, { arrayBuffer: () => Promise.reject(new DOMException("The requested file could not be read.", "NotReadableError")) });
			}
		}
		const sent: number[] = [];
		const err = await c.download(payloadOf([new Unreadable([new Uint8Array(3 * MiB)])]), (n) => sent.push(n)).catch((e) => e);
		expect((err as Error).name).toBe("NotReadableError");
		expect(sent[sent.length - 1]).toBe(MiB);
		// The rest went as zeros, the phone answered, and the session goes on
		expect(c.isBroken).toBe(false);
		expect(abandoned).toBe(0);
		expect(await c.getVar("product")).toBe("cheetah");
		expect(fake.commands).toEqual(["download:00300000", "getvar:product"]);
		expect(fake.writes).toEqual([]);
	});

	it("gives up when USB fails part way through a download, and marks the phone for a reset", async () => {
		const fake = new FakePhone({ maxDownload: 4 * 1024 * 1024 });
		const t = fake.connect();
		let abandoned = 0;
		let n = 0;
		const flaky: Transport = {
			send: async (d) => {
				if (++n === 3) throw new DOMException("A transfer error has occurred.", "NetworkError");
				await t.send(d);
			},
			receive: () => t.receive(),
			abandon: () => abandoned++,
		};
		const c = new FastbootClient(flaky);
		await expect(c.download(payloadOf([bytes(1024 * 1024, 3)]))).rejects.toThrow(/transfer error/);
		expect(c.isBroken).toBe(true);
		expect(abandoned).toBe(1);
		await expect(c.getVar("product")).rejects.toThrow(/lost/);
	});
});
