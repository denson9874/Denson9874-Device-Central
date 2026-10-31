// Browser tests: the built page in Chromium, a simulated Pixel behind navigator.usb, and a local
// stand-in for the Worker serving a small fixture release. Walks the whole flow twice (root and a
// paused, resumed download on a computer; no root and a Reconnect prompt on a phone-sized
// screen), checks what the simulated phone ends up with, and saves screenshots to e2e/out/.
//
//   npm run build && npm run test:e2e        (needs Playwright with Chromium installed)

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bytes, expandSparse, makeSparse, makeSuperEmpty, makeZip, withAvbFooter } from "../test/helpers.ts";
import { startServer } from "./server.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const assets = join(root, ".cloudflare/output/v0/workers/default/assets");
const out = join(here, "out");
const fixtures = join(out, "fixtures");
const shots = join(out, "screenshots");
// require(), not import: it finds a Playwright installed globally (NODE_PATH) as well as a local one
const { chromium } = createRequire(import.meta.url)("playwright");

if (!existsSync(join(assets, "index.html"))) {
	console.error("Build the page first: npm run build");
	process.exit(1);
}
mkdirSync(shots, { recursive: true });
execFileSync("npx", ["vite", "build", "--config", "e2e/vite.fake-usb.config.ts", "--logLevel", "warn"], { cwd: root, stdio: "inherit" });
const fakeUsb = readFileSync(join(out, "fake-usb.js"), "utf8");

// ---- The fixture release ----
const BS = 4096;
const NAME = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial";
const INFO = "version 1\nflash boot\nflash init_boot\nflash vendor_boot\nflash dtbo\nflash --apply-vbmeta vbmeta\nflash vbmeta_system\nreboot fastboot\nupdate-super\nflash product\nflash system\nflash vendor\nif-wipe erase userdata\nif-wipe erase metadata\n";
const images = {
	"boot.img": withAvbFooter(bytes(100_000, 11)),
	"init_boot.img": bytes(90_000, 12),
	"vendor_boot.img": bytes(200_000, 13),
	"dtbo.img": bytes(20_000, 14),
	"vbmeta.img": bytes(8192, 15),
	"vbmeta_system.img": bytes(4096, 16),
	"system.img": makeSparse(BS, [{ raw: bytes(BS * 700, 17) }, { skip: 50 }, { fill: 0x11223344, blocks: 20 }, { raw: bytes(BS * 500, 18) }, { skip: 30 }]),
	"vendor.img": bytes(BS * 400 + 1000, 19),
	"product.img": makeSparse(BS, [{ raw: bytes(BS * 120, 20) }, { skip: 6 }]),
	"super_empty.img": makeSuperEmpty(["product_a", "product_b", "system_a", "system_b", "vendor_a", "vendor_b"]),
};
const stock = bytes(70_000, 99);
const zip = makeZip(
	[
		{ name: "android-info.txt", data: new TextEncoder().encode("require board=cheetah\n") },
		{ name: "fastboot-info.txt", data: new TextEncoder().encode(INFO) },
		...Object.entries(images).map(([name, data]) => ({ name, data })),
	],
	{ zip64: true },
);
const sha = (b) => createHash("sha256").update(b).digest("hex");
rmSync(fixtures, { recursive: true, force: true });
mkdirSync(join(fixtures, "cheetah/flasher"), { recursive: true });
writeFileSync(join(fixtures, `cheetah/flasher/${NAME}-fastboot.zip`), zip);
writeFileSync(join(fixtures, `cheetah/flasher/${NAME}-init_boot-stock.img`), stock);
writeFileSync(
	join(fixtures, "cheetah/flasher.json"),
	JSON.stringify({
		schema: 1,
		device: "cheetah",
		updated: "2026-10-30T12:00:00Z",
		releases: [
			{
				name: NAME,
				channel: "release",
				android: "16.0",
				version: "1.0",
				type: "Unofficial",
				date: "2026-10-29",
				published: "2026-10-30T12:00:00Z",
				zip: { file: `${NAME}-fastboot.zip`, size: zip.byteLength, sha256: sha(zip) },
				initBootStock: { file: `${NAME}-init_boot-stock.img`, size: stock.byteLength, sha256: sha(stock) },
				root: "kernelsu-next",
				requirements: ["require board=cheetah"],
			},
		],
	}),
);
const want = {
	initBootKsu: sha(images["init_boot.img"]),
	stock: sha(stock),
	system: sha(expandSparse(images["system.img"])),
	product: sha(expandSparse(images["product.img"])),
	vendor: sha(images["vendor.img"]),
};

// ---- Fonts: Google Fonts fetched once with curl (the browser here has no direct internet) ----
const fontCache = join(out, "fonts");
mkdirSync(fontCache, { recursive: true });
function cached(url, ua) {
	const f = join(fontCache, sha(url));
	if (!existsSync(f)) {
		try {
			execFileSync("curl", ["-sSf", "-m", "20", "-A", ua, "-o", f, url]);
		} catch {
			return null;
		}
	}
	return readFileSync(f);
}

const failures = [];
function check(ok, what) {
	console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
	if (!ok) failures.push(what);
}

async function newPage(browser, { mobile = false, theme, fake = {} } = {}) {
	const ctx = await browser.newContext(
		mobile
			? { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, userAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36", colorScheme: theme ?? "dark" }
			: { viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1, colorScheme: theme ?? "dark" },
	);
	const ua = await (async () => {
		const p = await ctx.newPage();
		const u = await p.evaluate(() => navigator.userAgent);
		await p.close();
		return u;
	})();
	await ctx.route("https://fonts.googleapis.com/**", async (route) => {
		const body = cached(route.request().url(), ua);
		if (body) await route.fulfill({ body, contentType: "text/css", headers: { "Access-Control-Allow-Origin": "*" } });
		else await route.abort();
	});
	await ctx.route("https://fonts.gstatic.com/**", async (route) => {
		const body = cached(route.request().url(), ua);
		if (body) await route.fulfill({ body, contentType: "font/woff2", headers: { "Access-Control-Allow-Origin": "*" } });
		else await route.abort();
	});
	await ctx.addInitScript(`window.__FAKE_OPTS__ = ${JSON.stringify({ maxDownload: 1024 * 1024, restartMs: 1500, msPerMiB: 400, ...fake })};\n${fakeUsb}`);
	const page = await ctx.newPage();
	const errors = [];
	page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
	page.on("console", (m) => {
		if (m.type() === "error" && !/favicon|ERR_FAILED|fonts\.g/.test(m.text())) errors.push(`console: ${m.text()}`);
	});
	return { ctx, page, errors };
}

/** On a failure: a screenshot, the page's text and its fastboot log, then the error again. */
async function scenario(name, fn) {
	let page = null;
	try {
		await fn((p) => (page = p));
	} catch (e) {
		if (page) {
			await page.screenshot({ path: join(shots, `FAILED-${name}.png`) }).catch(() => {});
			const text = await page.locator("main").innerText().catch(() => "");
			const log = await page.locator("details.log pre").innerText().catch(() => "");
			console.error(`--- ${name}: page text ---\n${text}\n--- fastboot log (last 40 lines) ---\n${log.split("\n").slice(-40).join("\n")}`);
		}
		throw e;
	}
}

async function waitStatus(page, re, timeout = 60_000) {
	await page.waitForFunction((src) => new RegExp(src).test(document.getElementById("status-title")?.textContent ?? ""), re.source, { timeout });
}

async function percentAtLeast(page, re, pct, timeout = 60_000) {
	await page.waitForFunction(
		([src, p]) => {
			const t = document.getElementById("status-title")?.textContent ?? "";
			const m = new RegExp(src).exec(t);
			return !!m && Number(m[1]) >= p;
		},
		[re.source, pct],
		{ timeout },
	);
}

async function phoneState(page) {
	// The simulated phone takes a moment to finish restarting into Android
	await page.waitForFunction(() => window.__fakePhone.mode === "android", null, { timeout: 10_000 }).catch(() => {});
	return page.evaluate(async () => {
		const p = window.__fakePhone;
		const hex = async (b) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", b))].map((x) => x.toString(16).padStart(2, "0")).join("");
		return {
			mode: p.mode,
			erased: [...p.erased].sort(),
			initBootA: await hex(p.physical.get("init_boot_a").slice(0, 90_000)),
			initBootAStock: await hex(p.physical.get("init_boot_a").slice(0, 70_000)),
			initBootBStock: await hex(p.physical.get("init_boot_b").slice(0, 70_000)),
			system: await hex(p.logical.get(`system_${p.slot}`)),
			product: await hex(p.logical.get(`product_${p.slot}`)),
			vendor: await hex(p.logical.get(`vendor_${p.slot}`).slice(0, 400 * 4096 + 1000)),
			logical: [...p.logical.keys()].sort(),
			restarts: window.__fakeUsbLog,
		};
	});
}

const browser = await chromium.launch();
const { server, state, url } = await startServer({ assets, fixtures, bytesPerSecond: 1.5 * 1024 * 1024 });
try {
	// ---------- 1. A computer: root, clean install, a download paused and resumed ----------
	await scenario("computer", async (track) => {
		const { ctx, page, errors } = await newPage(browser);
		track(page);
		await page.goto(url);
		await page.getByRole("button", { name: /Pixel 7 Pro/ }).first().waitFor();
		await page.waitForTimeout(1200);
		await page.screenshot({ path: join(shots, "1-phone.png") });
		await page.getByRole("button", { name: /Pixel 7 Pro/ }).first().click();
		await page.getByRole("button", { name: "Continue with Pixel 7 Pro" }).click();
		await page.getByText("ExpressiveOS 1.0").first().waitFor();
		check(await page.getByLabel(/KernelSU Next/).first().isChecked(), "KernelSU Next is the default for a build that has it");
		check(await page.getByLabel(/Clean install/).isChecked(), "a clean install is the default");
		await page.screenshot({ path: join(shots, "2-build.png"), fullPage: true });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Download", exact: true }).click();
		await percentAtLeast(page, /Downloading ([\d.]+)%/, 30);
		await page.screenshot({ path: join(shots, "3-downloading.png") });
		await page.getByRole("button", { name: "Pause" }).click();
		await waitStatus(page, /Download paused/);
		// A closed tab: the bytes so far stay in the browser
		await page.reload();
		await page.getByRole("button", { name: "Continue with Pixel 7 Pro" }).click();
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Resume download" }).waitFor();
		check(/downloaded earlier/.test(await page.locator(".panel").innerText()), "a paused download is offered to resume after a reload");
		state.bytesPerSecond = 6 * 1024 * 1024;
		await page.getByRole("button", { name: "Resume download" }).click();
		await page.getByText("Downloaded and checked").first().waitFor({ timeout: 60_000 });
		check(state.requests.some((r) => /^GET \/dl\/cheetah\/.*-fastboot\.zip bytes=\d+-$/.test(r) && !/bytes=0-/.test(r)), "the resumed download asked for the rest with a Range request");
		await page.waitForTimeout(700);
		await page.screenshot({ path: join(shots, "3b-downloaded.png") });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.getByText("Ready to install").waitFor();
		await page.screenshot({ path: join(shots, "4-connected.png") });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByLabel(/erases everything/).check();
		await page.getByRole("button", { name: "Install", exact: true }).click();
		// The restart into fastbootd comes first (the simulated phone takes 1.5 s)
		await page.waitForFunction(() => document.querySelector(".bloom-stage")?.getAttribute("data-mode") === "waiting", null, { timeout: 60_000 });
		await page.waitForTimeout(400);
		await page.screenshot({ path: join(shots, "5a-restarting.png") });
		// Part way through writing system
		await page.waitForFunction(
			() => {
				const li = document.querySelector(".steps li.is-running");
				return !!li && /Write system/.test(li.textContent ?? "") && parseInt(li.querySelector(".step-note")?.textContent ?? "0") >= 40;
			},
			null,
			{ timeout: 120_000 },
		);
		await page.screenshot({ path: join(shots, "5b-installing.png") });
		await page.getByRole("heading", { name: "ExpressiveOS is installed" }).waitFor({ timeout: 120_000 });
		await page.waitForTimeout(450);
		await page.screenshot({ path: join(shots, "6-done-bloom.png") });
		await page.waitForTimeout(2500);
		await page.screenshot({ path: join(shots, "6b-done.png") });
		const s = await phoneState(page);
		check(s.mode === "android", `the phone started Android (${s.mode})`);
		check(s.initBootA === want.initBootKsu, "init_boot is KernelSU Next's");
		check(s.system === want.system && s.product === want.product && s.vendor === want.vendor, "system, product and vendor are their images byte for byte");
		check(JSON.stringify(s.erased) === '["metadata","userdata"]', `userdata and metadata erased (${s.erased})`);
		check(JSON.stringify(s.restarts) === '["restart -> fastbootd","restart -> android"]', `restarts: ${s.restarts.join(", ")}`);
		check(errors.length === 0, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
		// Light theme, same page
		await page.locator("#theme-toggle").click();
		await page.waitForTimeout(300);
		await page.screenshot({ path: join(shots, "6c-done-light.png") });
		await ctx.close();
	});

	// ---------- 2. A phone-sized screen: no root, keep data, and the browser asks again ----------
	await scenario("phone", async (track) => {
		state.bytesPerSecond = 0;
		const { ctx, page, errors } = await newPage(browser, { mobile: true, fake: { askAgain: true, slot: "b" } });
		track(page);
		await page.goto(url);
		await page.getByRole("button", { name: /Pixel 7 Pro/ }).first().click();
		await page.waitForTimeout(800);
		await page.screenshot({ path: join(shots, "m1-phone.png") });
		await page.getByRole("button", { name: "Continue with Pixel 7 Pro" }).click();
		await page.getByText("ExpressiveOS 1.0").first().waitFor();
		await page.getByLabel(/No root/).check();
		await page.getByLabel(/Keep my data/).check();
		await page.screenshot({ path: join(shots, "m2-build.png"), fullPage: true });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Download", exact: true }).click();
		await page.getByText("Downloaded and checked").first().waitFor({ timeout: 60_000 });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.getByText("Ready to install").waitFor();
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		check(await page.getByRole("button", { name: "Install", exact: true }).isEnabled(), "keeping data needs no erase confirmation");
		await page.getByRole("button", { name: "Install", exact: true }).click();
		await page.getByRole("button", { name: "Reconnect" }).waitFor({ timeout: 60_000 });
		await page.screenshot({ path: join(shots, "m3-reconnect.png") });
		await page.getByRole("button", { name: "Reconnect" }).click();
		await page.getByRole("heading", { name: "ExpressiveOS is installed" }).waitFor({ timeout: 120_000 });
		await page.waitForTimeout(500);
		await page.screenshot({ path: join(shots, "m4-done.png") });
		const s = await phoneState(page);
		check(s.mode === "android", "the phone started Android");
		check(s.initBootAStock === want.stock && s.initBootBStock === want.stock, "no root: the stock init_boot is on both slots");
		check(s.erased.length === 0, "keeping data: nothing erased");
		check(s.system === want.system, "system written to slot b");
		check(errors.length === 0, `no page errors${errors.length ? `: ${errors.join(" | ")}` : ""}`);
		await ctx.close();
	});

	// ---------- 3. The wrong phone ----------
	await scenario("wrong-phone", async (track) => {
		const { ctx, page } = await newPage(browser, { fake: { product: "husky" } });
		track(page);
		await page.goto(url);
		await page.getByRole("button", { name: /Pixel 7 Pro/ }).first().click();
		await page.getByRole("button", { name: "Continue with Pixel 7 Pro" }).click();
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Download", exact: true }).click();
		await page.getByText("Downloaded and checked").first().waitFor({ timeout: 60_000 });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.getByText("That's a different phone").waitFor();
		check((await page.getByRole("button", { name: "Continue", exact: true }).count()) === 0, "a Pixel 8 Pro can't go on with a Pixel 7 Pro build");
		await page.screenshot({ path: join(shots, "x-wrong-phone.png") });
		await ctx.close();
	});

	// ---------- 4. A locked bootloader ----------
	await scenario("locked", async (track) => {
		const { ctx, page } = await newPage(browser, { fake: { unlocked: false } });
		track(page);
		await page.goto(url);
		await page.getByRole("button", { name: /Pixel 7 Pro/ }).first().click();
		await page.getByRole("button", { name: "Continue with Pixel 7 Pro" }).click();
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Download", exact: true }).click();
		await page.getByText("Downloaded and checked").first().waitFor({ timeout: 60_000 });
		await page.getByRole("button", { name: "Continue", exact: true }).click();
		await page.getByRole("button", { name: "Connect", exact: true }).click();
		await page.getByText("The bootloader is locked").waitFor();
		await page.screenshot({ path: join(shots, "x-locked.png") });
		await page.getByLabel(/unlocking erases everything/).check();
		await page.getByRole("button", { name: "Unlock the bootloader" }).click();
		await page.getByText("Ready to install").waitFor({ timeout: 30_000 });
		check(await page.evaluate(() => window.__fakePhone.unlocked), "the bootloader unlocks after the user agrees");
		await ctx.close();
	});
} finally {
	await browser.close();
	server.close();
}

if (failures.length) {
	console.error(`\n${failures.length} check(s) failed`);
	process.exit(1);
}
console.log(`\nE2E=OK (screenshots in ${shots})`);
