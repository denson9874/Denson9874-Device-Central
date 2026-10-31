// The page's steps, driven through their buttons on a small DOM in Node (app-harness.ts), with the
// simulated Pixel behind WebUSB: what the stepper lets through, what Install checks itself, and
// what each step does with a zip, a phone or a failure that changed under it.

import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { USB_DRIVER_URL, openFailure } from "../src/fastboot/webusb.ts";
import type { Release } from "../src/releases.ts";
import { StoreError, storeName } from "../src/store/store.ts";
import { App } from "../src/ui/app.ts";
import { type FakeElement, type Page, buttonIn, buttonsIn, fakeDom, fakeNavigatorUsb, plugIn, unplug, world } from "./app-harness.ts";
import { FakePhone, type FakeOptions } from "./fake-phone.ts";
import { bytes, makeSuperEmpty, makeZip } from "./helpers.ts";

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
	return { ...(await importOriginal<object>()), UsbTransport: h.FakeUsbTransport, isFastbootDevice: () => true };
});
vi.mock("../src/store/store.ts", async (importOriginal) => ({ ...(await importOriginal<object>()), ...(await import("./app-harness.ts")).store }));

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
	world.stored = new Map();
	world.files = new Map();
	world.releases = [];
	world.download = () => Promise.reject(new Error("no download"));
	world.hash = () => Promise.reject(new Error("no hash"));
});

afterEach(() => {
	vi.unstubAllGlobals();
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

describe("the status under the flower", () => {
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
