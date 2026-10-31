// The page's steps, driven through their buttons on a small DOM in Node (app-harness.ts), with the
// simulated Pixel behind WebUSB: what the stepper lets through, what Install checks itself, and
// what each step does with a zip, a phone or a failure that changed under it.

import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConnectOptions } from "../src/adb/adb.ts";
import { browserAdbKey } from "../src/adb/key.ts";
import { deviceByCodename } from "../src/devices.ts";
import { USB_DRIVER_URL, openFailure } from "../src/fastboot/webusb.ts";
import type { Release } from "../src/releases.ts";
import { StoreError, storeName } from "../src/store/store.ts";
import { App } from "../src/ui/app.ts";
import { type FakeElement, type Page, buttonIn, buttonsIn, fakeDom, fakeNavigatorUsb, plugIn, unplug, world } from "./app-harness.ts";
import { FakeAdbPhone, type FakeAdbOptions } from "./fake-adb.ts";
import { FakePhone, type FakeOptions } from "./fake-phone.ts";
import { bytes, makeSuperEmpty, makeZip } from "./helpers.ts";

/** How long a phone running Android has to answer, and its user to tap Allow (the page's own are 10 s and 3 min). */
const adbTiming = vi.hoisted(() => ({ answerTimeoutMs: 300, allowTimeoutMs: 800, settleMs: 20 }));

vi.mock("../src/ui/bloom.ts", async () => {
	const h = await import("./app-harness.ts");
	return { BloomStage: h.FakeBloom, bloomMark: () => new h.FakeElement("svg") };
});
vi.mock("../src/fastboot/usb-connector.ts", async () => {
	const h = await import("./app-harness.ts");
	return { linkTo: h.linkTo, WebUsbConnector: h.WebUsbConnector };
});
vi.mock("../src/fastboot/webusb.ts", async (importOriginal) => {
	const h = await import("./app-harness.ts");
	return { ...(await importOriginal<object>()), UsbTransport: h.FakeUsbTransport };
});
vi.mock("../src/store/store.ts", async (importOriginal) => ({ ...(await importOriginal<object>()), ...(await import("./app-harness.ts")).store }));
// USB debugging as the page does it (src/adb/), over the simulated adbd (fake-adb.ts), on shorter timings
vi.mock("../src/adb/adb.ts", async (importOriginal) => {
	const adb = await importOriginal<typeof import("../src/adb/adb.ts")>();
	return { ...adb, connectAdb: (d: USBDevice, o: ConnectOptions = {}) => adb.connectAdb(d, { ...o, ...adbTiming }) };
});

// ---------- Builds ----------

const enc = new TextEncoder();
const INFO = "version 1\nflash boot\nflash init_boot\nflash vendor_boot\nflash --apply-vbmeta vbmeta\nreboot fastboot\nupdate-super\nflash system\nif-wipe erase userdata\nif-wipe erase metadata\n";
const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

interface Build {
	release: Release;
	zip: Uint8Array;
	initBoot: Uint8Array;
	stock: Uint8Array | null;
}

function build(device: string, version: string, date: string, androidInfo: string, opts: { stock: boolean; seed: number }): Build {
	const initBoot = bytes(8192, opts.seed + 1);
	const zip = makeZip([
		{ name: "android-info.txt", data: enc.encode(androidInfo) },
		{ name: "fastboot-info.txt", data: enc.encode(INFO) },
		{ name: "boot.img", data: bytes(8192, opts.seed) },
		{ name: "init_boot.img", data: initBoot },
		{ name: "vendor_boot.img", data: bytes(8192, opts.seed + 2) },
		{ name: "vbmeta.img", data: bytes(4096, opts.seed + 3) },
		{ name: "super_empty.img", data: makeSuperEmpty(["system_a", "system_b"]) },
		{ name: "system.img", data: bytes(16384, opts.seed + 4) },
	]);
	const stock = opts.stock ? bytes(6000, opts.seed + 9) : null;
	const name = `ExpressiveOS-16.0-${date.replaceAll("-", "")}-${device}-${version}-Unofficial`;
	const release: Release = {
		name,
		channel: "release",
		android: "16.0",
		version,
		type: "Unofficial",
		date,
		published: `${date}T12:00:00Z`,
		zip: { file: `${name}-fastboot.zip`, size: zip.byteLength, sha256: sha(zip) },
		initBootStock: stock ? { file: `${name}-init_boot-stock.img`, size: stock.byteLength, sha256: sha(stock) } : null,
		root: stock ? "kernelsu-next" : null,
		requirements: [],
	};
	return { release, zip, initBoot, stock };
}

/** Lists the builds for their phone, with each zip already downloaded unless said otherwise. */
function publish(builds: Build[], opts: { stored?: boolean } = {}) {
	world.releases = builds.map((b) => b.release);
	for (const b of builds) {
		if (opts.stored !== false) world.stored.set(storeName(b.release.zip.sha256, "zip"), zipFile(b));
		if (b.stock) world.files.set(b.release.initBootStock!.file, b.stock);
	}
}

const zipFile = (b: Build) => new File([b.zip.slice()], b.release.zip.file);

// ---------- Driving the page ----------

let page: Page;

beforeEach(() => {
	const dom = fakeDom();
	for (const [k, v] of Object.entries(dom.globals)) vi.stubGlobal(k, v);
	vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/141.0", storage: {} });
	vi.stubGlobal("fetch", async (url: string) => {
		const m = /^\/api\/releases\/(\w+)$/.exec(url);
		if (!m) return new Response(null, { status: 404 });
		return Response.json({ schema: 1, device: m[1], updated: "2026-10-30T12:00:00Z", releases: world.releases });
	});
	page = dom.page;
	world.device = null;
	world.android = null;
	world.unpermitted = new WeakSet();
	world.askAfterMs = 0;
	world.reconnectTimeoutMs = 5000;
	Object.assign(adbTiming, { answerTimeoutMs: 300, allowTimeoutMs: 800, settleMs: 20 });
	world.stored = new Map();
	world.files = new Map();
	world.releases = [];
	world.download = () => Promise.reject(new Error("no download"));
	world.hash = () => Promise.reject(new Error("no hash"));
});

afterEach(() => {
	vi.unstubAllGlobals();
	// Whatever a test did, the page never opened a service on a phone running Android but the restart
	for (const p of androids.splice(0)) for (const service of p.opened) expect(service).toBe("reboot:bootloader");
});

const settle = async () => {
	for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 0));
};

const text = () => page.panel.textContent;

async function until(cond: () => boolean, what: string) {
	for (let i = 0; i < 2000 && !cond(); i++) await new Promise((r) => setTimeout(r, 1));
	if (!cond()) throw new Error(`Timed out waiting for ${what}. The panel says: ${text()}`);
}

async function press(label: string | RegExp, root: FakeElement = page.panel) {
	const b = buttonIn(root, label);
	if (!b) throw new Error(`No button ${label}; there are ${JSON.stringify(buttonsIn(root))}. The panel says: ${text()}`);
	expect(b.disabled, `${label} is disabled`).toBe(false);
	b.click();
	await settle();
}

/** The stepper's button for a step. */
const step = (label: string) => buttonIn(page.stepper, new RegExp(`^\\d\\. ${label}$`))!;

function choose(group: string, value: string) {
	const input = page.panel.querySelector(`input[name="${group}"][value="${value}"]`);
	if (!input) throw new Error(`No ${group} choice ${value}`);
	input.checked = true;
	input.dispatchEvent(new Event("change"));
}

function tick() {
	const box = page.panel.querySelector('input[type="checkbox"]')!;
	box.checked = true;
	box.dispatchEvent(new Event("change"));
}

/** Opens the page and goes to the Build step for a phone. */
async function start(model: string, codename: string): Promise<App> {
	const app = new App();
	await press(`${model}${codename}`);
	await press(`Continue with ${model}`);
	await until(() => text().includes("Install type"), "the build list");
	return app;
}

/** From the Build step, with the zip already in the browser, on to a connected phone. */
async function toConnected() {
	await press("Continue");
	await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
	expect(text()).toContain("Downloaded and checked");
	await press("Continue");
	await press("Connect");
	await until(() => /Ready to install|different phone|doesn't accept|locked/.test(text()), "the phone's checks");
}

async function install() {
	if (page.panel.querySelector('input[type="checkbox"]')) tick();
	await press("Install");
	await until(() => /ExpressiveOS is installed|didn't start|Stopped at/.test(text()), "the end of the install");
}

const same = (a: Uint8Array, b: Uint8Array) => Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0;
const wrote = (fake: FakePhone) => fake.commands.filter((c) => !c.startsWith("getvar:"));
const privateInstall = (app: App) => (app as unknown as { install(): Promise<void> }).install();

function phone(o: FakeOptions = {}) {
	const fake = new FakePhone(o);
	plugIn(fake);
	return fake;
}

/** USB goes once the phone has answered this command: the next one can't be sent. */
function usbGoesAfter(fake: FakePhone, command: string) {
	const handle = fake.handle.bind(fake);
	fake.handle = (cmd: string) => {
		const replies = handle(cmd);
		if (cmd === command) fake.current.gone = true;
		return replies;
	};
}

const androids: FakeAdbPhone[] = [];

/**
 * A phone running Android with USB debugging on, plugged in (fake-adb.ts), that `trusted` already
 * allows this browser's key. reboot:bootloader takes it off USB, and unless `back` is false it
 * comes back a moment later in Fastboot Mode (fake-phone.ts, with `fastboot`'s options) as a new
 * USB device: one the page may use only once the user picks it, unless `permitted`.
 */
async function android(o: FakeAdbOptions & { trusted?: boolean; permitted?: boolean; back?: boolean; fastboot?: FakeOptions } = {}) {
	const fastboot = new FakePhone({ product: o.device ?? "cheetah", ...o.fastboot });
	const key = Buffer.from((await browserAdbKey()).androidPublicKey()).toString("base64");
	const adb = new FakeAdbPhone({
		serial: fastboot.serial,
		device: fastboot.product,
		model: deviceByCodename(fastboot.product)?.model ?? "Pixel",
		trustedKeys: o.trusted ? [key] : [],
		...o,
	});
	androids.push(adb);
	world.device = null;
	world.android = adb.usb;
	adb.onDisconnect = (d) => {
		if (world.android === d) world.android = null;
		world.usb.dispatchEvent(Object.assign(new Event("disconnect"), { device: d }));
		if (o.back === false) return;
		setTimeout(() => {
			const back = plugIn(fastboot);
			// The browser tells the page only of a device it may use
			if (o.permitted) world.usb.dispatchEvent(Object.assign(new Event("connect"), { device: back }));
			else world.unpermitted.add(back);
		}, 10);
	};
	return { adb, fastboot };
}

/** Everything the page's live region says from now on, in order (an emptying isn't said). */
function sayings(): string[] {
	const live = page.body.querySelector("#announce")!;
	const said: string[] = [];
	let proto: object | null = live;
	let desc: PropertyDescriptor | undefined;
	while (proto && !(desc = Object.getOwnPropertyDescriptor(proto, "textContent"))) proto = Object.getPrototypeOf(proto);
	Object.defineProperty(live, "textContent", {
		configurable: true,
		get() {
			return desc!.get!.call(this);
		},
		set(v: string) {
			if (v) said.push(v);
			desc!.set!.call(this, v);
		},
	});
	return said;
}

/** A notice's title: the first thing in its body, in bold. */
const noticeTitle = (box: FakeElement) => box.querySelector(".notice-body")!.children.find((c) => c.tagName === "strong")?.textContent;

/** From the Build step, with the zip already in the browser, to the Connect step. */
async function toConnect() {
	await press("Continue");
	await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
	await press("Continue");
	expect(text()).toContain("Connect your phone");
}

// ---------- The tests ----------

describe("a build without a stock init_boot (every Pixel 11 build)", () => {
	it("installs, with the zip's own init_boot", async () => {
		const b = build("cubs", "1.0", "2026-10-30", "require board=cubs\n", { stock: false, seed: 10 });
		publish([b]);
		const fake = phone({ product: "cubs" });
		await start("Pixel 11", "cubs");
		expect(text()).toContain("this build installs without root");
		await toConnected();
		expect(text()).toContain("Ready to install");
		await press("Continue");
		expect(text()).toContain("No root");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(same(fake.physical.get("init_boot_a")!.subarray(0, b.initBoot.byteLength), b.initBoot)).toBe(true);
		// Nothing on the other slot: there's no stock image to put there
		expect(fake.physical.get("init_boot_b")!.every((x) => x === 0xee)).toBe(true);
		expect(text()).not.toContain("KernelSU Next app");
	});
});

describe("Install after Connect refused the phone", () => {
	it("can't be opened from the stepper once another model is connected", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 20 });
		publish([b]);
		phone({ failOnce: "set_active:a" });
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		await install();
		expect(text()).toContain("Stopped at");
		// A Pixel 8 Pro instead
		const husky = phone({ product: "husky" });
		await press("Try again");
		await press("Connect");
		await until(() => text().includes("That's a different phone"), "the refusal");
		expect(step("Install").disabled).toBe(true);
		expect(step("Connect").textContent).toBe("4. Connect");
		expect(wrote(husky)).toEqual([]);
	});

	it("refuses in Install itself, before anything is written", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 20 });
		publish([b]);
		phone();
		const app = await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		await press("Back");
		await press("Disconnect");
		const husky = phone({ product: "husky" });
		await press("Connect");
		await until(() => text().includes("That's a different phone"), "the refusal");
		// However the install gets started (a stale button, a stepper bug), it checks the phone itself
		await privateInstall(app);
		await settle();
		expect(text()).toContain("The install didn't start");
		expect(text()).toContain("This is a Pixel 8 Pro (husky)");
		expect(text()).toContain("Nothing was written to the phone.");
		expect(wrote(husky)).toEqual([]);
	});
});

describe("android-info.txt", () => {
	const a = build("cheetah", "1.1", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 30 });
	// An older build that needs newer firmware than the phone has (the fake phone is on 16.4)
	const b = build("cheetah", "1.0", "2026-10-20", "require board=cheetah\nrequire version-bootloader=cloudripper-17.0*\n", { stock: true, seed: 40 });

	it("is checked again against the zip in hand when the build changes after connecting", async () => {
		publish([a, b]);
		const fake = phone();
		const app = await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		expect(text()).toContain("Ready to install");
		// Back to Build, the other build, and on to Connect again
		await press(step("Build").textContent, page.stepper);
		choose("release", `release/${b.release.name}`);
		// The stepper doesn't skip ahead past the download any more
		expect(step("Connect").disabled).toBe(true);
		await press("Continue");
		await until(() => text().includes("Downloaded and checked"), "the other download");
		await press("Continue");
		await until(() => text().includes("doesn't accept this phone"), "the check against the new zip");
		expect(text()).toContain("version-bootloader must be cloudripper-17.0*");
		expect(text()).not.toContain("Ready to install");
		expect(step("Install").disabled).toBe(true);
		// And Install, however it's reached, checks the zip it writes
		await privateInstall(app);
		await settle();
		expect(text()).toContain("This phone can't take this build");
		expect(wrote(fake)).toEqual([]);
	});

	it("is checked against the zip being installed, not the one checked at Connect", async () => {
		publish([a, b]);
		const fake = phone();
		const app = await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		// The zip changes under a phone that was checked against another (as when the report and
		// the zip get out of step in any way)
		const state = app as unknown as { zipFile: File; reportZip: File };
		state.zipFile = zipFile(b);
		state.reportZip = state.zipFile;
		await privateInstall(app);
		await settle();
		expect(text()).toContain("version-bootloader must be cloudripper-17.0*");
		expect(wrote(fake)).toEqual([]);
	});
});

describe("a zip the user picks", () => {
	it("locks the step while it's checked, and can be cancelled", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 50 });
		publish([b], { stored: false });
		let signal: AbortSignal | undefined;
		let finish!: (sha: string) => void;
		world.hash = (_f, _p, s) => {
			signal = s;
			return new Promise<string>((resolve, reject) => {
				finish = resolve;
				s?.addEventListener("abort", () => reject(new StoreError("cancelled", "Cancelled")));
			});
		};
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Use a zip I already have"), "the download step");
		const pickZip = async () => {
			const input = page.panel.querySelector('input[type="file"]')!;
			input.files = [zipFile(b)];
			input.dispatchEvent(new Event("change"));
			await settle();
		};
		await pickZip();
		// Nothing but Cancel while it's checked: no Back to another build, no Download beside it
		expect(buttonsIn(page.panel)).toEqual(["Cancel"]);
		expect(buttonsIn(page.stepper).length).toBe(6);
		expect(page.stepper.querySelectorAll("button").every((x) => x.disabled)).toBe(true);
		await press("Cancel");
		expect(signal?.aborted).toBe(true);
		await until(() => !!buttonIn(page.panel, "Download"), "the step again");
		expect(page.panel.querySelector(".notice-danger")).toBeNull();
		// Picked again and let finish: it's the zip
		await pickZip();
		finish(b.release.zip.sha256);
		await settle();
		await until(() => text().includes("Downloaded and checked"), "the checked zip");
	});
});

describe("unplugging on the Install step", () => {
	it("takes the Install button away", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 60 });
		publish([b]);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		expect(buttonIn(page.panel, "Install")).not.toBeNull();
		unplug();
		await settle();
		expect(text()).toContain("The phone isn't connected any more.");
		expect(buttonIn(page.panel, "Install")).toBeNull();
		expect(step("Install").disabled).toBe(true);
	});
});

describe("Install on another phone", () => {
	it("asks for the install type again, and starts a new log", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 70 });
		publish([b]);
		phone();
		const app = await start("Pixel 7 Pro", "cheetah");
		choose("wipe", "keep");
		await toConnected();
		await press("Continue");
		expect(text()).toContain("Keep data (update)");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		phone({ serial: "SECONDPHONE01" });
		await press("Install on another phone");
		expect(text()).toContain("Choose a build");
		expect(page.panel.querySelector('input[name="wipe"][value="clean"]')?.checked).toBe(true);
		expect((app as unknown as { logLines: unknown[] }).logLines).toEqual([]);
		await toConnected();
		await press("Continue");
		expect(text()).toContain("Clean: erases everything on the phone");
		expect(page.panel.querySelector('input[type="checkbox"]')).not.toBeNull();
	});
});

describe("Detect a connected phone", () => {
	it("leaves the phone's connection open", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 80 });
		publish([b]);
		const fake = phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press(step("Phone").textContent, page.stepper);
		await press("Detect a connected phone");
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
		expect(world.device!.closes).toBe(0);
		await press("Continue with Pixel 7 Pro");
		await until(() => text().includes("Install type"), "the build list");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		await press("Continue");
		// Still connected, and still checked against this zip
		expect(text()).toContain("Ready to install");
		await press("Continue");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(fake.mode).toBe("android");
	});
});

describe("the steps into Fastboot Mode", () => {
	// The browser's list shows a phone running Android only with USB debugging on: the page says so,
	// with the easy way (USB debugging, and the page restarts it) and the way by hand, by Detect and
	// Connect, and again when the list was closed with no phone chosen (NotFoundError)
	const listed = "The browser's list only shows a phone that's running Android with USB debugging on, or one that's in Fastboot Mode.";
	const easy = "The easy way: USB debugging. The page finds the phone while it's running Android, and restarts it into Fastboot Mode for you.";
	const debugging = "On the phone, open Settings, then About phone, and tap Build number seven times. Then open System, Developer options and turn on USB debugging.";
	const cable = "Plug it into this computer with a USB cable that carries data, not a charge-only one.";
	const allow = (button: string) => `Press ${button} and choose your phone in the list. When the phone asks "Allow USB debugging?", tap Allow.`;
	const byHand = "Or by hand. Put the phone in Fastboot Mode yourself.";
	const into = "Turn the phone off. Then hold Power and Volume down together until you see Fastboot Mode.";
	const choose = (button: string) => `Plug it in, press ${button} and choose your phone in the list. It may be called Pixel, Android or Fastboot.`;
	const steps = (root: FakeElement) => root.querySelectorAll("ol.howto li").map((li) => li.textContent);
	const ways = (root: FakeElement) => root.querySelectorAll("p.howto-way").map((p) => p.textContent);
	const all = (button: string) => [debugging, cable, allow(button), into, choose(button)];
	const howto = () => page.panel.querySelector(".fastboot-howto")!;
	/** A notice's title: the first thing in its body, in bold. */
	const title = (box: FakeElement) => box.querySelector(".notice-body")!.children.find((c) => c.tagName === "strong")?.textContent;
	/** Where an element is among the panel's own children. */
	const at = (e: FakeElement | null) => page.panel.children.indexOf(e!);
	const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 150 });

	it("are under Detect a connected phone on the Phone step, the easy way first", () => {
		new App();
		const box = howto();
		expect(box).not.toBeNull();
		expect(at(box)).toBe(at(buttonIn(page.panel, "Detect a connected phone")!.parentNode) + 1);
		expect(box.querySelector("p")?.textContent).toBe(listed);
		expect(ways(box)).toEqual([easy, byHand]);
		expect(box.querySelectorAll("ol.howto").length).toBe(2);
		expect(steps(box)).toEqual(all("Detect a connected phone"));
		expect(box.querySelectorAll("strong").map((s) => s.textContent)).toEqual([
			"The easy way: USB debugging. ",
			"Detect a connected phone",
			"Or by hand. ",
			"Power",
			"Volume down",
			"Fastboot Mode",
			"Detect a connected phone",
		]);
	});

	it("are over Connect on the Connect step, in the same words", async () => {
		publish([b]);
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		const box = howto();
		expect(at(box)).toBe(at(buttonIn(page.panel, "Connect")!.parentNode) - 1);
		expect(box.querySelector("p")?.textContent).toBe(listed);
		expect(ways(box)).toEqual([easy, byHand]);
		expect(steps(box)).toEqual(all("Connect"));
	});

	it("say to use a USB-C cable on Chrome on Android", async () => {
		vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 9) Chrome/141.0 Mobile", storage: {} });
		new App();
		expect(steps(howto())[1]).toBe("Connect it to this phone with a USB-C cable that carries data. An OTG adapter may be needed.");
	});

	it("are in a notice when Detect gets no phone, in place of the step's own", async () => {
		// Nothing in Fastboot Mode, and nothing with USB debugging on: the browser's list is empty,
		// and closing it is a NotFoundError
		new App();
		await press("Detect a connected phone");
		const info = howto().querySelector(".notice-info")!;
		expect(info).not.toBeNull();
		expect(title(info)).toBe("No phone was chosen");
		expect(info.querySelector("p")?.textContent).toBe(listed);
		expect(ways(info)).toEqual([easy, byHand]);
		expect(steps(info)).toEqual(all("Detect a connected phone"));
		// The steps are on the page once, and nothing else is over the step
		expect(page.panel.querySelectorAll("ol.howto").length).toBe(2);
		expect(page.panel.querySelectorAll(".notice").length).toBe(1);
		expect(page.statusTitle.textContent).toBe("Install ExpressiveOS");
		expect(world.bloom!.mode).toBe("idle");
		// Choosing a model keeps it there; once the phone is in Fastboot Mode, Detect finds it
		await press("Pixel 7 Procheetah");
		expect(howto().querySelector(".notice-info")).not.toBeNull();
		phone();
		await press("Detect a connected phone");
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
		expect(page.panel.querySelector(".notice-info")).toBeNull();
		expect(howto().querySelector("p")?.textContent).toBe(listed);
	});

	it("are in a notice when Connect gets no phone, and Connect goes on once it's there", async () => {
		publish([b]);
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		const info = howto().querySelector(".notice-info")!;
		expect(info).not.toBeNull();
		expect(title(info)).toBe("No phone was chosen");
		expect(info.querySelector("p")?.textContent).toBe(listed);
		expect(steps(info)).toEqual(all("Connect"));
		expect(page.panel.querySelectorAll("ol.howto").length).toBe(2);
		expect(page.panel.querySelector(".notice-danger")).toBeNull();
		expect(page.statusTitle.textContent).toBe("Connect your phone");
		expect(world.bloom!.mode).toBe("idle");
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
		phone();
		await press("Connect");
		await until(() => text().includes("Ready to install"), "the phone's checks");
		expect(page.panel.querySelector(".notice-info")).toBeNull();
	});

	it("are in Before you start, in the same words", () => {
		new App();
		const prep = page.panel.querySelectorAll("details.prep li").map((li) => li.textContent);
		expect(prep).toContain(
			"Turn on USB debugging. In Developer options, as for OEM unlocking, turn on USB debugging too. With it on, the page finds the phone while it's running Android and restarts it into Fastboot Mode for you. " +
				`Without it, put the phone in Fastboot Mode yourself. ${into}`,
		);
		expect(prep.find((t) => t.startsWith("Use a USB cable that carries data,"))).toBeDefined();
	});
});

describe("a phone running Android, with USB debugging on", () => {
	const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 160 });
	const byHand = (button: string) =>
		`Or put the phone in Fastboot Mode by hand: turn it off, then hold Power and Volume down together until you see Fastboot Mode, and press ${button} again.`;
	const danger = () => page.panel.querySelector(".notice-danger");

	it("is found by Detect once the user allows USB debugging, and isn't restarted", async () => {
		const { adb } = await android({ device: "husky" });
		new App();
		await press("Detect a connected phone");
		await until(() => text().includes("Tap Allow on your phone."), "the help for the phone's question");
		expect(adb.prompts).toHaveLength(1);
		expect(adb.prompts[0].name).toBe("ExpressiveOS Flasher@browser");
		const box = page.panel.querySelector(".notice-info")!;
		expect(noticeTitle(box)).toBe('Your phone asks "Allow USB debugging?"');
		expect(box.textContent).toContain("Tap Allow on your phone. Tick Always allow from this computer so it doesn't ask again.");
		expect(box.textContent).toContain("If you don't see the question, unlock the phone.");
		expect(box.textContent).toContain("If you tapped Cancel on the phone, press Cancel here, then press Detect a connected phone so the phone asks again.");
		// In place of the steps into Fastboot Mode, by the button that found it
		expect(page.panel.querySelector(".fastboot-howto")).toBeNull();
		expect(buttonIn(page.panel, "Cancel")?.disabled).toBe(false);
		expect(buttonIn(page.panel, "Detect a connected phone")?.disabled).toBe(true);
		expect(page.statusTitle.textContent).toBe("Allow USB debugging");
		expect(page.statusDetail.textContent).toBe("Tap Allow on your phone");
		expect(world.bloom!.mode).toBe("waiting");

		adb.tapAllow({ always: true });
		await until(() => text().includes("Found a Pixel 8 Pro"), "the detected phone");
		expect(text()).toContain("Found a Pixel 8 Pro (husky), running Android. Keep USB debugging on: at the Connect step, the page restarts it into Fastboot Mode for you.");
		expect(page.panel.querySelector('button[aria-pressed="true"]')?.textContent).toBe("Pixel 8 Prohusky");
		expect(buttonIn(page.panel, "Continue with Pixel 8 Pro")?.disabled).toBe(false);
		// Read, then let go: nothing restarted
		expect(adb.opened).toEqual([]);
		expect(adb.mode).toBe("android");
		expect(adb.usb.calls.slice(-2)).toEqual(["releaseInterface 1", "close"]);
		expect(page.panel.querySelector(".fastboot-howto")).not.toBeNull();
	});

	it("can be let go of with Cancel while the phone asks", async () => {
		const { adb } = await android();
		new App();
		await press("Detect a connected phone");
		await until(() => text().includes("Tap Allow on your phone."), "the help for the phone's question");
		await press("Cancel");
		await until(() => buttonIn(page.panel, "Detect a connected phone")?.disabled === false, "the step again");
		expect(page.panel.querySelector(".notice")).toBeNull();
		expect(page.panel.querySelector(".fastboot-howto")).not.toBeNull();
		expect(page.statusTitle.textContent).toBe("Install ExpressiveOS");
		expect(adb.usb.opened).toBe(false);
		expect(adb.opened).toEqual([]);
	});

	it("is restarted into Fastboot Mode on Connect only when the user says so, chosen again, then checked as a phone in Fastboot Mode is", async () => {
		publish([b]);
		const { adb, fastboot } = await android();
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => text().includes("Tap Allow on your phone."), "the help for the phone's question");
		expect(text()).toContain("If you tapped Cancel on the phone, press Cancel here, then press Connect so the phone asks again.");
		adb.tapAllow();
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		expect(text()).toContain("Found your Pixel 7 Pro");
		expect(text()).toContain("Restart into Fastboot Mode to go on. The phone restarts, and nothing on it is changed or erased.");
		expect(text()).toContain("Android, with USB debugging");
		expect(text()).toContain(fastboot.serial);
		expect(page.statusTitle.textContent).toBe("Phone found");
		expect(page.statusDetail.textContent).toBe("Pixel 7 Pro · running Android");
		// Nothing yet: the phone waits for the button
		await new Promise((r) => setTimeout(r, 50));
		expect(adb.opened).toEqual([]);
		expect(adb.mode).toBe("android");

		await press("Restart into Fastboot Mode");
		await until(() => !!buttonIn(page.panel, "Choose the phone again"), "the button to choose it again");
		expect(adb.opened).toEqual(["reboot:bootloader"]);
		expect(text()).toContain("In Fastboot Mode, the browser sees the phone as a new device, so you need to choose it again.");
		expect(page.statusTitle.textContent).toBe("Restarting into Fastboot Mode…");
		expect(world.bloom!.mode).toBe("waiting");
		await until(() => world.device !== null, "the phone in Fastboot Mode");
		await press("Choose the phone again");
		await until(() => text().includes("Ready to install"), "the phone's checks");
		expect(text()).toContain("Fastboot (bootloader)");
		expect(fastboot.commands).toContain("getvar:product");
		// On as after any Connect
		await press("Continue");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(fastboot.mode).toBe("android");
	});

	it("is found again in Fastboot Mode without the user when the browser may use it, and goes on to the unlock", async () => {
		publish([b]);
		world.askAfterMs = 60_000;
		const { adb } = await android({ trusted: true, permitted: true, fastboot: { unlocked: false } });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		// This browser's key is allowed already
		expect(adb.prompts).toHaveLength(0);
		await press("Restart into Fastboot Mode");
		await until(() => text().includes("The bootloader is locked"), "the unlock");
		expect(buttonIn(page.panel, "Unlock the bootloader")).not.toBeNull();
		expect(adb.opened).toEqual(["reboot:bootloader"]);
	});

	it("isn't restarted when it's another model than the build's", async () => {
		publish([b]);
		const { adb } = await android({ device: "husky", trusted: true });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => text().includes("That's a different phone"), "the refusal");
		expect(danger()?.textContent).toContain(
			"This is a Pixel 8 Pro (husky), and the build is for the Pixel 7 Pro, so the page left it as it is. Go back and choose the Pixel 8 Pro, or connect your Pixel 7 Pro. If your Pixel 7 Pro is plugged in too, unplug this phone, then press Connect and choose your Pixel 7 Pro in the list.",
		);
		expect(buttonIn(page.panel, "Restart into Fastboot Mode")).toBeNull();
		expect(adb.opened).toEqual([]);
		expect(adb.mode).toBe("android");
		expect(adb.usb.opened).toBe(false);
		expect(page.statusTitle.textContent).toBe("This phone can't take the build");
		expect(world.bloom!.mode).toBe("error");
		expect(step("Install").disabled).toBe(true);
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
	});

	it("isn't asked about a key it trusts on Connect, after the user allowed a Detect the page had stopped waiting for", async () => {
		publish([b]);
		const { adb } = await android({ back: false });
		new App();
		await press("Detect a connected phone");
		await until(() => !!adb.prompt, "the phone's question");
		await press("Cancel");
		await until(() => buttonIn(page.panel, "Detect a connected phone")?.disabled === false, "the step again");
		// The user taps Allow on the phone afterwards, with Always allow, and presses Detect again
		adb.tapAllow({ always: true });
		await press("Detect a connected phone");
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
		await press("Continue with Pixel 7 Pro");
		await until(() => text().includes("Install type"), "the build list");
		await toConnect();
		const prompts = adb.prompts.length;
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		expect(adb.prompts).toHaveLength(prompts);
		expect(adb.prompt).toBeNull();
		await press("Restart into Fastboot Mode");
		await until(() => !!buttonIn(page.panel, "Choose the phone again"), "the button to choose it again");
		expect(adb.opened).toEqual(["reboot:bootloader"]);
		await press("Cancel");
		await until(() => !!buttonIn(page.panel, "Connect"), "the step again");
	});

	it("is chosen in the browser's list on Connect, though the site may still use it from an earlier visit", async () => {
		// The Pixel 7 Pro the page restarted last time is still plugged in, running Android with USB
		// debugging on; the Pixel 8 Pro the build is for is in Fastboot Mode, new to the site
		const husky = build("husky", "1.0", "2026-10-30", "require board=husky\n", { stock: true, seed: 170 });
		publish([husky]);
		const { adb } = await android({ trusted: true });
		const pixel8 = new FakePhone({ product: "husky", serial: "35021FDH300ABC" });
		world.unpermitted.add(plugIn(pixel8));
		const list = vi.spyOn(world.usb as unknown as { requestDevice: (o?: USBDeviceRequestOptions) => Promise<USBDevice> }, "requestDevice");
		await start("Pixel 8 Pro", "husky");
		await toConnect();
		await press("Connect");
		await until(() => /Ready to install|different phone|locked/.test(text()), "the phone's checks");
		expect(list).toHaveBeenCalledTimes(1);
		expect(text()).toContain("Ready to install");
		expect(text()).toContain("35021FDH300ABC");
		expect(adb.usb.calls).toEqual([]);
		expect(adb.opened).toEqual([]);
	});

	it("found by Detect is taken on Connect without the browser's list", async () => {
		publish([b]);
		const { adb } = await android({ trusted: true });
		const list = vi.spyOn(world.usb as unknown as { requestDevice: (o?: USBDeviceRequestOptions) => Promise<USBDevice> }, "requestDevice");
		new App();
		await press("Detect a connected phone");
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
		await press("Continue with Pixel 7 Pro");
		await until(() => text().includes("Install type"), "the build list");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		expect(list).toHaveBeenCalledTimes(1);
		expect(adb.opened).toEqual([]);
	});

	it("tells the user to stop the adb server that holds the phone, then works once it's stopped", async () => {
		const { adb } = await android({ claimError: new DOMException("Unable to claim interface.", "NetworkError") });
		new App();
		await press("Detect a connected phone");
		await until(() => page.statusTitle.textContent === "Couldn't read the phone", "the failure");
		expect(danger()?.textContent).toContain(
			"usually an adb server started by adb, Android Studio or scrcpy. Close Android Studio and scrcpy if they're open, and any other tab using the phone. Then run adb kill-server in a terminal and try again.",
		);
		expect(danger()?.querySelector("a")).toBeNull();
		expect(world.bloom!.mode).toBe("error");
		// adb kill-server
		adb.opts.claimError = undefined;
		await press("Detect a connected phone");
		await until(() => !!adb.prompt, "the phone's question");
		adb.tapAllow();
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
	});

	it("links to the Google USB Driver when Windows won't let the browser have it", async () => {
		vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0", storage: {} });
		await android({ openError: new DOMException("Access denied.", "SecurityError") });
		new App();
		await press("Detect a connected phone");
		await until(() => !!danger(), "the failure");
		expect(danger()?.textContent).toContain("run adb kill-server in a terminal and try again. Otherwise install the Google USB Driver");
		expect(danger()?.querySelector("a")?.getAttribute("href")).toBe(USB_DRIVER_URL);
	});

	it("says how to allow USB debugging, or put the phone in Fastboot Mode by hand, when the user doesn't allow it", async () => {
		publish([b]);
		const { adb } = await android();
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!adb.prompt, "the phone's question");
		// Cancel on the phone: it says nothing, so the page waits out its time
		adb.tapCancel();
		await until(() => page.statusTitle.textContent === "Couldn't connect", "the failure");
		expect(danger()?.textContent).toContain(
			`The phone didn't allow USB debugging in time. Unlock the phone, tap Allow when it asks "Allow USB debugging?", then try again. ${byHand("Connect")}`,
		);
		expect(adb.usb.opened).toBe(false);
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
		expect(page.panel.querySelector(".fastboot-howto")).not.toBeNull();
	});

	it("says what to do when Cancel was tapped on the phone, which the phone doesn't tell the page", async () => {
		// The page's own time to allow it, 3 minutes: nothing comes before that
		adbTiming.allowTimeoutMs = undefined as unknown as number;
		const { adb } = await android();
		new App();
		await press("Detect a connected phone");
		await until(() => !!adb.prompt, "the phone's question");
		adb.tapCancel();
		await new Promise((r) => setTimeout(r, 300));
		expect(text()).toContain("If you tapped Cancel on the phone, press Cancel here, then press Detect a connected phone so the phone asks again.");
		expect(page.statusTitle.textContent).toBe("Allow USB debugging");
		// As it says: a new connection, and the phone asks again
		await press("Cancel");
		await until(() => buttonIn(page.panel, "Detect a connected phone")?.disabled === false, "the step again");
		await press("Detect a connected phone");
		await until(() => !!adb.prompt, "the phone's question again");
		expect(adb.prompts).toHaveLength(2);
		adb.tapAllow();
		await until(() => text().includes("Found a Pixel 7 Pro"), "the detected phone");
	});

	it("says the same when the phone doesn't answer at all", async () => {
		const { adb } = await android();
		adb.onMessage = () => true;
		new App();
		await press("Detect a connected phone");
		await until(() => !!danger(), "the failure");
		expect(danger()?.textContent).toContain(`The phone didn't answer over USB debugging. Unplug it, plug it back in and try again. ${byHand("Detect a connected phone")}`);
		expect(page.statusTitle.textContent).toBe("Couldn't read the phone");
	});

	it("passes on the phone's refusal to restart, with the steps by hand once", async () => {
		publish([b]);
		const { adb } = await android({ trusted: true, reboot: "refuse" });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		await press("Restart into Fastboot Mode");
		await until(() => !!danger(), "the failure");
		const said = danger()!.textContent;
		expect(said).toContain("The phone didn't restart into Fastboot Mode when asked over USB debugging. Turn the phone off. Then hold Power and Volume down together until you see Fastboot Mode.");
		expect(said.match(/Volume down/g)).toHaveLength(1);
		expect(adb.mode).toBe("android");
	});

	it("says what to do when it doesn't come back in Fastboot Mode", async () => {
		publish([b]);
		world.reconnectTimeoutMs = 200;
		await android({ trusted: true, back: false });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		await press("Restart into Fastboot Mode");
		await until(() => page.statusTitle.textContent === "Couldn't connect", "the failure");
		// The time also runs out on a phone in Fastboot Mode that wasn't chosen again
		expect(danger()?.textContent).toContain(
			"The page stopped waiting for the phone. If it shows Fastboot Mode, press Connect and choose it. If it shows something else, put it in Fastboot Mode by hand: turn it off, then hold Power and Volume down together until you see Fastboot Mode. Then press Connect.",
		);
		expect(buttonIn(page.panel, "Choose the phone again")).toBeNull();
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
	});

	it("stops waiting for it with Cancel, and says another phone chosen isn't it", async () => {
		publish([b]);
		const { fastboot } = await android({ trusted: true, back: false });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		await press("Restart into Fastboot Mode");
		await until(() => !!buttonIn(page.panel, "Choose the phone again"), "the button to choose it again");
		// Another phone in Fastboot Mode is chosen
		world.unpermitted.add(plugIn(new FakePhone({ serial: "OTHERPHONE01" })));
		const said = sayings();
		await press("Choose the phone again");
		await until(() => text().includes("That isn't the phone the page is waiting for"), "the wrong phone");
		expect(buttonIn(page.panel, "Choose the phone again")).not.toBeNull();
		// The keyboard stays on the button and the status is the same: screen readers are told, each time
		const wrong = "That isn't the phone the page is waiting for, or it isn't in Fastboot Mode yet. Choose it again.";
		expect(said.at(-1)).toBe(wrong);
		await press("Choose the phone again");
		await settle();
		expect(said.filter((t) => t === wrong)).toHaveLength(2);
		await press("Cancel");
		await until(() => !!buttonIn(page.panel, "Connect"), "the step again");
		expect(text()).toContain("The page stopped waiting for the phone. If it shows Fastboot Mode, press Connect and choose it.");
		expect(page.panel.querySelector(".notice-danger")).toBeNull();
		// It's in Fastboot Mode now: Connect takes it from there
		plugIn(fastboot);
		await press("Connect");
		await until(() => text().includes("Ready to install"), "the phone's checks");
	});

	it("is let go of when it's unplugged while waiting for Restart into Fastboot Mode", async () => {
		publish([b]);
		const { adb } = await android({ trusted: true, back: false });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		adb.usb.disconnect();
		await settle();
		expect(text()).toContain("The phone was unplugged. Plug it back in and connect again.");
		expect(buttonIn(page.panel, "Restart into Fastboot Mode")).toBeNull();
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
		expect(adb.opened).toEqual([]);
	});

	it("is let go of when the user leaves the step instead of restarting it", async () => {
		publish([b]);
		const { adb } = await android({ trusted: true });
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		await until(() => !!buttonIn(page.panel, "Restart into Fastboot Mode"), "the button to restart it");
		await press(step("Download").textContent, page.stepper);
		await settle();
		expect(adb.usb.opened).toBe(false);
		await press("Continue");
		expect(text()).toContain("Connect your phone");
		expect(buttonIn(page.panel, "Connect")).not.toBeNull();
		expect(adb.opened).toEqual([]);
	});
});

describe("the status under the flower", () => {
	it("says on Connect that the phone may be running Android with USB debugging, or in Fastboot Mode", async () => {
		publish([build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 95 })]);
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		expect(page.statusTitle.textContent).toBe("Connect your phone");
		expect(page.statusDetail.textContent).toBe("Running Android with USB debugging on, or in Fastboot Mode");
	});

	it("stays on a failed download", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 90 });
		publish([b], { stored: false });
		world.download = () => Promise.reject(new StoreError("network", "The download keeps failing: reset"));
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Download"), "the download step");
		await press("Download");
		await until(() => text().includes("The download keeps failing"), "the failure");
		expect(page.statusTitle.textContent).toBe("The download stopped");
		expect(world.bloom!.mode).toBe("error");
	});

	it("names the phone that's connected, not the one chosen, when they differ", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 95 });
		publish([b]);
		phone({ product: "husky" });
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		expect(text()).toContain("That's a different phone");
		expect(page.statusDetail.textContent).toContain("Pixel 8 Pro");
		expect(world.bloom!.mode).toBe("error");
	});
});

describe("a line of android-info.txt that can't be read (images-2)", () => {
	// fastboot's CheckRequirements says "android-info.txt syntax error" for these and goes on
	const odd = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\nrequire foo\nnot a requirement\n", { stock: true, seed: 100 });

	it("is a warning on Connect and Install, and the install goes ahead", async () => {
		publish([odd]);
		const fake = phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		expect(text()).toContain("Ready to install");
		expect(page.panel.querySelector(".notice-danger")).toBeNull();
		const warn = () => page.panel.querySelector(".notice-warn");
		expect(warn()?.textContent).toContain("require foo");
		expect(warn()?.textContent).toContain("not a requirement");
		expect(buttonIn(page.panel, "Continue")?.disabled).toBe(false);
		await press("Continue");
		expect(warn()?.textContent).toContain("require foo");
		expect(buttonIn(page.panel, "Install")).not.toBeNull();
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(fake.mode).toBe("android");
	});

	it("still lets a requirement the phone fails stop it", async () => {
		const both = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\nrequire foo\nrequire version-bootloader=cloudripper-17.0*\n", { stock: true, seed: 110 });
		publish([both]);
		const fake = phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		expect(text()).toContain("version-bootloader must be cloudripper-17.0*");
		expect(page.panel.querySelector(".notice-danger")?.textContent).not.toContain("require foo");
		expect(buttonIn(page.panel, "Continue")).toBeNull();
		expect(wrote(fake)).toEqual([]);
	});
});

describe("a connection that broke part way (protocol-2)", () => {
	const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 120 });

	it("says to restart the phone into Fastboot Mode first when the install lost it", async () => {
		publish([b]);
		const fake = phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		usbGoesAfter(fake, "set_active:a");
		await install();
		expect(text()).toContain("Stopped at");
		expect(text()).toContain("Restart the phone into Fastboot Mode first: hold Power and Volume down until it restarts.");
		expect(text()).not.toContain("if it isn't");
	});

	it("keeps the gentler advice when the phone only refused a command", async () => {
		publish([b]);
		phone({ failOnce: "set_active:a" });
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		await install();
		expect(text()).toContain("Stopped at");
		expect(text()).toContain("put the phone in Fastboot Mode if it isn't");
		expect(text()).not.toContain("Restart the phone into Fastboot Mode first");
	});

	it("closes the connection before Connect can be pressed again, when reading the phone fails", async () => {
		publish([b]);
		const fake = phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		const device = world.device!;
		let closed!: () => void;
		device.closeGate = new Promise<void>((r) => (closed = r));
		usbGoesAfter(fake, "getvar:unlocked");
		await press("Connect");
		// Still closing: nothing else may open the phone, or the close would take the new connection
		expect(device.closes).toBe(0);
		expect(buttonIn(page.panel, "Connect")).toBeNull();
		expect(page.statusTitle.textContent).not.toBe("Couldn't connect");
		closed();
		await settle();
		expect(device.closes).toBe(1);
		expect(page.statusTitle.textContent).toBe("Couldn't connect");
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
	});

	it("closes the connection before going on, when the phone can't be read after unlocking", async () => {
		publish([b]);
		const fake = phone({ unlocked: false });
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		expect(text()).toContain("The bootloader is locked");
		const device = world.device!;
		let closed!: () => void;
		device.closeGate = new Promise<void>((r) => (closed = r));
		usbGoesAfter(fake, "flashing unlock");
		tick();
		await press("Unlock the bootloader");
		expect(device.closes).toBe(0);
		expect(text()).not.toContain("Connect the phone again to go on");
		closed();
		await settle();
		expect(device.closes).toBe(1);
		expect(text()).toContain("The bootloader is unlocked. Connect the phone again to go on.");
		expect(buttonIn(page.panel, "Connect")?.disabled).toBe(false);
	});

	for (const answer of ["yes", "no", ""]) {
		it(`doesn't call a phone that answers ${JSON.stringify(answer)} for its model a different phone`, async () => {
			publish([b]);
			const fake = phone({ product: answer });
			const app = await start("Pixel 7 Pro", "cheetah");
			await toConnect();
			await press("Connect");
			await until(() => text().includes("unexpected answer"), "the phone's checks");
			expect(text()).not.toContain("different phone");
			expect(text()).not.toContain(`says it's`);
			expect(text()).toContain("Restart it into Fastboot Mode by holding Power and Volume down until it restarts, then connect again.");
			expect(page.statusTitle.textContent).toBe("The phone gave an unexpected answer");
			expect(page.statusDetail.textContent).not.toContain(`${answer} ·`);
			expect(step("Install").disabled).toBe(true);
			// Install, however it's reached, says the same
			await privateInstall(app);
			await settle();
			expect(text()).toContain("The install didn't start");
			expect(text()).toContain("unexpected answer");
			expect(wrote(fake)).toEqual([]);
		});
	}

	it("says the same when Detect a connected phone gets an answer that isn't a model", async () => {
		phone({ product: "yes" });
		new App();
		await press("Detect a connected phone");
		await until(() => text().includes("unexpected answer"), "the detected phone");
		expect(text()).not.toContain(`says it's "yes"`);
		expect(text()).toContain("Restart it into Fastboot Mode by holding Power and Volume down until it restarts");
	});
});

describe("a computer that won't let the browser open the phone (ux-2, runtime-4)", () => {
	it("links to the Google USB Driver on Windows, instead of putting its address in the message", async () => {
		vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0", storage: {} });
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 130 });
		publish([b]);
		const device = plugIn(new FakePhone());
		device.openError = openFailure("open", new DOMException("Access denied.", "SecurityError"), "windows");
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		const box = page.panel.querySelector(".notice-danger")!;
		expect(box.textContent).toContain("Install the Google USB Driver");
		expect(box.textContent).not.toContain("https://");
		const a = box.querySelector("a");
		expect(a?.getAttribute("href")).toBe(USB_DRIVER_URL);
		expect(a?.textContent).toMatch(/Google USB Driver/);
		expect(page.statusTitle.textContent).toBe("Couldn't connect");
	});

	it("has no driver link for a phone something else holds", async () => {
		const b = build("cheetah", "1.0", "2026-10-30", "require board=cheetah\n", { stock: true, seed: 140 });
		publish([b]);
		const device = plugIn(new FakePhone());
		// On Windows, where an access error does get the link: only the kind of error leaves it out
		vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0", storage: {} });
		device.openError = openFailure("claim", new DOMException("Unable to claim interface.", "NetworkError"), "windows");
		await start("Pixel 7 Pro", "cheetah");
		await toConnect();
		await press("Connect");
		const box = page.panel.querySelector(".notice-danger")!;
		expect(box.textContent).toContain("in use by another program");
		expect(box.querySelector("a")).toBeNull();
	});
});
