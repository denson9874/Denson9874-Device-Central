// The flasher's six steps: choose the phone, choose the build, download it, connect the phone,
// install, done. The Bloom stage beside them follows along.

import { type DeviceInfo, DEVICES, deviceByCodename } from "../devices.ts";
import { FastbootClient, FastbootError, type LogKind, ProtocolError } from "../fastboot/client.ts";
import { Phone } from "../fastboot/device.ts";
import { FastbootInfoError } from "../fastboot/fastboot-info.ts";
import { logicalPartitions } from "../fastboot/lp.ts";
import { WebUsbConnector, linkTo } from "../fastboot/usb-connector.ts";
import { UsbError, UsbTransport, isFastbootDevice, requestPhone, webUsbSupported } from "../fastboot/webusb.ts";
import { PlanError, type Step, buildPlan, describe } from "../flash/plan.ts";
import { type PhoneReport, canUnlock, inspectPhone, unlockBootloader } from "../flash/preflight.ts";
import { type ImageSource, InstallError, runPlan, stepWeights } from "../flash/runner.ts";
import { type Release, ReleasesError, fetchReleases, fileUrl, formatBytes } from "../releases.ts";
import { StoreError, downloadRelease, fetchVerified, hashFile, listStored, partialSize, removeStored, storageSupported, storeName, storedFile } from "../store/store.ts";
import { ZipError, ZipReader } from "../zip/zip.ts";
import { BloomStage, bloomMark } from "./bloom.ts";
import { type Child, append, h, link, notice } from "./dom.ts";

type StepId = "phone" | "build" | "download" | "connect" | "install" | "done";

const STEPS: Array<{ id: StepId; label: string }> = [
	{ id: "phone", label: "Phone" },
	{ id: "build", label: "Build" },
	{ id: "download", label: "Download" },
	{ id: "connect", label: "Connect" },
	{ id: "install", label: "Install" },
	{ id: "done", label: "Done" },
];

const FLASH_TOOL = "https://flash.android.com/";
const USB_DRIVER = "https://developer.android.com/studio/run/win-usb";
const isAndroid = () => /Android/i.test(navigator.userAgent);

function store(key: string, value?: string): string | null {
	try {
		if (value === undefined) return localStorage.getItem(key);
		localStorage.setItem(key, value);
	} catch {
		/* storage blocked: only a convenience */
	}
	return null;
}

function longDate(iso: string): string {
	const [y, m, d] = iso.split("-").map(Number);
	return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
}

function androidVersion(v: string): string {
	return v.replace(/\.0$/, "");
}

function duration(seconds: number): string {
	if (!Number.isFinite(seconds) || seconds <= 0) return "";
	if (seconds < 60) return "less than a minute left";
	const m = Math.round(seconds / 60);
	if (m < 60) return `about ${m} min left`;
	const hr = Math.floor(m / 60);
	return `about ${hr} h ${m % 60} min left`;
}

function errorText(e: unknown): string {
	if (e instanceof Error) return e.message;
	return String(e);
}

/** Keeps the screen on while something long runs (the browser drops it when the tab is hidden). */
class Awake {
	private lock: WakeLockSentinel | null = null;
	private want = false;

	constructor() {
		document.addEventListener("visibilitychange", () => {
			if (this.want && document.visibilityState === "visible") void this.take();
		});
	}

	private async take() {
		try {
			this.lock = (await navigator.wakeLock?.request("screen")) ?? null;
		} catch {
			this.lock = null;
		}
	}

	on() {
		this.want = true;
		void this.take();
	}

	off() {
		this.want = false;
		void this.lock?.release().catch(() => {});
		this.lock = null;
	}
}

/** Download speed over the last few seconds. */
class Speed {
	private samples: Array<[number, number]> = [];

	reset() {
		this.samples = [];
	}

	add(bytes: number): number {
		const now = performance.now();
		this.samples.push([now, bytes]);
		while (this.samples.length > 2 && now - this.samples[0][0] > 6000) this.samples.shift();
		const [t0, b0] = this.samples[0];
		const dt = (now - t0) / 1000;
		return dt > 0.5 ? (bytes - b0) / dt : 0;
	}
}

interface LogLine {
	kind: LogKind;
	text: string;
}

export class App {
	private step: StepId = "phone";
	private reached = 0;
	private busy = false;
	private bloom: BloomStage;
	private panel: HTMLElement;
	private stepper: HTMLOListElement;
	private statusTitle: HTMLElement;
	private statusDetail: HTMLElement;
	private awake = new Awake();
	private logLines: LogLine[] = [];
	private logView: HTMLPreElement | null = null;

	private device: DeviceInfo | undefined;
	private releases: Release[] | null = null;
	private releasesError: ReleasesError | null = null;
	private release: Release | undefined;
	private root = true;
	private wipe = true;
	private zipFile: File | null = null;
	private phone: Phone | null = null;
	private report: PhoneReport | null = null;
	private androidInfo: string | null = null;
	private connector: WebUsbConnector;
	private reconnectBox: HTMLElement | null = null;
	private flash: { message: string; kind: "danger" | "warn" | "ok" | "info" } | null = null;
	private readonly testers = new URLSearchParams(location.search).has("testers");

	constructor() {
		this.panel = document.getElementById("panel")!;
		this.stepper = document.getElementById("stepper") as HTMLOListElement;
		this.statusTitle = document.getElementById("status-title")!;
		this.statusDetail = document.getElementById("status-detail")!;
		this.bloom = new BloomStage(document.getElementById("stage")!);
		document.getElementById("brand-mark")!.append(bloomMark(30));
		this.connector = new WebUsbConnector({
			needsReconnect: (show) => this.showReconnect(show),
			restarting: (on) => {
				if (this.step !== "install" || !this.busy) return;
				this.bloom.setMode(on ? "waiting" : "install");
				if (on) this.setStatus(null, "Waiting for the phone to restart…");
			},
		});
		this.setupTheme();
		window.addEventListener("beforeunload", (ev) => {
			if (this.busy && this.step === "install") {
				ev.preventDefault();
				ev.returnValue = "";
			}
		});
		if (webUsbSupported()) {
			navigator.usb.addEventListener("disconnect", (ev) => {
				const t = this.phone?.link.transport;
				if (!this.busy && t instanceof UsbTransport && t.device === ev.device) {
					this.phone = null;
					this.report = null;
					if (this.step === "connect") {
						this.flash = { kind: "warn", message: "The phone was unplugged. Plug it back in and connect again." };
						this.render();
					}
				}
			});
		}
		const last = deviceByCodename(store("eos-flasher-device"));
		if (last) this.device = last;
		this.render();
	}

	// ---------- Shell ----------

	private setupTheme() {
		const saved = store("eos-flasher-theme");
		if (saved === "light" || saved === "dark") document.documentElement.dataset.theme = saved;
		document.getElementById("theme-toggle")?.addEventListener("click", () => {
			const dark = matchMedia("(prefers-color-scheme: dark)").matches;
			const now = document.documentElement.dataset.theme ?? (dark ? "dark" : "light");
			const next = now === "dark" ? "light" : "dark";
			document.documentElement.dataset.theme = next;
			store("eos-flasher-theme", next);
		});
	}

	private setStatus(title: string | null, detail?: string) {
		if (title !== null) this.statusTitle.textContent = title;
		if (detail !== undefined) this.statusDetail.textContent = detail;
	}

	private go(step: StepId) {
		this.step = step;
		this.reached = Math.max(this.reached, STEPS.findIndex((s) => s.id === step));
		this.flash = null;
		this.render();
		this.panel.focus({ preventScroll: true });
		if (window.matchMedia("(max-width: 860px)").matches) this.panel.scrollIntoView({ behavior: "smooth", block: "start" });
	}

	private renderStepper() {
		const at = STEPS.findIndex((s) => s.id === this.step);
		this.stepper.replaceChildren(
			...STEPS.map((s, i) => {
				const done = i < at || (i <= this.reached && i !== at);
				const canGo = !this.busy && i !== at && i <= this.reached && s.id !== "done" && this.step !== "done";
				return h(
					"li",
					{ class: i === at ? "is-current" : done ? "is-done" : "" },
					h(
						"button",
						{ type: "button", disabled: !canGo, "aria-current": i === at ? "step" : null, on: { click: () => canGo && this.go(s.id) } },
						h("span", { class: "step-label" }, `${i + 1}. ${s.label}`),
					),
				);
			}),
		);
	}

	private render() {
		this.renderStepper();
		this.logView = null;
		this.reconnectBox = null;
		const body: Child[] = [];
		switch (this.step) {
			case "phone":
				body.push(...this.phoneStep());
				break;
			case "build":
				body.push(...this.buildStep());
				break;
			case "download":
				body.push(...this.downloadStep());
				break;
			case "connect":
				body.push(...this.connectStep());
				break;
			case "install":
				body.push(...this.installStep());
				break;
			case "done":
				body.push(...this.doneStep());
				break;
		}
		this.panel.replaceChildren();
		if (this.flash) this.panel.append(notice(this.flash.kind, null, this.flash.message));
		append(this.panel, body);
	}

	private flashMessage(kind: "danger" | "warn" | "ok" | "info", message: string) {
		this.flash = { kind, message };
		this.render();
	}

	// ---------- 1. Phone ----------

	private phoneStep(): Child[] {
		if (!this.busy) {
			this.bloom.setMode("idle");
			this.bloom.setProgress(1);
			this.setStatus("Install ExpressiveOS", "Right from your browser");
		}
		const usb = webUsbSupported();
		const storage = storageSupported();
		const out: Child[] = [
			h("h2", null, "Which phone are you installing on?"),
			h(
				"p",
				{ class: "lead" },
				"You'll need a USB cable, about 30 minutes, and Chrome or Edge on a computer (or Chrome on an Android phone, connected to this one with a cable).",
			),
		];
		if (!usb) {
			out.push(
				notice(
					"danger",
					"This browser can't talk to phones over USB",
					"Open this page in Google Chrome or Microsoft Edge on a computer, or in Chrome on an Android phone. Firefox and Safari don't support WebUSB.",
				),
			);
		} else if (!storage) {
			out.push(notice("danger", "This browser can't store the download", "Open this page in a normal (not private or incognito) Chrome or Edge window."));
		}
		out.push(
			h(
				"div",
				{ class: "tiles", role: "group", "aria-label": "Phones" },
				...DEVICES.map((d) =>
					h(
						"button",
						{
							class: "tile",
							type: "button",
							"aria-pressed": String(this.device?.codename === d.codename),
							on: {
								click: () => {
									this.selectDevice(d);
									this.render();
								},
							},
						},
						h("span", { class: "tile-model" }, d.model),
						h("span", { class: "tile-code" }, d.codename),
					),
				),
			),
		);
		const detect = h(
			"button",
			{ class: "btn btn-secondary", type: "button", disabled: !usb || this.busy, on: { click: () => void this.detect() } },
			"Detect a connected phone",
		);
		out.push(
			h(
				"div",
				{ class: "actions" },
				h(
					"button",
					{ class: "btn btn-primary btn-big", type: "button", disabled: !this.device || !usb || !storage, on: { click: () => this.go("build") } },
					this.device ? `Continue with ${this.device.model}` : "Choose your phone",
				),
				detect,
			),
			this.prepList(),
		);
		return out;
	}

	private prepList(): HTMLElement {
		return h(
			"details",
			{ class: "prep" },
			h("summary", null, "Before you start"),
			h(
				"ul",
				null,
				h("li", null, h("strong", null, "Back up your phone. "), "A clean install, and unlocking the bootloader, erase everything on it."),
				h(
					"li",
					null,
					h("strong", null, "Turn on OEM unlocking. "),
					"In Settings, open About phone and tap Build number seven times. Then open System, Developer options and turn on OEM unlocking. Some carrier phones can't be unlocked.",
				),
				h(
					"li",
					null,
					h("strong", null, "Update to the latest stock Android first. "),
					"ExpressiveOS doesn't include the phone's firmware (bootloader and modem), so it needs a recent one. Update from Settings, or flash the latest factory image with ",
					link(FLASH_TOOL, "Google's Android Flash Tool"),
					".",
				),
				h(
					"li",
					null,
					h("strong", null, "On Windows, "),
					"install the ",
					link(USB_DRIVER, "Google USB Driver"),
					" if the phone doesn't show up when you connect it.",
				),
				h("li", null, h("strong", null, "Use a good cable "), "plugged straight into the computer (not a hub), and charge the phone to at least half."),
				h("li", null, h("strong", null, "Leave about 8 GB free "), "on this computer for the download."),
			),
		);
	}

	private selectDevice(d: DeviceInfo) {
		if (this.device?.codename !== d.codename) {
			this.releases = null;
			this.releasesError = null;
			this.release = undefined;
			this.zipFile = null;
			this.reached = 0;
		}
		this.device = d;
		store("eos-flasher-device", d.codename);
	}

	private async detect() {
		let d: USBDevice;
		try {
			d = await requestPhone();
		} catch (e) {
			if (!(e instanceof UsbError)) this.flashMessage("danger", errorText(e));
			return;
		}
		this.busy = true;
		this.setStatus("Looking at your phone…", "");
		try {
			const link = await linkTo(d);
			let product: string | null;
			try {
				product = await new FastbootClient(link.transport).getVar("product");
			} finally {
				await link.close();
			}
			const dev = deviceByCodename(product);
			this.busy = false;
			if (!dev) {
				this.flashMessage("warn", `This phone says it's "${product ?? "unknown"}", which ExpressiveOS isn't built for.`);
				return;
			}
			this.selectDevice(dev);
			this.setStatus(`Found your ${dev.model}`, "Ready when you are");
			this.flashMessage("ok", `Found a ${dev.model} (${dev.codename}).`);
		} catch (e) {
			this.busy = false;
			this.setStatus("Install ExpressiveOS", "Right from your browser");
			this.flashMessage("danger", errorText(e));
		}
	}

	// ---------- 2. Build ----------

	private buildStep(): Child[] {
		const dev = this.device!;
		this.bloom.setMode("idle");
		this.setStatus(`ExpressiveOS for ${dev.model}`, "Choose a build");
		const out: Child[] = [h("h2", null, "Choose a build"), h("p", { class: "lead" }, `ExpressiveOS builds for the ${dev.model} (${dev.codename}).`)];
		if (!this.releases && !this.releasesError) {
			out.push(h("p", null, "Loading the builds…"));
			void this.loadReleases();
			return out;
		}
		if (this.releasesError) {
			out.push(
				notice(this.releasesError.kind === "none" ? "info" : "danger", null, this.releasesError.message),
				h(
					"div",
					{ class: "actions" },
					h(
						"button",
						{
							class: "btn btn-secondary",
							type: "button",
							on: {
								click: () => {
									this.releasesError = null;
									this.render();
								},
							},
						},
						"Try again",
					),
					h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("phone") } }, "Choose another phone"),
				),
			);
			return out;
		}
		const list = this.releases!.filter((r) => r.channel === "release" || this.testers);
		if (!list.length) {
			out.push(notice("info", null, "There are no ExpressiveOS builds for this phone yet."));
			return out;
		}
		if (!this.release || !list.includes(this.release)) this.pickRelease(list[0]);
		const rel = this.release!;
		const newest = list.find((r) => r.channel === "release");
		out.push(
			h(
				"div",
				{ class: "choices", role: "radiogroup", "aria-label": "Builds" },
				...list.map((r) =>
					this.choice("release", r.name, r === rel, () => this.pickRelease(r), [
						h(
							"span",
							{ class: "choice-title" },
							`ExpressiveOS ${r.version}`,
							r === newest ? h("span", { class: "badge" }, "Latest") : null,
							r.channel === "testers" ? h("span", { class: "badge badge-testers" }, "Testers") : null,
							r.root ? h("span", { class: "badge badge-root" }, "KernelSU Next") : null,
						),
						h("span", { class: "choice-aside" }, formatBytes(r.zip.size)),
						h("span", { class: "choice-meta" }, `Android ${androidVersion(r.android)} · built ${longDate(r.date)} · ${r.type}`),
					]),
				),
			),
		);
		if (rel.initBootStock) {
			out.push(
				h(
					"fieldset",
					null,
					h("legend", null, "Root"),
					h(
						"div",
						{ class: "choices" },
						this.choice("root", "ksun", this.root, () => (this.root = true), [
							h("span", { class: "choice-title" }, "KernelSU Next"),
							h("span", { class: "choice-meta" }, "Root with KernelSU Next and susfs. The KernelSU Next app comes with ExpressiveOS; open it once after the first start."),
						]),
						this.choice("root", "none", !this.root, () => (this.root = false), [
							h("span", { class: "choice-title" }, "No root"),
							h("span", { class: "choice-meta" }, "The stock init_boot on both slots, for apps that refuse rooted phones. You can install again with root later."),
						]),
					),
				),
			);
		} else {
			out.push(notice("info", "No root option", `Root with KernelSU Next isn't available for the ${dev.model} yet, so this build installs without root.`));
		}
		out.push(
			h(
				"fieldset",
				null,
				h("legend", null, "Install type"),
				h(
					"div",
					{ class: "choices" },
					this.choice("wipe", "clean", this.wipe, () => (this.wipe = true), [
						h("span", { class: "choice-title" }, "Clean install", h("span", { class: "badge" }, "Recommended")),
						h("span", { class: "choice-meta" }, "Erases everything on the phone. Needed when coming from stock Android or another ROM."),
					]),
					this.choice("wipe", "keep", !this.wipe, () => (this.wipe = false), [
						h("span", { class: "choice-title" }, "Keep my data"),
						h("span", { class: "choice-meta" }, "Only for updating a phone that already runs ExpressiveOS. Coming from anything else, the phone won't start until it's wiped."),
					]),
				),
			),
			h(
				"div",
				{ class: "actions" },
				h("button", { class: "btn btn-primary btn-big", type: "button", on: { click: () => this.go("download") } }, "Continue"),
				h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("phone") } }, "Back"),
			),
		);
		return out;
	}

	private pickRelease(r: Release) {
		const changed = this.release !== r;
		this.release = r;
		if (!changed) return;
		this.zipFile = null;
		// Root by default when the build has it
		this.root = !!r.initBootStock;
	}

	private choice(group: string, value: string, checked: boolean, onPick: () => void, content: Child[]): HTMLLabelElement {
		return h(
			"label",
			{ class: "choice" },
			h("input", {
				type: "radio",
				name: group,
				value,
				checked,
				on: {
					change: () => {
						onPick();
						this.render();
						// The panel was drawn again: keep the keyboard where it was
						this.panel.querySelector<HTMLInputElement>(`input[name="${group}"][value="${CSS.escape(value)}"]`)?.focus();
					},
				},
			}),
			...content,
		);
	}

	private async loadReleases() {
		const dev = this.device!;
		try {
			const r = await fetchReleases(dev.codename);
			if (this.device !== dev) return;
			this.releases = r;
			if (r.length && !r.some((x) => x.initBootStock)) this.root = false;
		} catch (e) {
			if (this.device !== dev) return;
			this.releasesError = e instanceof ReleasesError ? e : new ReleasesError(errorText(e), "network");
		}
		if (this.step === "build") this.render();
	}

	// ---------- 3. Download ----------

	private downloadStep(): Child[] {
		const rel = this.release!;
		const name = storeName(rel.zip.sha256, "zip");
		const out: Child[] = [
			h("h2", null, "Download the build"),
			h(
				"p",
				{ class: "lead" },
				`${rel.zip.file} is ${formatBytes(rel.zip.size)}. It's kept in this browser, so you can stop and come back, and its SHA-256 is checked before anything touches the phone.`,
			),
		];
		const progress = h("div", { class: "bar", hidden: true }, h("span"));
		const line = h("p", { class: "status-detail", hidden: true });
		const actions = h("div", { class: "actions" });
		out.push(progress, line, actions);

		if (this.busy) return out; // a download is running and updates the elements below
		this.bloom.setMode("idle");
		this.setStatus("Ready to download", formatBytes(rel.zip.size));

		const fileInput = h("input", {
			type: "file",
			accept: ".zip,application/zip",
			hidden: true,
			on: {
				change: () => {
					const f = fileInput.files?.[0];
					if (f) void this.useOwnZip(f);
				},
			},
		});

		void (async () => {
			const stored = this.zipFile ?? (await storedFile(name, rel.zip.size));
			if (this.step !== "download" || this.release !== rel || this.busy) return;
			if (stored) {
				this.zipFile = stored;
				this.bloom.setMode("download");
				this.bloom.setProgress(1);
				this.setStatus("Downloaded and checked", formatBytes(rel.zip.size));
				actions.before(notice("ok", "Downloaded and checked", `${rel.zip.file} matches its SHA-256.`));
				actions.replaceChildren(
					h("button", { class: "btn btn-primary btn-big", type: "button", on: { click: () => this.go("connect") } }, "Continue"),
					h(
						"button",
						{
							class: "btn btn-quiet",
							type: "button",
							on: {
								click: async () => {
									await removeStored(name);
									this.zipFile = null;
									this.render();
								},
							},
						},
						"Remove the download",
					),
				);
				return;
			}
			const partial = await partialSize(name);
			const est = await navigator.storage?.estimate?.().catch(() => null);
			const need = rel.zip.size - partial;
			if (est?.quota !== undefined && est.usage !== undefined && est.quota - est.usage < need) {
				actions.before(
					notice(
						"warn",
						"There may not be room",
						`This browser says it can store ${formatBytes(Math.max(0, est.quota - est.usage))} more, and the download needs ${formatBytes(need)}. Free up disk space first, or use a copy of the zip you already have.`,
					),
				);
			}
			const others = (await listStored()).filter((f) => f.name !== name && !f.name.startsWith(name));
			if (others.length) {
				const total = others.reduce((n, f) => n + f.size, 0);
				actions.after(
					h(
						"p",
						null,
						h(
							"button",
							{
								class: "btn btn-quiet",
								type: "button",
								on: {
									click: async () => {
										for (const f of others) await removeStored(f.name);
										this.render();
									},
								},
							},
							`Remove ${others.length === 1 ? "an older download" : `${others.length} older downloads`} (${formatBytes(total)})`,
						),
					),
				);
			}
			if (partial > 0) {
				line.hidden = false;
				line.textContent = `${formatBytes(partial)} of ${formatBytes(rel.zip.size)} downloaded earlier. It picks up where it stopped.`;
				progress.hidden = false;
				(progress.firstElementChild as HTMLElement).style.width = `${(partial / rel.zip.size) * 100}%`;
				this.bloom.setMode("download");
				this.bloom.setProgress(partial / rel.zip.size);
			}
			actions.replaceChildren(
				h("button", { class: "btn btn-primary btn-big", type: "button", on: { click: () => void this.startDownload(progress, line, actions) } }, partial > 0 ? "Resume download" : "Download"),
				h("button", { class: "btn btn-secondary", type: "button", on: { click: () => fileInput.click() } }, "Use a zip I already have"),
				h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("build") } }, "Back"),
				fileInput,
			);
		})();
		return out;
	}

	private async startDownload(progress: HTMLElement, line: HTMLElement, actions: HTMLElement) {
		const rel = this.release!;
		const dev = this.device!;
		const name = storeName(rel.zip.sha256, "zip");
		const ac = new AbortController();
		this.busy = true;
		this.renderStepper();
		this.awake.on();
		const speed = new Speed();
		const bar = progress.firstElementChild as HTMLElement;
		progress.hidden = false;
		line.hidden = false;
		this.bloom.setMode("download");
		actions.replaceChildren(
			h(
				"button",
				{
					class: "btn btn-secondary",
					type: "button",
					on: { click: () => ac.abort() },
				},
				"Pause",
			),
		);
		this.setStatus("Starting the download…", "");
		try {
			const file = await downloadRelease(
				fileUrl(dev.codename, rel.zip.file),
				name,
				rel.zip.size,
				rel.zip.sha256,
				(p) => {
					const frac = p.total ? p.done / p.total : 0;
					if (p.phase === "checking") {
						this.bloom.setMode("verify");
						this.setStatus(`Checking what's already here ${Math.floor(frac * 100)}%`, "Your earlier download is checked again before it continues");
						speed.reset();
						return;
					}
					if (p.phase === "verifying") {
						this.bloom.setMode("verify");
						this.setStatus("Checking the download…", "Comparing its SHA-256");
						return;
					}
					this.bloom.setMode("download");
					const bps = speed.add(p.done);
					this.bloom.setProgress(frac);
					this.bloom.setSpeed(bps);
					bar.style.width = `${frac * 100}%`;
					const pct = Math.floor(frac * 1000) / 10;
					this.setStatus(`Downloading ${pct.toFixed(1)}%`, bps > 0 ? `${(bps / 1024 / 1024).toFixed(1)} MB/s · ${duration((p.total - p.done) / bps)}` : "");
					line.textContent = `${formatBytes(p.done)} of ${formatBytes(p.total)}`;
				},
				ac.signal,
				(attempt) => this.setStatus(null, `The connection dropped; trying again (${attempt})…`),
			);
			this.zipFile = file;
			this.busy = false;
			this.awake.off();
			this.bloom.setMode("download");
			this.bloom.setProgress(1);
			for (let i = 0; i < 4; i++) setTimeout(() => this.bloom.pulse(i), i * 180);
			this.render();
		} catch (e) {
			this.busy = false;
			this.awake.off();
			if (e instanceof StoreError && e.code === "cancelled") {
				this.render();
				this.setStatus("Download paused", "Resume whenever you like");
				return;
			}
			this.bloom.setMode("error");
			this.setStatus("The download stopped", "");
			this.flashMessage("danger", errorText(e));
		}
	}

	private async useOwnZip(f: File) {
		const rel = this.release!;
		if (f.size !== rel.zip.size) {
			this.flashMessage("danger", `That file isn't ${rel.zip.file}: it's ${formatBytes(f.size)}, not ${formatBytes(rel.zip.size)}.`);
			return;
		}
		this.busy = true;
		this.renderStepper();
		this.awake.on();
		this.bloom.setMode("verify");
		try {
			const sha = await hashFile(f, (p) => {
				const frac = p.total ? p.done / p.total : 0;
				this.bloom.setProgress(frac);
				this.setStatus(`Checking your zip ${Math.floor(frac * 100)}%`, "Comparing its SHA-256 with the build's");
			});
			this.busy = false;
			this.awake.off();
			if (sha !== rel.zip.sha256) {
				this.bloom.setMode("error");
				this.setStatus("That zip doesn't match", "");
				this.flashMessage("danger", `That file isn't ${rel.zip.file} (its SHA-256 is different). Download the build here instead.`);
				return;
			}
			this.zipFile = f;
			this.render();
		} catch (e) {
			this.busy = false;
			this.awake.off();
			this.bloom.setMode("error");
			this.flashMessage("danger", errorText(e));
		}
	}

	// ---------- 4. Connect ----------

	private connectStep(): Child[] {
		const dev = this.device!;
		if (!this.busy) {
			this.bloom.setMode("idle");
			this.bloom.setProgress(1);
			this.setStatus(this.report ? "Phone connected" : "Connect your phone", this.report ? `${dev.model} · ${this.report.serial ?? ""}` : "In fastboot mode, over USB");
		}
		const out: Child[] = [h("h2", null, "Connect your phone")];
		if (!this.phone || !this.report) {
			out.push(
				h(
					"ol",
					{ class: "howto" },
					h("li", null, "Turn the phone off. Then hold ", h("strong", null, "Power"), " and ", h("strong", null, "Volume down"), " together until you see ", h("strong", null, "Fastboot Mode"), "."),
					h(
						"li",
						null,
						isAndroid()
							? "Connect it to this phone with a USB-C cable (this phone is the host; an OTG adapter may be needed)."
							: "Plug it into this computer with a USB cable.",
					),
					h("li", null, "Press ", h("strong", null, "Connect"), " and choose your phone in the list. It may be called Pixel, Android or Fastboot."),
				),
				h(
					"div",
					{ class: "actions" },
					h("button", { class: "btn btn-primary btn-big", type: "button", disabled: this.busy, on: { click: () => void this.connect() } }, this.busy ? "Connecting…" : "Connect"),
					h("button", { class: "btn btn-quiet", type: "button", disabled: this.busy, on: { click: () => this.go("download") } }, "Back"),
				),
				h(
					"p",
					{ class: "status-detail" },
					"Phone not in the list? Try another cable or port",
					isAndroid() ? "." : ", and on Windows install the ",
					isAndroid() ? null : link(USB_DRIVER, "Google USB Driver"),
					isAndroid() ? null : ". Close any other program using the phone, such as a terminal running adb or fastboot.",
				),
			);
			return out;
		}
		const r = this.report;
		const product = r.product ?? "unknown";
		out.push(
			h(
				"dl",
				{ class: "facts" },
				h("dt", null, "Phone"),
				h("dd", null, deviceByCodename(product)?.model ?? product, ` (${product})`),
				h("dt", null, "Serial"),
				h("dd", null, r.serial ?? "unknown"),
				h("dt", null, "Bootloader"),
				h("dd", null, r.unlocked === null ? "unknown" : r.unlocked ? "Unlocked" : "Locked"),
				h("dt", null, "Mode"),
				h("dd", null, r.mode === "fastbootd" ? "fastbootd" : "Fastboot (bootloader)"),
				r.currentSlot ? h("dt", null, "Active slot") : null,
				r.currentSlot ? h("dd", null, r.currentSlot.toUpperCase()) : null,
				r.bootloader ? h("dt", null, "Bootloader version") : null,
				r.bootloader ? h("dd", null, r.bootloader) : null,
			),
		);
		const problems = this.problems();
		if (problems.length) {
			out.push(...problems);
			out.push(
				h(
					"div",
					{ class: "actions" },
					h("button", { class: "btn btn-secondary", type: "button", disabled: this.busy, on: { click: () => void this.disconnect() } }, "Connect a different phone"),
					h("button", { class: "btn btn-quiet", type: "button", disabled: this.busy, on: { click: () => this.go("phone") } }, "Choose another model"),
				),
			);
			return out;
		}
		if (r.unlocked === false) {
			out.push(...this.unlockPanel());
			return out;
		}
		const fw = this.release?.firmware;
		if (fw?.bootloader && r.bootloader && fw.bootloader !== r.bootloader) {
			out.push(
				notice(
					"warn",
					"Different firmware",
					`This build was made on bootloader ${fw.bootloader}, and the phone has ${r.bootloader}. If it doesn't start, flash the latest factory image with Google's Android Flash Tool, then install again.`,
				),
			);
		}
		out.push(
			notice("ok", "Ready to install", `Your ${dev.model} is connected and the build is for it.`),
			h(
				"div",
				{ class: "actions" },
				h("button", { class: "btn btn-primary btn-big", type: "button", on: { click: () => this.go("install") } }, "Continue"),
				h("button", { class: "btn btn-quiet", type: "button", on: { click: () => void this.disconnect() } }, "Disconnect"),
			),
		);
		return out;
	}

	/** Reasons the connected phone can't take this build. */
	private problems(): Child[] {
		const r = this.report!;
		const dev = this.device!;
		const out: Child[] = [];
		if (r.product !== dev.codename) {
			const other = deviceByCodename(r.product);
			out.push(
				notice(
					"danger",
					"That's a different phone",
					other
						? `This is a ${other.model} (${other.codename}), and the build is for the ${dev.model}. Go back and choose the ${other.model}, or connect your ${dev.model}.`
						: `This phone says it's "${r.product ?? "unknown"}", and the build is for the ${dev.model} (${dev.codename}).`,
				),
			);
			return out;
		}
		const failed = r.requirements.filter((x) => !x.ok && !x.skipped);
		if (failed.length || r.requirementErrors.length) {
			out.push(
				notice(
					"danger",
					"The build's android-info.txt doesn't accept this phone",
					h(
						"ul",
						null,
						...failed.map((f) => h("li", null, `${f.requirement.name} must ${f.requirement.invert ? "not " : ""}be ${f.requirement.options.join(" or ")}; the phone says ${f.value ?? "nothing"}`)),
						...r.requirementErrors.map((e) => h("li", null, `Unreadable line: ${e}`)),
					),
				),
			);
		}
		return out;
	}

	private unlockPanel(): Child[] {
		const out: Child[] = [
			notice(
				"warn",
				"The bootloader is locked",
				"ExpressiveOS can only be installed on an unlocked phone. Unlocking erases everything on it, and Google Pay and some banking apps may stop working.",
			),
		];
		const confirm = h("input", { type: "checkbox", id: "unlock-ok" });
		const btn = h("button", { class: "btn btn-danger", type: "button", disabled: true, on: { click: () => void this.unlock() } }, "Unlock the bootloader");
		confirm.addEventListener("change", () => (btn.disabled = !confirm.checked || this.busy));
		out.push(
			h("label", { class: "check" }, confirm, h("span", null, "I understand unlocking erases everything on the phone.")),
			h("div", { class: "actions" }, btn, h("button", { class: "btn btn-quiet", type: "button", on: { click: () => void this.disconnect() } }, "Disconnect")),
		);
		return out;
	}

	private logger = (kind: LogKind, text: string) => {
		this.logLines.push({ kind, text });
		if (this.logLines.length > 3000) this.logLines.splice(0, 1000);
		this.showLogLine({ kind, text });
	};

	private showLogLine(l: LogLine) {
		if (!this.logView) return;
		this.logView.append(h("span", { class: `k-${l.kind}` }, `${l.kind === "cmd" ? "> " : l.kind === "note" ? "# " : "  "}${l.text}\n`));
		if (this.logView.childNodes.length > 3000) this.logView.firstChild?.remove();
		this.logView.scrollTop = this.logView.scrollHeight;
	}

	private async connect() {
		const dev = this.device!;
		let device: USBDevice;
		try {
			// A phone this site may already use is taken without asking again
			const known = (await navigator.usb.getDevices()).filter(isFastbootDevice);
			device = known.length === 1 ? known[0] : await requestPhone();
		} catch (e) {
			if (!(e instanceof UsbError)) this.flashMessage("danger", errorText(e));
			return;
		}
		this.busy = true;
		this.render();
		this.setStatus("Connecting…", "");
		try {
			await this.phone?.link.close().catch(() => {});
			const link = await linkTo(device);
			this.phone = new Phone(link, this.connector, this.logger);
			this.androidInfo = await this.readAndroidInfo();
			this.report = await inspectPhone(this.phone, this.androidInfo);
			this.busy = false;
			this.setStatus("Phone connected", `${deviceByCodename(this.report.product)?.model ?? this.report.product ?? ""} · ${this.report.serial ?? ""}`);
			if (this.report.product !== dev.codename) this.bloom.setMode("error");
			this.render();
		} catch (e) {
			this.busy = false;
			this.phone = null;
			this.report = null;
			this.bloom.setMode("error");
			this.setStatus("Couldn't connect", "");
			this.flashMessage("danger", errorText(e));
		}
	}

	private async readAndroidInfo(): Promise<string | null> {
		if (!this.zipFile) return null;
		const zip = await ZipReader.open(this.zipFile);
		return zip.entry("android-info.txt") ? zip.text("android-info.txt") : null;
	}

	private async disconnect() {
		await this.phone?.link.close().catch(() => {});
		this.phone = null;
		this.report = null;
		this.render();
	}

	private async unlock() {
		const phone = this.phone!;
		this.busy = true;
		this.render();
		try {
			const able = await canUnlock(phone);
			if (able === false) {
				this.busy = false;
				this.flashMessage(
					"danger",
					"OEM unlocking is off. Start the phone, turn on OEM unlocking in Settings › System › Developer options, then restart into Fastboot Mode and connect again.",
				);
				return;
			}
			this.bloom.setMode("waiting");
			this.setStatus("Confirm on the phone", "Use the volume keys to choose Unlock the bootloader, then press Power");
			const result = await unlockBootloader(phone);
			this.busy = false;
			if (result === "refused") {
				this.bloom.setMode("idle");
				this.flashMessage("warn", "The phone didn't unlock (it was cancelled or refused). You can try again.");
				return;
			}
			// The phone erases itself and stays in Fastboot Mode; read its state again
			try {
				this.report = await inspectPhone(phone, this.androidInfo);
			} catch {
				this.phone = null;
				this.report = null;
				this.flash = { kind: "info", message: "The bootloader is unlocked. Connect the phone again to go on." };
				this.render();
				return;
			}
			this.flash = { kind: "ok", message: "The bootloader is unlocked." };
			this.render();
		} catch (e) {
			this.busy = false;
			this.bloom.setMode("error");
			this.flashMessage("danger", errorText(e));
		}
	}

	// ---------- 5. Install ----------

	private installStep(): Child[] {
		const dev = this.device!;
		const rel = this.release!;
		const out: Child[] = [h("h2", null, "Install ExpressiveOS")];
		if (!this.zipFile) {
			out.push(
				notice("warn", null, "The build isn't downloaded."),
				h("div", { class: "actions" }, h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("download") } }, "Download the build")),
			);
			return out;
		}
		if (!this.phone || !this.report) {
			out.push(
				notice("warn", null, "The phone isn't connected any more."),
				h("div", { class: "actions" }, h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("connect") } }, "Connect the phone")),
			);
			return out;
		}
		this.bloom.setMode("idle");
		this.setStatus("Ready to install", `${rel.zip.file}`);
		out.push(
			h(
				"dl",
				{ class: "facts" },
				h("dt", null, "Build"),
				h("dd", null, `ExpressiveOS ${rel.version} · Android ${androidVersion(rel.android)} · ${longDate(rel.date)}`),
				h("dt", null, "Root"),
				h("dd", null, rel.initBootStock ? (this.root ? "KernelSU Next" : "No root (stock init_boot)") : "No root"),
				h("dt", null, "Install"),
				h("dd", null, this.wipe ? "Clean: erases everything on the phone" : "Keep data (update)"),
				h("dt", null, "Phone"),
				h("dd", null, `${dev.model} · ${this.report.serial ?? ""}`),
			),
			notice(
				"info",
				null,
				"Keep the phone plugged in and this tab open until it's done; it takes 5 to 15 minutes. The phone restarts on its own along the way.",
			),
		);
		const go = h("button", { class: "btn btn-primary btn-big", type: "button", disabled: this.wipe, on: { click: () => void this.install() } }, "Install");
		if (this.wipe) {
			const ok = h("input", { type: "checkbox", on: { change: () => (go.disabled = !ok.checked) } });
			out.push(h("label", { class: "check" }, ok, h("span", null, "I understand this erases everything on the phone.")));
		}
		out.push(h("div", { class: "actions" }, go, h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("connect") } }, "Back")));
		return out;
	}

	private showReconnect(show: boolean) {
		if (!this.reconnectBox) return;
		this.reconnectBox.hidden = !show;
		if (show) {
			this.setStatus(null, "Press Reconnect and choose the phone again");
			this.reconnectBox.querySelector("button")?.focus();
		}
	}

	private async install() {
		const phone = this.phone!;
		const rel = this.release!;
		const dev = this.device!;
		const zipFile = this.zipFile!;
		this.busy = true;
		this.awake.on();
		this.renderStepper();
		this.bloom.setMode("install");
		this.bloom.setProgress(0);
		this.setStatus("Getting ready…", "Reading the build");

		const list = h("ol", { class: "steps" });
		const bar = h("div", { class: "bar" }, h("span"));
		this.reconnectBox = h(
			"div",
			{ class: "reconnect", hidden: true },
			h("strong", null, "Choose the phone again"),
			h("p", null, "The phone restarted, and the browser needs you to pick it again before it can go on."),
			h(
				"button",
				{
					class: "btn btn-primary btn-attention",
					type: "button",
					on: {
						click: () =>
							void this.connector.pick().catch((e) => {
								if (e instanceof UsbError && e.message !== "No phone was chosen") this.setStatus(null, e.message);
							}),
					},
				},
				"Reconnect",
			),
		);
		const pre = h("pre");
		this.logView = pre;
		for (const l of this.logLines.slice(-400)) this.showLogLine(l);
		this.panel.replaceChildren(
			h("h2", null, "Installing ExpressiveOS"),
			h("p", { class: "lead" }, "Keep the phone plugged in and this tab open."),
			bar,
			this.reconnectBox,
			list,
			h("details", { class: "log" }, h("summary", null, "Details"), pre),
		);

		let steps: Step[];
		let images: ImageSource;
		try {
			const zip = await ZipReader.open(zipFile);
			const has = (n: string) => !!zip.entry(n);
			const fbInfo = has("fastboot-info.txt") ? await zip.text("fastboot-info.txt") : null;
			const logical = has("super_empty.img") ? logicalPartitions(await zip.bytes("super_empty.img", 16 * 1024 * 1024)) : null;
			steps = buildPlan(fbInfo, has, logical, { wipe: this.wipe, root: this.root, hasStockInitBoot: !!rel.initBootStock });
			let stock: Blob | null = null;
			if (steps.some((s) => s.kind === "flash" && s.image.kind === "stock-init-boot")) {
				this.setStatus(null, "Downloading the stock init_boot");
				const sib = rel.initBootStock!;
				stock = await fetchVerified(fileUrl(dev.codename, sib.file), sib.size, sib.sha256);
			}
			images = {
				image: async (ref) => (ref.kind === "zip" ? zip.blob(ref.name) : stock!),
				superEmpty: () => zip.blob("super_empty.img"),
				size: (ref) => (ref.kind === "zip" ? (zip.entry(ref.name)?.size ?? 0) : (rel.initBootStock?.size ?? 0)),
			};
		} catch (e) {
			this.installFailed(e instanceof ZipError || e instanceof PlanError || e instanceof FastbootInfoError ? `The build can't be installed: ${e.message}` : errorText(e), null);
			return;
		}

		const rows = steps.map((s) => {
			const note = h("span", { class: "step-note" });
			const li = h("li", null, h("span", { class: "dot", "aria-hidden": "true" }), h("span", null, describe(s)), note);
			list.append(li);
			return { li, note };
		});
		const weights = stepWeights(steps, images);
		const total = weights.reduce((a, b) => a + b, 0);
		const before = weights.map((_, i) => weights.slice(0, i).reduce((a, b) => a + b, 0));
		let current = 0;
		let shown = 0;
		const setOverall = (f: number) => {
			const v = Math.max(shown, Math.min(1, f));
			shown = v;
			this.bloom.setProgress(v);
			(bar.firstElementChild as HTMLElement).style.width = `${v * 100}%`;
			this.setStatus(`Installing ${Math.floor(v * 100)}%`);
		};
		let flashes = 0;
		try {
			await runPlan(
				phone,
				steps,
				images,
				{
					step: (i, state, note) => {
						current = i;
						const row = rows[i];
						row.li.className = state === "running" ? "is-running" : state === "done" ? "is-done" : "is-skipped";
						row.note.textContent = state === "skipped" ? (note ?? "skipped") : "";
						if (state === "running") {
							row.li.scrollIntoView({ block: "nearest" });
							const s = steps[i];
							this.bloom.setMode(s.kind === "reboot" || s.kind === "start-android" ? "waiting" : "install");
							this.setStatus(null, describe(s));
						}
						if (state === "done" && steps[i].kind === "flash") this.bloom.pulse(flashes++ % 4);
						setOverall((before[i] + (state === "running" ? 0 : weights[i])) / total);
					},
					progress: (i, f) => {
						setOverall((before[i] + weights[i] * f) / total);
						if (f > 0 && f < 1) rows[i].note.textContent = `${Math.floor(f * 100)}%`;
					},
					note: (text) => {
						rows[current].note.textContent = text.replace(/^.*: /, "");
						this.logger("note", text);
					},
				},
			);
		} catch (e) {
			const cause = e instanceof InstallError ? e.cause : e;
			if (e instanceof InstallError) {
				rows[e.stepIndex].li.className = "is-failed";
			}
			this.installFailed(this.explain(cause), e instanceof InstallError ? describe(e.step) : null);
			return;
		}
		this.busy = false;
		this.awake.off();
		this.phone = null;
		this.report = null;
		this.go("done");
	}

	private explain(e: unknown): string {
		if (e instanceof FastbootError) {
			if (/lock/i.test(e.reply)) return `${e.message}. The bootloader may be locked; connect again to check.`;
			return e.message;
		}
		if (e instanceof ProtocolError || e instanceof UsbError) return `${e.message}`;
		if (e instanceof DOMException && e.name === "NetworkError") return "The USB connection was lost. Check the cable, put the phone in Fastboot Mode and try again.";
		return errorText(e);
	}

	private installFailed(message: string, step: string | null) {
		this.busy = false;
		this.awake.off();
		this.showReconnect(false);
		this.bloom.setMode("error");
		this.setStatus("The install stopped", step ?? "");
		// The connection may be gone; the next try connects afresh
		void this.phone?.link.close().catch(() => {});
		this.phone = null;
		this.report = null;
		this.renderStepper();
		const box = notice(
			"danger",
			step ? `Stopped at: ${step}` : "The install didn't start",
			message,
			"Nothing is lost by trying again: put the phone in Fastboot Mode if it isn't (hold Power and Volume down), connect it and install again. The phone won't start ExpressiveOS until an install finishes.",
		);
		const actions = h(
			"div",
			{ class: "actions" },
			h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("connect") } }, "Try again"),
		);
		this.panel.querySelector(".lead")?.after(box, actions);
	}

	// ---------- 6. Done ----------

	private doneStep(): Child[] {
		const dev = this.device!;
		const rel = this.release!;
		this.bloom.celebrate();
		this.setStatus("ExpressiveOS is installed", `Enjoy your ${dev.model}`);
		const rooted = !!rel.initBootStock && this.root;
		const name = storeName(rel.zip.sha256, "zip");
		const out: Child[] = [
			h("h2", null, "ExpressiveOS is installed"),
			h("p", { class: "lead" }, `Your ${dev.model} is starting ExpressiveOS. The first start takes a few minutes, so give it time; you can unplug it now.`),
			h(
				"ul",
				{ class: "done-list" },
				rooted ? h("li", null, h("strong", null, "Root: "), "open the KernelSU Next app once the phone has started to finish setting it up.") : null,
				h("li", null, h("strong", null, "Keep the bootloader unlocked. "), "Locking it with ExpressiveOS installed stops the phone from starting."),
				h("li", null, h("strong", null, "Stuck on the boot animation for more than 15 minutes? "), "Hold Power and Volume down to get back to Fastboot Mode and install again with a clean install."),
			),
		];
		const actions = h("div", { class: "actions" });
		out.push(actions);
		void storedFile(name, rel.zip.size).then((f) => {
			if (f)
				actions.prepend(
					h(
						"button",
						{
							class: "btn btn-secondary",
							type: "button",
							on: {
								click: async (ev) => {
									(ev.currentTarget as HTMLButtonElement).disabled = true;
									await removeStored(name);
									this.zipFile = null;
									(ev.target as HTMLElement).textContent = "Download removed";
								},
							},
						},
						`Remove the download from this browser (${formatBytes(rel.zip.size)})`,
					),
				);
		});
		actions.append(
			h(
				"button",
				{
					class: "btn btn-quiet",
					type: "button",
					on: {
						click: () => {
							this.reached = 2;
							this.go("download");
						},
					},
				},
				"Install on another phone",
			),
		);
		return out;
	}
}
