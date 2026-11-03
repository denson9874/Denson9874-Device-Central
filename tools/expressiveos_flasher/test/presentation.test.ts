// What the page tells people beyond its pixels, driven like app.test.ts on app-harness.ts's small
// DOM: what screen readers are told and when (the live region, the progress bars, the install
// rows), where the keyboard goes when a step is drawn again, the root instructions on the Done
// step, and the stylesheet's text contrast in both themes.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Release } from "../src/releases.ts";
import { type Progress, StoreError, storeName } from "../src/store/store.ts";
import { App } from "../src/ui/app.ts";
import { FakeElement, type Page, buttonIn, buttonsIn, fakeDom, fakeNavigatorUsb, plugIn, unplug, world } from "./app-harness.ts";
import { FakePhone, type FakeOptions } from "./fake-phone.ts";
import { bytes, makeSuperEmpty, makeZip } from "./helpers.ts";

/** A download the test drives itself, progress and all (null: the harness's own). */
const hooks = vi.hoisted(() => ({
	download: null as null | ((onProgress: (p: Progress) => void, signal?: AbortSignal) => Promise<File>),
}));

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
vi.mock("../src/store/store.ts", async (importOriginal) => {
	const h = await import("./app-harness.ts");
	return {
		...(await importOriginal<object>()),
		...h.store,
		downloadRelease: async (url: string, name: string, size: number, sha: string, onProgress: (p: Progress) => void, signal?: AbortSignal) => {
			if (!hooks.download) return h.store.downloadRelease(url, name, size, sha, onProgress, signal);
			const file = await hooks.download(onProgress, signal);
			h.world.stored.set(name, file);
			return { file, release: async () => {} };
		},
	};
});

// ---------- A build ----------

const enc = new TextEncoder();
const INFO = "version 1\nflash boot\nflash init_boot\nflash vendor_boot\nflash --apply-vbmeta vbmeta\nreboot fastboot\nupdate-super\nflash system\nif-wipe erase userdata\nif-wipe erase metadata\n";
const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

function build(device: string, opts: { stock: boolean; seed: number }) {
	const zip = makeZip([
		{ name: "android-info.txt", data: enc.encode(`require board=${device}\n`) },
		{ name: "fastboot-info.txt", data: enc.encode(INFO) },
		{ name: "boot.img", data: bytes(8192, opts.seed) },
		{ name: "init_boot.img", data: bytes(8192, opts.seed + 1) },
		{ name: "vendor_boot.img", data: bytes(8192, opts.seed + 2) },
		{ name: "vbmeta.img", data: bytes(4096, opts.seed + 3) },
		{ name: "super_empty.img", data: makeSuperEmpty(["system_a", "system_b"]) },
		{ name: "system.img", data: bytes(16384, opts.seed + 4) },
	]);
	const stock = opts.stock ? bytes(6000, opts.seed + 9) : null;
	const name = `ExpressiveOS-16.0-20261030-${device}-1.0-Unofficial`;
	const release: Release = {
		name,
		channel: "release",
		android: "16.0",
		version: "1.0",
		type: "Unofficial",
		date: "2026-10-30",
		published: "2026-10-30T12:00:00Z",
		zip: { file: `${name}-fastboot.zip`, size: zip.byteLength, sha256: sha(zip) },
		initBootStock: stock ? { file: `${name}-init_boot-stock.img`, size: stock.byteLength, sha256: sha(stock) } : null,
		root: stock ? "kernelsu-next" : null,
		requirements: [],
	};
	return { release, zip, stock };
}

type Build = ReturnType<typeof build>;
const zipFile = (b: Build) => new File([b.zip.slice()], b.release.zip.file);

function publish(b: Build, opts: { stored?: boolean } = {}) {
	world.releases = [b.release];
	if (opts.stored !== false) world.stored.set(storeName(b.release.zip.sha256, "zip"), zipFile(b));
	if (b.stock) world.files.set(b.release.initBootStock!.file, b.stock);
}

// ---------- The page, with a keyboard ----------

let page: Page;
/** The element the keyboard is on; the harness's DOM has no focus of its own. */
let focused: FakeElement | null = null;
const harnessFocus = FakeElement.prototype.focus;

function attached(e: FakeElement): boolean {
	for (let n: FakeElement | null = e; n; n = n.parentNode) if (n === page.body) return true;
	return false;
}

/** document.activeElement as a browser has it: the body once the focused element is gone. */
const active = (): FakeElement => (focused && attached(focused) ? focused : page.body);

beforeEach(() => {
	const dom = fakeDom();
	Object.defineProperty(dom.globals.document as object, "activeElement", { configurable: true, get: active });
	// Like a browser's: a disabled or hidden element doesn't take the keyboard
	FakeElement.prototype.focus = function (this: FakeElement) {
		if (this.disabled) return;
		for (let n: FakeElement | null = this; n; n = n.parentNode) if (n.hidden) return;
		focused = this;
	};
	for (const [k, v] of Object.entries(dom.globals)) vi.stubGlobal(k, v);
	vi.stubGlobal("navigator", { usb: fakeNavigatorUsb(), userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/141.0", storage: {} });
	vi.stubGlobal("fetch", async (url: string) => {
		const m = /^\/api\/releases\/(\w+)$/.exec(url);
		if (!m) return new Response(null, { status: 404 });
		return Response.json({ schema: 1, device: m[1], updated: "2026-10-30T12:00:00Z", releases: world.releases });
	});
	page = dom.page;
	focused = null;
	hooks.download = null;
	world.device = null;
	world.stored = new Map();
	world.files = new Map();
	world.releases = [];
});

afterEach(() => {
	FakeElement.prototype.focus = harnessFocus;
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

/** Presses a button from the keyboard: it has the focus, then it's clicked. */
async function press(label: string | RegExp, root: FakeElement = page.panel) {
	const b = buttonIn(root, label);
	if (!b) throw new Error(`No button ${label}; there are ${JSON.stringify(buttonsIn(root))}. The panel says: ${text()}`);
	expect(b.disabled, `${label} is disabled`).toBe(false);
	b.focus();
	b.click();
	await settle();
}

function choose(group: string, value: string) {
	const input = page.panel.querySelector(`input[name="${group}"][value="${value}"]`)!;
	input.focus();
	input.checked = true;
	input.dispatchEvent(new Event("change"));
}

function phone(o: FakeOptions = {}) {
	const fake = new FakePhone(o);
	plugIn(fake);
	return fake;
}

/** Everything written to the live region, in order. */
function liveRegion(): string[] {
	const live = page.body.querySelector("#announce");
	expect(live, "the page's live region").not.toBeNull();
	expect(live!.getAttribute("aria-live")).toBe("polite");
	const said: string[] = [];
	const own = Object.getOwnPropertyDescriptor(FakeElement.prototype, "textContent")!;
	Object.defineProperty(live, "textContent", {
		configurable: true,
		get: () => own.get!.call(live),
		set: (v: string) => {
			said.push(v);
			own.set!.call(live, v);
		},
	});
	return said;
}

/** Opens the page and goes to the Build step for a phone, as a keyboard would. */
async function start(model: string, codename: string): Promise<App> {
	const app = new App();
	await press(`${model}${codename}`);
	await press(`Continue with ${model}`);
	await until(() => text().includes("Install type"), "the build list");
	return app;
}

async function toConnected() {
	await press("Continue");
	await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
	await press("Continue");
	await press("Connect");
	await until(() => /Ready to install|different phone|doesn't accept|locked/.test(text()), "the phone's checks");
}

async function install() {
	const box = page.panel.querySelector('input[type="checkbox"]');
	if (box) {
		box.checked = true;
		box.dispatchEvent(new Event("change"));
	}
	await press("Install");
	await until(() => /ExpressiveOS is installed|didn't start|Stopped at/.test(text()), "the end of the install");
}

// ---------- The tests ----------

describe("what screen readers are told (ux-4)", () => {
	it("hears the download every 10%, while the status and the bar follow every bit of it", async () => {
		const b = build("cheetah", { stock: true, seed: 10 });
		publish(b, { stored: false });
		let tick!: (p: Progress) => void;
		let finish!: () => void;
		hooks.download = (onProgress) =>
			new Promise<File>((resolve) => {
				tick = onProgress;
				finish = () => resolve(zipFile(b));
			});
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Download"), "the download step");
		const said = liveRegion();
		await press("Download");
		const titles = new Set<string>();
		const total = 6_000_000_000;
		for (let i = 1; i <= 1000; i++) {
			tick({ phase: "downloading", done: (total * i) / 1000, total });
			titles.add(page.statusTitle.textContent);
			if (i === 500) {
				const bar = page.panel.querySelector('[role="progressbar"]')!;
				expect(bar.getAttribute("aria-label")).toBe("Download");
				expect(bar.getAttribute("aria-valuenow")).toBe("50");
				expect(bar.getAttribute("aria-valuetext")).toMatch(/^50%, .* of /);
			}
			// Let what's queued for the live region be said, as the worker's 100 ms would
			await Promise.resolve();
		}
		// The status under the flower moves with every tick; the live region says the start, then
		// every 10%
		expect(titles.size).toBe(1000);
		expect(said.filter((s) => s.includes("Downloading"))).toEqual(["Downloading 0.1%", ...[10, 20, 30, 40, 50, 60, 70, 80, 90].map((p) => `Downloading ${p}%`)]);
		expect(said.length).toBeLessThanOrEqual(11);
		finish();
		await until(() => text().includes("Downloaded and checked"), "the finished download");
		expect(said.at(-1)).toContain("Downloaded and checked");
	});

	it("names each install step and its state in words, and the bar is a progressbar", async () => {
		const b = build("cheetah", { stock: true, seed: 20 });
		publish(b);
		// Late in the install, so most rows are done by then
		phone({ failOnce: "flash:system_a" });
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		const said = liveRegion();
		await install();
		expect(text()).toContain("Stopped at: Write system");
		const bar = page.panel.querySelector('[role="progressbar"]')!;
		expect(bar.getAttribute("aria-label")).toBe("Install");
		expect(bar.getAttribute("aria-valuemin")).toBe("0");
		expect(bar.getAttribute("aria-valuemax")).toBe("100");
		const rows = page.panel.querySelectorAll(".steps li");
		const state = (li: FakeElement) => li.querySelector(".sr-only")?.textContent ?? null;
		const done = rows.filter((li) => li.className === "is-done");
		expect(done.length).toBeGreaterThanOrEqual(5);
		for (const li of done) expect(state(li)).toBe(" (done)");
		const failed = rows.filter((li) => li.className === "is-failed");
		expect(failed.length).toBe(1);
		expect(state(failed[0])).toBe(" (failed)");
		expect(rows.some((li) => li.getAttribute("aria-current") === "step")).toBe(false);
		// Percentages said on their own are milestones
		for (const s of said.filter((x) => /^Installing \d+%$/.test(x))) expect(Number(/\d+/.exec(s)![0]) % 10).toBe(0);
		expect(said.length).toBeLessThan(rows.length + 12);
	});

	it("says where the download step ends up, not where it starts, once the zip is in hand", async () => {
		const b = build("cheetah", { stock: true, seed: 25 });
		publish(b, { stored: false });
		let finish!: () => void;
		hooks.download = () => new Promise<File>((resolve) => (finish = () => resolve(zipFile(b))));
		phone();
		await start("Pixel 7 Pro", "cheetah");
		let said = liveRegion();
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Download"), "the download step");
		// Nothing downloaded yet: that's where it ends up, and it's said once
		expect(said.filter((s) => s.includes("Ready to download")).length).toBe(1);
		await press("Download");
		said.length = 0;
		finish();
		await until(() => text().includes("Downloaded and checked"), "the finished download");
		const once = (what: string) => {
			expect(said.filter((s) => s.includes("Ready to download")), what).toEqual([]);
			expect(said.filter((s) => s.includes("Downloaded and checked")).length, what).toBe(1);
		};
		once("after the download");
		// Back from Connect
		await press("Continue");
		await press("Connect");
		await until(() => text().includes("Ready to install"), "the phone's checks");
		said.length = 0;
		await press("Back");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		once("on Back from Connect");
		// And once another phone is to be installed
		await press("Continue");
		expect(text()).toContain("Ready to install");
		await press("Continue");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		phone({ serial: "SECONDPHONE01" });
		await press("Install on another phone");
		said = liveRegion();
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		once("after Install on another phone");
	});

	it("never says two different percentages of the install at once", async () => {
		const b = build("cheetah", { stock: true, seed: 27 });
		publish(b);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		await toConnected();
		await press("Continue");
		const said = liveRegion();
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		const percents = said.map((s) => [...new Set([...s.matchAll(/Installing (\d+)%/g)].map((m) => m[1]))]);
		expect(percents.filter((p) => p.length > 1)).toEqual([]);
		// It's still heard along the way
		expect(percents.filter((p) => p.length === 1).length).toBeGreaterThanOrEqual(5);
	});

	it("isn't the status under the flower, and says a step's outcome that isn't an alert", async () => {
		const b = build("cheetah", { stock: true, seed: 30 });
		publish(b);
		phone({ unlocked: false, unlockAnswer: "no" });
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		await press("Continue");
		const said = liveRegion();
		await press("Connect");
		await until(() => text().includes("The bootloader is locked"), "the locked phone");
		expect(said.at(-1)).toMatch(/^Phone connected\. Pixel 7 Pro · 28161FDH2000AB Its bootloader is locked\. Unlocking it erases everything on the phone\.$/);
		// The phone says no: the message over the step is said, once
		const box = page.panel.querySelector('input[type="checkbox"]')!;
		box.checked = true;
		box.dispatchEvent(new Event("change"));
		await press("Unlock the bootloader");
		await until(() => text().includes("didn't unlock"), "the refusal");
		expect(said.at(-1)).toContain("The phone didn't unlock (it was cancelled or refused). You can try again.");
		expect(said.filter((s) => s.includes("didn't unlock")).length).toBe(1);
	});
});

describe("the keyboard when the panel is drawn again (ux-6)", () => {
	it("stays on the phone just chosen, and goes to the heading of a new step", async () => {
		new App();
		await press("Pixel 8 Prohusky");
		const tile = active();
		expect(tile.textContent).toBe("Pixel 8 Prohusky");
		expect(tile.getAttribute("aria-pressed")).toBe("true");
		await press("Continue with Pixel 8 Pro");
		expect(active().tagName).toBe("h2");
		expect(active().textContent).toBe("Choose a build");
		expect(active().getAttribute("tabindex")).toBe("-1");
	});

	it("stays on a choice, and isn't taken by something finishing in the background", async () => {
		const b = build("cheetah", { stock: true, seed: 40 });
		publish(b);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		choose("wipe", "keep");
		expect(active().getAttribute("value")).toBe("keep");
		expect(active().checked).toBe(true);
		await toConnected();
		// On the theme button when the phone is unplugged: the panel changes, the keyboard stays
		const toggle = page.body.querySelector("#theme-toggle")!;
		toggle.focus();
		const said = liveRegion();
		unplug();
		await settle();
		expect(text()).toContain("The phone was unplugged");
		expect(active()).toBe(toggle);
		expect(said.at(-1)).toContain("The phone was unplugged. Plug it back in and connect again.");
	});

	it("goes from Download to Pause, and from Pause to Resume download", async () => {
		const b = build("cheetah", { stock: true, seed: 50 });
		publish(b, { stored: false });
		hooks.download = (_p, signal) => new Promise<File>((_resolve, reject) => signal?.addEventListener("abort", () => reject(new StoreError("cancelled", "Cancelled"))));
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Download"), "the download step");
		await press("Download");
		expect(active().textContent).toBe("Pause");
		await press("Pause");
		await until(() => !!buttonIn(page.panel, "Download"), "the paused step");
		expect(active().textContent).toBe("Download");
		expect(active()).toBe(buttonIn(page.panel, "Download"));
	});

	it("isn't left on the page when Connect's button goes away", async () => {
		const b = build("cheetah", { stock: true, seed: 60 });
		publish(b);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		const said = liveRegion();
		await toConnected();
		expect(text()).toContain("Ready to install");
		expect(active()).not.toBe(page.body);
		expect(active().textContent).toBe("Connect your phone");
		expect(said.at(-1)).toContain("It passed the checks and is ready for the install.");
	});
});

describe("a list closed with no phone chosen", () => {
	const said = "No phone was chosen. The browser's list only shows a phone that's running Android with USB debugging on, or one that's in Fastboot Mode.";

	it("is said on the Phone step, and the keyboard stays on Detect a connected phone", async () => {
		new App();
		const live = liveRegion();
		await press("Detect a connected phone");
		expect(page.panel.querySelector(".notice-info")).not.toBeNull();
		expect(live.at(-1)).toBe(said);
		expect(active().textContent).toBe("Detect a connected phone");
		// Drawn again for another choice, it isn't said again
		await press("Pixel 7 Procheetah");
		expect(live.filter((s) => s.includes("No phone was chosen")).length).toBe(1);
	});

	it("is said on the Connect step, and the keyboard stays on Connect", async () => {
		const b = build("cheetah", { stock: true, seed: 110 });
		publish(b);
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		await press("Continue");
		const live = liveRegion();
		await press("Connect");
		expect(page.panel.querySelector(".notice-info")).not.toBeNull();
		expect(live.at(-1)).toBe(said);
		expect(active()).toBe(buttonIn(page.panel, "Connect"));
	});
});

describe("a way back on every step (ux-9)", () => {
	it("has Back with the download stored and with the phone ready, and keeps the stepper's names", async () => {
		const b = build("cheetah", { stock: true, seed: 70 });
		publish(b);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		expect(buttonsIn(page.panel)).toContain("Back");
		await press("Continue");
		await press("Connect");
		await until(() => text().includes("Ready to install"), "the phone's checks");
		await press("Back");
		expect(text()).toContain("Download the build");
		// A narrow stepper shows the number alone; the name stays in the button's text
		const first = page.stepper.querySelector("button")!;
		expect(first.textContent).toBe("1. Phone");
		expect(first.querySelector(".step-num")?.textContent).toBe("1.");
		expect(first.querySelector(".step-name")?.textContent).toBe("Phone");
	});
});

describe("the root instructions (ux-10)", () => {
	it("say to restart once after a clean install, not to open the app", async () => {
		const b = build("cheetah", { stock: true, seed: 80 });
		publish(b);
		phone();
		await start("Pixel 7 Pro", "cheetah");
		expect(text()).not.toContain("open it once");
		expect(text()).toContain("A clean install sets them up during the first start, and they work after one restart.");
		await toConnected();
		await press("Continue");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(text()).toContain("Restart the phone once after setup, before signing in to banking or payment apps, so susfs (root hiding) and Zygisk are on.");
		expect(text()).not.toContain("to finish setting it up");
	});

	it("don't promise susfs and Zygisk after one restart when the data is kept", async () => {
		const b = build("husky", { stock: true, seed: 90 });
		publish(b);
		phone({ product: "husky" });
		await start("Pixel 8 Pro", "husky");
		choose("wipe", "keep");
		await toConnected();
		await press("Continue");
		await install();
		expect(text()).toContain("ExpressiveOS is installed");
		expect(text()).toContain("If this phone already had root with ExpressiveOS, it carries on as before.");
		expect(text()).toContain("turn them on in the KernelSU Next app, then restart the phone.");
		expect(text()).not.toContain("Restart the phone once after setup");
	});
});

describe("help for a phone that won't connect (ux-2, runtime-4)", () => {
	const linuxRule = "add a udev rule for Google's USB vendor id 18d1 (for example, install the android-udev-rules package), then unplug the phone and plug it back in.";

	it("has a line for Linux before you start", () => {
		new App();
		const prep = page.panel.querySelector("details")!;
		expect(prep.textContent).toContain("Before you start");
		const linux = prep.querySelectorAll("li").find((li) => li.textContent.startsWith("On Linux,"));
		expect(linux?.textContent).toBe(`On Linux, ${linuxRule}`);
		const windows = prep.querySelectorAll("li").find((li) => li.textContent.startsWith("On Windows,"));
		expect(windows?.querySelector("a")?.textContent).toBe("Google USB Driver");
	});

	it("covers a phone that isn't in the list and one that is but won't connect, on Windows and Linux", async () => {
		const b = build("cheetah", { stock: true, seed: 100 });
		publish(b);
		await start("Pixel 7 Pro", "cheetah");
		await press("Continue");
		await until(() => !!buttonIn(page.panel, "Continue"), "the stored download");
		await press("Continue");
		const help = page.panel.querySelectorAll("p.status-detail").map((p) => p.textContent);
		const missing = help.find((t) => t.startsWith("Phone not in the list?"));
		const stuck = help.find((t) => t.startsWith("In the list but won't connect?"));
		expect(missing).toContain("Check that USB debugging is on, or that the phone shows Fastboot Mode, and try another cable or port.");
		expect(missing).toContain("On Windows, install the Google USB Driver.");
		expect(missing).toContain(`On Linux, ${linuxRule}`);
		expect(stuck).toContain("Close any other program using the phone, such as Android Studio, scrcpy or a terminal running fastboot, and any other tab using it. If adb is installed, run adb kill-server too.");
		expect(stuck).toContain("Without the Google USB Driver on Windows, or the udev rule on Linux, the browser can list the phone but can't open it.");
		expect(stuck).toContain("After that, unplug the phone, plug it back in and connect again.");
		expect(page.panel.querySelectorAll("p.status-detail a").map((a) => a.getAttribute("href"))).toContain("https://developer.android.com/studio/run/win-usb");
	});
});

// ---------- The stylesheet's contrast (ux-5) ----------

type RGBA = [number, number, number, number];

const css = readFileSync(new URL("../src/ui/styles.css", import.meta.url), "utf8");

/** The custom properties of the block that starts with this selector. */
function tokens(start: string): Record<string, string> {
	const at = css.indexOf(start);
	expect(at, start).toBeGreaterThanOrEqual(0);
	const body = css.slice(at + start.length, css.indexOf("}", at));
	return Object.fromEntries([...body.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
}

/** A rule's declaration, such as .badge's color. */
function declaration(selector: string, property: string): string {
	const at = css.indexOf(`\n${selector} {`);
	expect(at, selector).toBeGreaterThanOrEqual(0);
	const body = css.slice(at, css.indexOf("}", at));
	const m = new RegExp(`\\n\\s*${property}:\\s*([^;]+);`).exec(body);
	expect(m, `${selector} ${property}`).not.toBeNull();
	return m![1].trim();
}

/** Splits at the commas that aren't inside parentheses. */
function args(s: string): string[] {
	const out: string[] = [];
	let depth = 0;
	let from = 0;
	for (let i = 0; i < s.length; i++) {
		if (s[i] === "(") depth++;
		else if (s[i] === ")") depth--;
		else if (s[i] === "," && depth === 0) {
			out.push(s.slice(from, i).trim());
			from = i + 1;
		}
	}
	out.push(s.slice(from).trim());
	return out;
}

/** Splits "color 40%" into the colour and the fraction (null when there's none). */
function withPercent(s: string): [string, number | null] {
	const m = /^(.*\S)\s+([\d.]+)%$/.exec(s);
	return m ? [m[1], Number(m[2]) / 100] : [s, null];
}

/** A CSS colour the stylesheet uses, worked out as the browser does (sRGB, 0 to 1). */
function color(expr: string, t: Record<string, string>): RGBA {
	expr = expr.trim();
	const v = /^var\(--([\w-]+)\)$/.exec(expr);
	if (v) {
		expect(t[v[1]], `--${v[1]}`).toBeDefined();
		return color(t[v[1]], t);
	}
	if (expr === "transparent") return [0, 0, 0, 0];
	const hex = /^#([\da-f]{3}|[\da-f]{6})$/i.exec(expr);
	if (hex) {
		const x = hex[1].length === 3 ? [...hex[1]].map((c) => c + c).join("") : hex[1];
		return [0, 2, 4].map((i) => parseInt(x.slice(i, i + 2), 16) / 255).concat(1) as RGBA;
	}
	const mix = /^color-mix\(in srgb,(.*)\)$/.exec(expr);
	if (mix) {
		const [[a, pa], [b, pb]] = args(mix[1]).map(withPercent);
		const p = pa ?? (pb === null ? 0.5 : 1 - pb);
		const [x, y] = [color(a, t), color(b, t)];
		// Premultiplied, as CSS mixes colours with alpha
		const alpha = x[3] * p + y[3] * (1 - p);
		const ch = (i: number) => (alpha ? (x[i] * x[3] * p + y[i] * y[3] * (1 - p)) / alpha : 0);
		return [ch(0), ch(1), ch(2), alpha];
	}
	throw new Error(`Can't work out the colour ${expr}`);
}

const over = (fg: RGBA, bg: RGBA): RGBA => [0, 1, 2].map((i) => fg[i] * fg[3] + bg[i] * (1 - fg[3])).concat(1) as RGBA;

function contrast(a: RGBA, b: RGBA): number {
	const lum = (c: RGBA) => {
		const [r, g, bl] = c.slice(0, 3).map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
		return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
	};
	const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
	return (hi + 0.05) / (lo + 0.05);
}

describe("the stylesheet's contrast (ux-5)", () => {
	const dark = tokens(":root {");
	const lightByScheme = tokens(':root:not([data-theme="dark"]) {');
	const lightByToggle = tokens(':root[data-theme="light"] {');
	const themes = { dark, light: { ...dark, ...lightByScheme } };

	it("has the same light theme from the system setting and from the toggle", () => {
		expect(lightByToggle).toEqual(lightByScheme);
	});

	it("keeps the bold keys in a step's text in their line, in a notice and in a list of steps", () => {
		// Only a notice's title is a line of its own
		expect(declaration(".notice-body > strong", "display")).toBe("block");
		expect(css).not.toMatch(/\n\.notice-body strong \{/);
		// A step isn't a grid or flex box, which would make each bold word a cell of its own
		const at = css.indexOf("\n.howto li {");
		expect(at).toBeGreaterThanOrEqual(0);
		expect(css.slice(at, css.indexOf("}", at))).not.toMatch(/display:\s*(grid|flex)/);
	});

	for (const [name, t] of Object.entries(themes)) {
		const c = (expr: string) => color(expr, t);
		const bg = c("var(--bg)");
		const panel = over(c("color-mix(in srgb, var(--bg-raised) 88%, transparent)"), bg);
		const cards = {
			card: c("var(--surface)"),
			"hovered card": c("var(--surface-hover)"),
			"chosen card": c("color-mix(in srgb, var(--accent) 12%, var(--surface))"),
		};
		// body::before's corner light, at its strongest
		const page = {
			page: bg,
			"violet corner": over(c("color-mix(in srgb, var(--violet) 22%, transparent)"), bg),
			"blue corner": over(c("color-mix(in srgb, var(--blue) 18%, transparent)"), bg),
			"green corner": over(c("color-mix(in srgb, var(--green) 12%, transparent)"), bg),
			"coral corner": over(c("color-mix(in srgb, var(--coral) 14%, transparent)"), bg),
		};

		it(`${name}: the faint text (footer, pending steps, step notes) is 4.5:1`, () => {
			const faint = c("var(--faint)");
			for (const [where, b] of Object.entries({ ...page, panel, "running step": cards.card })) expect(contrast(faint, b), where).toBeGreaterThanOrEqual(4.5);
		});

		it(`${name}: the badges are 4.5:1 on every card`, () => {
			for (const sel of [".badge", ".badge-testers", ".badge-root"]) {
				const fg = c(declaration(sel, "color"));
				const fill = c(declaration(sel, "background"));
				for (const [where, card] of Object.entries(cards)) expect(contrast(fg, over(fill, card)), `${sel} on a ${where}`).toBeGreaterThanOrEqual(4.5);
			}
		});

		it(`${name}: the keyboard's ring is 3:1 against what's next to it`, () => {
			const ring = /^3px solid (.+)$/.exec(declaration(".theme-toggle:focus-visible", "outline"));
			expect(ring).not.toBeNull();
			const fg = c(ring![1]);
			expect(fg[3]).toBe(1);
			for (const [where, b] of Object.entries({ ...page, panel, ...cards })) expect(contrast(fg, b), where).toBeGreaterThanOrEqual(3);
		});

		it(`${name}: the primary button's white label is 4.5:1 all along its gradient`, () => {
			const g = /^linear-gradient\((.*)\)$/.exec(declaration(".btn-primary", "background"));
			expect(g).not.toBeNull();
			const stops = args(g![1])
				.slice(1)
				.map(withPercent)
				.map(([col, at], i, all) => [c(col), at ?? i / (all.length - 1)] as const);
			const white = c("#fff");
			for (let i = 0; i <= 100; i++) {
				const p = i / 100;
				const k = Math.max(1, stops.findIndex(([, at]) => at >= p));
				const [[a, pa], [b, pb]] = [stops[k - 1], stops[k]];
				const f = pb > pa ? (p - pa) / (pb - pa) : 0;
				const at: RGBA = [0, 1, 2].map((j) => a[j] + (b[j] - a[j]) * f).concat(1) as RGBA;
				expect(contrast(white, at), `at ${p}`).toBeGreaterThanOrEqual(4.5);
			}
		});
	}
});
