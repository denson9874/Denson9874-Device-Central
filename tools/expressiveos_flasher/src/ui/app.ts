// The flasher's six steps: choose the phone, choose the build, download it, connect the phone,
// install, done. The Bloom stage beside them follows along.

import { type DeviceInfo, DEVICES, deviceByCodename } from "../devices.ts";
import { parseRequirements } from "../fastboot/android-info.ts";
import { FastbootClient, FastbootError, type LogKind, ProtocolError } from "../fastboot/client.ts";
import { Phone } from "../fastboot/device.ts";
import { FastbootInfoError } from "../fastboot/fastboot-info.ts";
import { logicalPartitions } from "../fastboot/lp.ts";
import { WebUsbConnector, linkTo } from "../fastboot/usb-connector.ts";
import { USB_DRIVER_URL, UsbError, UsbTransport, hostOs, isFastbootDevice, requestPhone, webUsbSupported } from "../fastboot/webusb.ts";
import { PlanError, type Step, buildPlan, describe } from "../flash/plan.ts";
import { type PhoneReport, type Problem, canUnlock, checkBeforeInstall, inspectPhone, plausibleProduct, reportProblems, unlockBootloader } from "../flash/preflight.ts";
import { type ImageSource, InstallError, runPlan, stepWeights } from "../flash/runner.ts";
import { type Release, ReleasesError, fetchReleases, fileUrl, formatBytes } from "../releases.ts";
import { type LetGo, StoreError, downloadRelease, fetchVerified, hashFile, listStored, openStored, partialSize, removeStored, storageSupported, storeName, storedFile } from "../store/store.ts";
import { ZipError, ZipReader } from "../zip/zip.ts";
import { BloomStage, bloomMark } from "./bloom.ts";
import { type Child, append, canFocus, focusKey, h, inside, link, notice, progressBar, setBar } from "./dom.ts";

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

/** The status's title and detail as one thing to say. */
function sentence(title: string, detail: string): string {
	if (!detail) return title;
	return /[.…!?]$/.test(title) ? `${title} ${detail}` : `${title}. ${detail}`;
}

/** A message over the step; one with a status is a failure, which the status and stage show too. */
interface Flash {
	message: string;
	kind: "danger" | "warn" | "ok" | "info";
	status?: string;
	/** A page that helps, shown as a link under the message. */
	help?: Help;
}

interface Help {
	href: string;
	text: string;
}

/**
 * A page that helps with a failure: the Google USB Driver, when Windows won't let the browser
 * open the phone (the message says to install it; the address is a link, not part of the text).
 */
function helpFor(e: unknown): Help | undefined {
	if (e instanceof UsbError && e.kind === "access" && hostOs() === "windows") return { href: USB_DRIVER_URL, text: "How to install the Google USB Driver" };
	return undefined;
}

const helpLink = (help: Help | undefined) => (help ? h("p", null, link(help.href, help.text)) : null);

/** The phone's answer for its model, when it isn't one, in words. */
const oddAnswer = (product: string | null) => (product ? `answered "${product}", which isn't a model name` : "didn't say which model it is");

const RESTART_INTO_FASTBOOT = "Restart it into Fastboot Mode by holding Power and Volume down until it restarts";

/** Why a phone may answer with something that isn't a model: only a shifted reply gives one. */
const heldAnswer = (product: string | null) => (product ? " It may still be holding the answer to an earlier command." : "");

/** What Linux needs before the browser may open the phone (openFailure in webusb.ts has the details). */
const LINUX_UDEV =
	"add a udev rule for Google's USB vendor id 18d1 (for example, install the android-udev-rules package), then unplug the phone and plug it back in.";

const stepIndex = (step: StepId) => STEPS.findIndex((s) => s.id === step);

/** The zip's android-info.txt, or null when it has none. */
async function readAndroidInfo(zipFile: File): Promise<string | null> {
	const zip = await ZipReader.open(zipFile);
	return zip.entry("android-info.txt") ? zip.text("android-info.txt") : null;
}

/** The download step's moving parts, which a running download or check updates. */
interface DownloadView {
	progress: HTMLElement;
	line: HTMLElement;
	actions: HTMLElement;
	/** "Remove older downloads", hidden while something runs. */
	older: HTMLElement;
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
	/** Lets go of the stored zip; while this tab holds it, no other tab removes it. */
	private zipHold: LetGo | null = null;
	private phone: Phone | null = null;
	private report: PhoneReport | null = null;
	/** The zip whose android-info.txt the report checked the phone against. */
	private reportZip: File | null = null;
	private connector: WebUsbConnector;
	private reconnectBox: HTMLElement | null = null;
	private flash: Flash | null = null;
	private flashBox: HTMLElement | null = null;
	/** The flash that was shown already, so drawing it again doesn't say it again. */
	private flashShown: Flash | null = null;
	/** The page's live region: what screen readers are told, a moment at a time. */
	private live: HTMLElement;
	/** What the live region says next (see say). */
	private saying: { flash: string | null; status: boolean; milestone: string | null; more: string[] } | null = null;
	private saidStatus = "";
	/** The phone check whose outcome was said. */
	private outcomeSaid: PhoneReport | null = null;
	/** A control the keyboard was on that its step draws again only a moment later (see resumeFocus). */
	private focusLater: string | null = null;
	private readonly testers = new URLSearchParams(location.search).has("testers");

	constructor() {
		this.panel = document.getElementById("panel")!;
		this.stepper = document.getElementById("stepper") as HTMLOListElement;
		this.statusTitle = document.getElementById("status-title")!;
		this.statusDetail = document.getElementById("status-detail")!;
		let live = document.getElementById("announce");
		if (!live) {
			live = h("div", { id: "announce", class: "sr-only", role: "status", "aria-live": "polite", "aria-atomic": "true" });
			document.body.append(live);
		}
		this.live = live;
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
					void this.dropPhone();
					if (this.step === "connect") this.flash = { kind: "warn", message: "The phone was unplugged. Plug it back in and connect again." };
					if (this.step === "connect" || this.step === "install") this.render();
					else this.renderStepper();
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

	/**
	 * The status under the flower. Screen readers are told of it too, unless it's `quiet`: the
	 * running percentages, which say only every 10% (milestones).
	 */
	private setStatus(title: string | null, detail?: string, quiet = false) {
		if (title !== null && this.statusTitle.textContent !== title) this.statusTitle.textContent = title;
		if (detail !== undefined && this.statusDetail.textContent !== detail) this.statusDetail.textContent = detail;
		if (!quiet) this.sayStatus();
	}

	/**
	 * Tells screen readers something, through the page's one live region (the status under the
	 * flower isn't one: it changes with every bit of progress). What comes up in the same moment is
	 * said together: a new message over the step, then the status as it stands (or else a running
	 * task's milestone), then the rest.
	 */
	private say(text: string) {
		this.queueSay().more.push(text);
	}

	/** Has the status said as it stands, if it changed since it was last said (see setStatus). */
	private sayStatus() {
		this.queueSay().status = true;
	}

	private queueSay() {
		if (!this.saying) {
			this.saying = { flash: null, status: false, milestone: null, more: [] };
			queueMicrotask(() => {
				const next = this.saying!;
				this.saying = null;
				const parts = [next.flash];
				const status = sentence(this.statusTitle.textContent ?? "", this.statusDetail.textContent ?? "");
				if (next.status && status !== this.saidStatus) {
					this.saidStatus = status;
					parts.push(status);
				} else {
					// A milestone is the status's percentage rounded down to 10%: said with the status,
					// which has the exact one, it would contradict it ("Installing 78%. … Installing 70%")
					parts.push(next.milestone);
				}
				const text = [...parts, ...next.more].filter(Boolean).join(" ");
				if (text && text !== this.live.textContent) this.live.textContent = text;
			});
		}
		return this.saying;
	}

	/**
	 * Says a running task's progress at each 10% it passes (the status shows all of it), unless the
	 * status is said at that moment anyway. Where it starts isn't said: the status says that.
	 */
	private milestones(what: string): (fraction: number) => void {
		let said: number | null = null;
		return (f) => {
			const tenth = Math.floor(f * 10);
			if (said === null) said = tenth;
			else if (tenth > said && tenth < 10) {
				said = tenth;
				this.queueSay().milestone = `${what} ${tenth * 10}%`;
			}
		};
	}

	/** The step's heading, which takes the keyboard when a step starts or its control is gone. */
	private heading(): HTMLElement | null {
		const h2 = this.panel.querySelector<HTMLElement>("h2");
		h2?.setAttribute("tabindex", "-1");
		return h2;
	}

	/** The control in the panel with this focusKey, if the keyboard can go to it. */
	private findControl(key: string): HTMLElement | null {
		for (const e of this.panel.querySelectorAll<HTMLElement>("*")) if (focusKey(e) === key && canFocus(e, this.panel)) return e;
		return null;
	}

	/**
	 * Changes the panel without losing the keyboard. It goes back to the same control when the
	 * change draws it again; else to the message given (what happened, so it's read out), or to the
	 * step's heading. A keyboard outside the panel stays where it is (something finishing in the
	 * background doesn't take it). Returns where the keyboard was put, if it was moved.
	 */
	private keepFocus(change: () => void, message: HTMLElement | null = null): HTMLElement | null {
		const was = document.activeElement;
		const inPanel = !!was && was !== this.panel && inside(was, this.panel);
		const key = inPanel ? focusKey(was!) : null;
		change();
		if (!inPanel || (document.activeElement === was && canFocus(was!, this.panel))) return null;
		const same = key === null ? null : this.findControl(key);
		if (!same && message) {
			// Read out when the keyboard lands on it, so not an alert as well
			message.setAttribute("tabindex", "-1");
			message.removeAttribute("role");
		}
		const to = same ?? message ?? this.heading();
		this.focusLater = same || message ? null : key;
		to?.focus({ preventScroll: true });
		return to;
	}

	/**
	 * The download step draws its buttons a moment after the rest of it: once they're there, the
	 * keyboard goes back to the control it was on, if it's still on the heading it was put on.
	 */
	private resumeFocus() {
		const key = this.focusLater;
		if (!key || document.activeElement !== this.panel.querySelector("h2")) return;
		const same = this.findControl(key);
		if (!same) return;
		this.focusLater = null;
		same.focus({ preventScroll: true });
	}

	private go(step: StepId) {
		// Whatever runs (a download, a check, the install) finishes on the step it started on
		if (this.busy) return;
		this.step = step;
		this.reached = Math.max(this.reached, stepIndex(step));
		this.flash = null;
		this.render("heading");
		if (window.matchMedia("(max-width: 860px)").matches) this.panel.scrollIntoView({ behavior: "smooth", block: "start" });
	}

	/**
	 * Keeps the stepper from opening the steps after this one until they're reached again: the
	 * zip they need is gone, or the phone hasn't passed the checks for it.
	 */
	private capReached(step: StepId) {
		this.reached = Math.min(this.reached, stepIndex(step));
	}

	private renderStepper() {
		const at = stepIndex(this.step);
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
						// A narrow stepper shows only the number of the steps you're not on (styles.css)
						h("span", { class: "step-label" }, h("span", { class: "step-num" }, `${i + 1}.`), " ", h("span", { class: "step-name" }, s.label)),
					),
				);
			}),
		);
	}

	/**
	 * Draws the step. A new step puts the keyboard on its heading; drawing the same step again
	 * keeps it on the control it was on (keepFocus).
	 */
	private render(focus: "keep" | "heading" = "keep") {
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
		// A flash is news once: drawn again (another choice on the step), it isn't alerted or said again
		const flash = this.flash;
		const fresh = !!flash && flash !== this.flashShown;
		this.flashShown = flash;
		const box = flash ? notice(flash.kind, null, flash.message, helpLink(flash.help)) : null;
		if (box && !fresh) box.removeAttribute("role");
		const draw = () => {
			this.panel.replaceChildren();
			this.flashBox = box;
			if (box) this.panel.append(box);
			append(this.panel, body);
			this.heading();
		};
		let focused: HTMLElement | null = null;
		if (focus === "heading") {
			draw();
			this.focusLater = null;
			focused = this.heading();
			focused?.focus({ preventScroll: true });
		} else {
			focused = this.keepFocus(draw, fresh ? box : null);
		}
		// A danger notice is an alert; the others are said, unless the keyboard went to them
		if (flash && fresh && flash.kind !== "danger" && focused !== box) this.queueSay().flash = flash.message;
		// A failure keeps its status and the stage's colour until the user moves on
		if (this.flash?.status && !this.busy) {
			this.bloom.setMode("error");
			this.setStatus(this.flash.status, "");
		}
	}

	private flashMessage(kind: "danger" | "warn" | "ok" | "info", message: string) {
		this.flash = { kind, message };
		this.render();
	}

	/**
	 * Shows what went wrong over the step, with the status and the stage to match, and a link to
	 * what helps with `error` if there's one.
	 */
	private fail(status: string, message: string, error?: unknown) {
		this.flash = { kind: "danger", message, status, help: helpFor(error) };
		this.render();
	}

	/** Takes the message off the step (something new starts). */
	private clearFlash() {
		this.flash = null;
		this.flashBox?.remove();
		this.flashBox = null;
	}

	/**
	 * The zip the next steps use. A stored one comes held, so no other tab removes it meanwhile;
	 * the promise settles once the one before is let go of.
	 */
	private setZip(file: File | null, hold: LetGo | null = null): Promise<void> {
		const before = this.zipHold !== hold ? this.zipHold : null;
		this.zipFile = file;
		this.zipHold = hold;
		if (!file) this.capReached("download");
		return before ? before() : Promise.resolve();
	}

	/**
	 * Forgets the phone and what was checked on it, and closes its connection (the promise is
	 * that). The stepper goes back to Connect.
	 */
	private dropPhone(): Promise<void> {
		const link = this.phone?.link;
		this.phone = null;
		this.report = null;
		this.reportZip = null;
		this.capReached("connect");
		return link ? link.close().catch(() => {}) : Promise.resolve();
	}

	/** The phone's report, if it was checked against the zip in hand. */
	private currentReport(): PhoneReport | null {
		return this.phone && this.report && this.zipFile && this.reportZip === this.zipFile ? this.report : null;
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
					link(USB_DRIVER_URL, "Google USB Driver"),
					" if the phone doesn't show up or won't connect.",
				),
				h("li", null, h("strong", null, "On Linux, "), LINUX_UDEV),
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
			void this.setZip(null);
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
			let product: string | null;
			const t = this.phone?.link.transport;
			if (this.phone && t instanceof UsbTransport && t.device === d) {
				// The phone this page is connected to already: closing a second link would close that one
				product = await this.phone.getVar("product");
			} else {
				const link = await linkTo(d);
				try {
					product = await new FastbootClient(link.transport).getVar("product");
				} finally {
					await link.close();
				}
			}
			const dev = deviceByCodename(product);
			this.busy = false;
			if (!dev) {
				this.flashMessage(
					"warn",
					plausibleProduct(product)
						? `This phone says it's "${product}", which ExpressiveOS isn't built for.`
						: // A phone still holding the reply to an earlier command (see reportProblems)
							`The phone gave an unexpected answer when asked for its model: it ${oddAnswer(product)}. ${RESTART_INTO_FASTBOOT}, then try again.`,
				);
				return;
			}
			this.selectDevice(dev);
			this.setStatus(`Found your ${dev.model}`, "Ready when you are");
			this.flashMessage("ok", `Found a ${dev.model} (${dev.codename}).`);
		} catch (e) {
			this.busy = false;
			this.fail("Couldn't read the phone", errorText(e), e);
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
					this.choice("release", `${r.channel}/${r.name}`, r === rel, () => this.pickRelease(r), [
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
							h(
								"span",
								{ class: "choice-meta" },
								"Root with KernelSU Next, plus susfs (root hiding) and Zygisk. A clean install sets them up during the first start, and they work after one restart.",
							),
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
		void this.setZip(null);
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
		const view: DownloadView = {
			progress: progressBar("Download"),
			line: h("p", { class: "status-detail", hidden: true }),
			actions: h("div", { class: "actions" }),
			older: h("p", { hidden: true }),
		};
		const { progress, line, actions, older } = view;
		progress.hidden = true;
		out.push(progress, line, actions, older);

		if (this.busy) return out; // a download is running and updates the elements below
		this.bloom.setMode("idle");
		// Not said yet: once the step knows whether the zip is here already (below), it says where it
		// ended up, so a finished download isn't heard as "Ready to download" and then corrected
		this.setStatus("Ready to download", formatBytes(rel.zip.size), true);

		const fileInput = h("input", {
			type: "file",
			accept: ".zip,application/zip",
			hidden: true,
			on: {
				change: () => {
					const f = fileInput.files?.[0];
					if (f) void this.useOwnZip(f, view);
				},
			},
		});

		void (async () => {
			// After render has put the elements above in the panel
			await Promise.resolve();
			const held = this.zipFile ? null : await openStored(name, rel.zip.size);
			if (this.step !== "download" || this.release !== rel || this.busy) {
				void held?.release();
				return;
			}
			if (held) {
				if (this.zipFile) void held.release();
				else void this.setZip(held.file, held.release);
			}
			// A failure shown over the step keeps its status and stage (render says it)
			const failed = !!this.flash?.status;
			if (this.zipFile) {
				if (!failed) {
					this.bloom.setMode("download");
					this.bloom.setProgress(1);
					this.setStatus("Downloaded and checked", formatBytes(rel.zip.size));
				}
				actions.before(notice("ok", "Downloaded and checked", `${rel.zip.file} matches its SHA-256.`));
				actions.replaceChildren(
					h("button", { class: "btn btn-primary btn-big", type: "button", dataset: { focus: "download" }, on: { click: () => this.go("connect") } }, "Continue"),
					h(
						"button",
						{
							class: "btn btn-quiet",
							type: "button",
							on: {
								click: async () => {
									if (this.busy) return;
									// This tab lets go of it first; another tab may still be using it
									await this.setZip(null);
									if (!(await removeStored(name).catch(() => false))) {
										this.flash = { kind: "warn", message: "This download is in use in another tab or window, so it wasn't removed. Close that tab, then try again." };
									}
									this.render();
								},
							},
						},
						"Remove the download",
					),
					h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("build") } }, "Back"),
				);
				this.resumeFocus();
				return;
			}
			// Not downloaded: "Ready to download", or what was set since (Download paused), as it stands
			if (!failed) this.sayStatus();
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
			// Not the ones another tab is installing from or downloading
			const others = (await listStored()).filter((f) => f.name !== name && !f.name.startsWith(name) && !f.inUse);
			if (others.length && !this.busy) {
				const total = others.reduce((n, f) => n + f.size, 0);
				older.hidden = false;
				older.replaceChildren(
					h(
						"button",
						{
							class: "btn btn-quiet",
							type: "button",
							on: {
								click: async () => {
									if (this.busy) return;
									let kept = 0;
									for (const f of others) if (!(await removeStored(f.name).catch(() => false))) kept++;
									if (kept) {
										this.flash = {
											kind: "warn",
											message: `${kept === 1 ? "One download is" : `${kept} downloads are`} in use in another tab or window, so ${kept === 1 ? "it was" : "they were"} kept.`,
										};
									}
									this.render();
								},
							},
						},
						`Remove ${others.length === 1 ? "an older download" : `${others.length} older downloads`} (${formatBytes(total)})`,
					),
				);
			}
			if (partial > 0) {
				line.hidden = false;
				line.textContent = `${formatBytes(partial)} of ${formatBytes(rel.zip.size)} downloaded earlier. It picks up where it stopped.`;
				progress.hidden = false;
				setBar(progress, partial / rel.zip.size);
				if (!failed) {
					this.bloom.setMode("download");
					this.bloom.setProgress(partial / rel.zip.size);
				}
			}
			actions.replaceChildren(
				h(
					"button",
					{ class: "btn btn-primary btn-big", type: "button", dataset: { focus: "download" }, on: { click: () => void this.startDownload(view) } },
					partial > 0 ? "Resume download" : "Download",
				),
				h("button", { class: "btn btn-secondary", type: "button", dataset: { focus: "own-zip" }, on: { click: () => fileInput.click() } }, "Use a zip I already have"),
				h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("build") } }, "Back"),
				fileInput,
			);
			this.resumeFocus();
		})();
		return out;
	}

	private async startDownload(view: DownloadView) {
		if (this.busy) return;
		const rel = this.release!;
		const dev = this.device!;
		const name = storeName(rel.zip.sha256, "zip");
		const ac = new AbortController();
		this.busy = true;
		this.clearFlash();
		this.renderStepper();
		this.awake.on();
		const speed = new Speed();
		const { progress, line, actions, older } = view;
		progress.hidden = false;
		line.hidden = false;
		older.hidden = true;
		this.bloom.setMode("download");
		// Pause takes Download's place, and the keyboard with it
		this.keepFocus(() =>
			actions.replaceChildren(
				h(
					"button",
					{
						class: "btn btn-secondary",
						type: "button",
						dataset: { focus: "download" },
						on: { click: () => ac.abort() },
					},
					"Pause",
				),
			),
		);
		this.setStatus("Starting the download…", "");
		// Each part is said when it starts, then every 10%
		let phase = "";
		const checked = this.milestones("Checking what's already here");
		const downloaded = this.milestones("Downloading");
		try {
			const held = await downloadRelease(
				fileUrl(dev.codename, rel, rel.zip.file),
				name,
				rel.zip.size,
				rel.zip.sha256,
				(p) => {
					const frac = p.total ? p.done / p.total : 0;
					const quiet = p.phase === phase;
					phase = p.phase;
					if (p.phase === "checking") {
						this.bloom.setMode("verify");
						this.setStatus(`Checking what's already here ${Math.floor(frac * 100)}%`, "Your earlier download is checked again before it continues", quiet);
						checked(frac);
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
					const pct = Math.floor(frac * 1000) / 10;
					this.setStatus(`Downloading ${pct.toFixed(1)}%`, bps > 0 ? `${(bps / 1024 / 1024).toFixed(1)} MB/s · ${duration((p.total - p.done) / bps)}` : "", quiet);
					downloaded(frac);
					line.textContent = `${formatBytes(p.done)} of ${formatBytes(p.total)}`;
					setBar(progress, frac, line.textContent);
				},
				ac.signal,
				(attempt) => this.setStatus(null, `The connection dropped; trying again (${attempt})…`),
			);
			this.busy = false;
			this.awake.off();
			// Only for the build and the step it started on
			if (this.release !== rel || this.step !== "download") {
				void held.release();
				this.renderStepper();
				return;
			}
			void this.setZip(held.file, held.release);
			this.bloom.setMode("download");
			this.bloom.setProgress(1);
			for (let i = 0; i < 4; i++) setTimeout(() => this.bloom.pulse(i), i * 180);
			this.render();
		} catch (e) {
			this.busy = false;
			this.awake.off();
			if (this.release !== rel || this.step !== "download") {
				this.renderStepper();
				return;
			}
			if (e instanceof StoreError && e.code === "cancelled") {
				this.render();
				this.setStatus("Download paused", "Resume whenever you like");
				return;
			}
			this.fail("The download stopped", errorText(e));
		}
	}

	private async useOwnZip(f: File, view: DownloadView) {
		if (this.busy) return;
		const rel = this.release!;
		this.clearFlash();
		if (f.size !== rel.zip.size) {
			this.fail("That zip doesn't match", `That file isn't ${rel.zip.file}: it's ${formatBytes(f.size)}, not ${formatBytes(rel.zip.size)}.`);
			return;
		}
		// Checking 6 GB takes a while: the step shows it and nothing else can start meanwhile
		const ac = new AbortController();
		this.busy = true;
		this.renderStepper();
		this.awake.on();
		this.bloom.setMode("verify");
		const { progress, line, actions, older } = view;
		progress.hidden = false;
		progress.setAttribute("aria-label", "Checking your zip");
		setBar(progress, 0);
		line.hidden = false;
		line.textContent = `Checking ${f.name} against the build's SHA-256`;
		older.hidden = true;
		// Cancel takes the place of "Use a zip I already have", and the keyboard with it
		this.keepFocus(() =>
			actions.replaceChildren(h("button", { class: "btn btn-secondary", type: "button", dataset: { focus: "own-zip" }, on: { click: () => ac.abort() } }, "Cancel")),
		);
		this.setStatus("Checking your zip…", "Comparing its SHA-256 with the build's");
		const checked = this.milestones("Checking your zip");
		let sha: string | null = null;
		let error: unknown = null;
		try {
			sha = await hashFile(
				f,
				(p) => {
					const frac = p.total ? p.done / p.total : 0;
					this.bloom.setProgress(frac);
					setBar(progress, frac);
					this.setStatus(`Checking your zip ${Math.floor(frac * 100)}%`, "Comparing its SHA-256 with the build's", true);
					checked(frac);
				},
				ac.signal,
			);
		} catch (e) {
			error = e;
		}
		this.busy = false;
		this.awake.off();
		// The answer is about the build it was checked against, on this step
		if (this.release !== rel || this.step !== "download") {
			this.renderStepper();
			return;
		}
		if (error instanceof StoreError && error.code === "cancelled") this.render();
		else if (error) this.fail("Couldn't check your zip", errorText(error));
		else if (sha !== rel.zip.sha256) this.fail("That zip doesn't match", `That file isn't ${rel.zip.file} (its SHA-256 is different). Download the build here instead.`);
		else {
			void this.setZip(f);
			this.render();
		}
	}

	// ---------- 4. Connect ----------

	private connectStep(): Child[] {
		const dev = this.device!;
		const out: Child[] = [h("h2", null, "Connect your phone")];
		if (!this.zipFile) {
			// The phone is checked against the build's android-info.txt, so the build comes first
			if (!this.busy) {
				this.bloom.setMode("idle");
				this.setStatus("Connect your phone", "Once the build is downloaded");
			}
			out.push(
				notice("warn", null, "Download the build first. The phone is checked against it before anything is written."),
				h("div", { class: "actions" }, h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("download") } }, "Download the build")),
			);
			return out;
		}
		const r = this.currentReport();
		if (this.phone && !r) {
			// The build changed since the phone was checked: check it again, against this one
			if (!this.busy) void this.recheck();
			out.push(h("p", { class: "lead" }, "Checking the connected phone against this build…"));
			return out;
		}
		if (!this.busy) {
			this.bloom.setProgress(1);
			if (!r) {
				this.bloom.setMode("idle");
				this.setStatus("Connect your phone", "In fastboot mode, over USB");
			}
		}
		if (!this.phone || !r) {
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
				...this.connectHelp(),
			);
			return out;
		}
		const product = r.product ?? "unknown";
		const problems = reportProblems(r, dev.codename);
		// Its other answers can't be trusted either, so they aren't shown
		const unexpected = problems.some((p) => p.kind === "unexpected");
		const odd = this.unreadable(r);
		if (!this.busy) {
			this.bloom.setMode(problems.length ? "error" : "idle");
			if (unexpected) this.setStatus("The phone gave an unexpected answer", "Restart it into Fastboot Mode, then connect again");
			else this.setStatus(problems.length ? "This phone can't take the build" : "Phone connected", `${deviceByCodename(product)?.model ?? product} · ${r.serial ?? ""}`);
			// What the check found is said once, after the status: the notices below aren't live
			// regions (the problems are alerts, so they need nothing more)
			if (this.outcomeSaid !== r) {
				this.outcomeSaid = r;
				if (!problems.length) {
					const skipped = odd.length
						? ` ${odd.length === 1 ? "One line" : `${odd.length} lines`} of the build's android-info.txt couldn't be read, so ${odd.length === 1 ? "it was" : "they were"} skipped, as fastboot does.`
						: "";
					this.say(`${r.unlocked === false ? "Its bootloader is locked. Unlocking it erases everything on the phone." : "It passed the checks and is ready for the install."}${skipped}`);
				}
			}
		}
		if (unexpected) {
			out.push(
				...this.problemNotices(problems),
				h(
					"div",
					{ class: "actions" },
					h("button", { class: "btn btn-secondary", type: "button", disabled: this.busy, on: { click: () => void this.disconnect() } }, "Disconnect"),
					h("button", { class: "btn btn-quiet", type: "button", disabled: this.busy, on: { click: () => this.go("download") } }, "Back"),
				),
			);
			return out;
		}
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
			odd.length ? this.unreadableNotice(odd) : null,
		);
		if (problems.length) {
			out.push(...this.problemNotices(problems));
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
				h("button", { class: "btn btn-quiet", type: "button", on: { click: () => this.go("download") } }, "Back"),
			),
		);
		return out;
	}

	/** What to try when the phone isn't in the browser's list, or is and won't connect. */
	private connectHelp(): Child[] {
		if (isAndroid()) {
			return [
				h("p", { class: "status-detail" }, "Phone not in the list? Check that it shows Fastboot Mode, and try another cable or adapter."),
				h("p", { class: "status-detail" }, "In the list but won't connect? Unplug it, plug it back in and connect again, and allow Chrome to use it when Android asks."),
			];
		}
		return [
			h(
				"p",
				{ class: "status-detail" },
				"Phone not in the list? Check that it shows Fastboot Mode, and try another cable or port. On Windows, install the ",
				link(USB_DRIVER_URL, "Google USB Driver"),
				`. On Linux, ${LINUX_UDEV}`,
			),
			h(
				"p",
				{ class: "status-detail" },
				"In the list but won't connect? Without the Google USB Driver on Windows, or the udev rule on Linux, the browser can list the phone but can't open it. " +
					"Close any other program using the phone, such as a terminal running adb or fastboot, and any other tab using it. " +
					"After that, unplug the phone, plug it back in and connect again.",
			),
		];
	}

	/** android-info.txt's lines that can't be read, when the phone is the build's model. */
	private unreadable(r: PhoneReport): string[] {
		return r.product === this.device?.codename ? r.requirementErrors : [];
	}

	/** The lines of android-info.txt that can't be read: a warning, as in fastboot, not a refusal. */
	private unreadableNotice(lines: string[]): HTMLElement {
		return notice(
			"warn",
			lines.length === 1 ? "A line of the build's android-info.txt can't be read" : "Some lines of the build's android-info.txt can't be read",
			"Google's fastboot tool skips lines like these, and so does this page. The phone was checked against all the other lines.",
			h("ul", null, ...lines.map((l) => h("li", null, h("code", null, l)))),
		);
	}

	/** Why the connected phone can't take this build, as the connect step shows it. */
	private problemNotices(problems: Problem[]): Child[] {
		const dev = this.device!;
		const out: Child[] = [];
		const lines: Child[] = [];
		for (const p of problems) {
			if (p.kind === "unexpected") {
				out.push(
					notice(
						"danger",
						"The phone gave an unexpected answer",
						`Asked for its model, the phone ${oddAnswer(p.product)}.${heldAnswer(p.product)} ${RESTART_INTO_FASTBOOT}, then connect again.`,
					),
				);
			} else if (p.kind === "product") {
				const other = deviceByCodename(p.product);
				out.push(
					notice(
						"danger",
						"That's a different phone",
						other
							? `This is a ${other.model} (${other.codename}), and the build is for the ${dev.model}. Go back and choose the ${other.model}, or connect your ${dev.model}.`
							: `This phone says it's "${p.product ?? "unknown"}", and the build is for the ${dev.model} (${dev.codename}).`,
					),
				);
			} else if (p.kind === "requirement") {
				lines.push(h("li", null, this.problemText(p)));
			} else {
				out.push(notice("danger", null, this.problemText(p)));
			}
		}
		if (lines.length) out.push(notice("danger", "The build's android-info.txt doesn't accept this phone", h("ul", null, ...lines)));
		return out;
	}

	private problemText(p: Problem): string {
		const dev = this.device!;
		switch (p.kind) {
			case "unexpected":
				return `The phone gave an unexpected answer when asked for its model: it ${oddAnswer(p.product)}.${heldAnswer(p.product)} ${RESTART_INTO_FASTBOOT}, then connect again.`;
			case "product": {
				const other = deviceByCodename(p.product);
				return other
					? `This is a ${other.model} (${other.codename}), and the build is for the ${dev.model}.`
					: `This phone says it's "${p.product ?? "unknown"}", and the build is for the ${dev.model} (${dev.codename}).`;
			}
			case "no-android-info":
				return "The build has no android-info.txt, so there's no way to check it's for this phone.";
			case "requirement": {
				const f = p.result;
				return `${f.requirement.name} must ${f.requirement.invert ? "not " : ""}be ${f.requirement.options.join(" or ")}; the phone says ${f.value ?? "nothing"}.`;
			}
			case "locked":
				return "The bootloader is locked.";
		}
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
		if (this.busy || !this.zipFile) return;
		let device: USBDevice;
		try {
			// A phone this site may already use is taken without asking again
			const known = (await navigator.usb.getDevices()).filter(isFastbootDevice);
			device = known.length === 1 ? known[0] : await requestPhone();
		} catch (e) {
			if (!(e instanceof UsbError)) this.fail("Couldn't connect", errorText(e), e);
			return;
		}
		if (this.busy) return;
		const closing = this.dropPhone();
		this.flash = null;
		this.busy = true;
		this.render();
		this.setStatus("Connecting…", "");
		try {
			await closing;
			const link = await linkTo(device);
			const phone = new Phone(link, this.connector, this.logger);
			this.phone = phone;
			await this.inspect(phone);
			this.busy = false;
			this.render();
		} catch (e) {
			// The phone may be part way through a command. Its connection is closed before anything
			// else can open it: a close that landed after the next open would take that one down, and
			// a read left waiting would take the next reply.
			await this.dropPhone();
			this.busy = false;
			this.fail("Couldn't connect", errorText(e), e);
		}
	}

	/** Reads the phone and checks it against the zip in hand's android-info.txt. */
	private async inspect(phone: Phone) {
		const zipFile = this.zipFile;
		const report = await inspectPhone(phone, zipFile ? await readAndroidInfo(zipFile) : null);
		if (this.phone !== phone) return;
		this.report = report;
		this.reportZip = zipFile;
		// Install opens again only from a report that passes, with Continue
		this.capReached("connect");
	}

	/** Checks the connected phone again, against the zip now in hand. */
	private async recheck() {
		const phone = this.phone!;
		this.busy = true;
		this.renderStepper();
		this.setStatus("Checking your phone…", "");
		try {
			await this.inspect(phone);
			this.busy = false;
			this.render();
		} catch (e) {
			// Closed before anything else can open it, as in connect()
			await this.dropPhone();
			this.busy = false;
			this.fail("Couldn't read the phone", errorText(e), e);
		}
	}

	private async disconnect() {
		if (this.busy) return;
		await this.dropPhone();
		this.render();
	}

	private async unlock() {
		const phone = this.phone;
		if (this.busy || !phone) return;
		this.flash = null;
		this.busy = true;
		this.render();
		try {
			const able = await canUnlock(phone);
			if (able === false) {
				this.busy = false;
				this.fail(
					"OEM unlocking is off",
					"OEM unlocking is off. Start the phone, turn on OEM unlocking in Developer options (in Settings, under System), then restart into Fastboot Mode and connect again.",
				);
				return;
			}
			this.bloom.setMode("waiting");
			this.setStatus("Confirm on the phone", "Use the volume keys to choose Unlock the bootloader, then press Power");
			const result = await unlockBootloader(phone);
			if (result === "refused") {
				this.busy = false;
				this.bloom.setMode("idle");
				this.flashMessage("warn", "The phone didn't unlock (it was cancelled or refused). You can try again.");
				return;
			}
			// The phone erases itself and stays in Fastboot Mode; read its state again
			try {
				await this.inspect(phone);
			} catch {
				// Closed before anything else can open it, as in connect()
				await this.dropPhone();
				this.busy = false;
				this.flash = { kind: "info", message: "The bootloader is unlocked. Connect the phone again to go on." };
				this.render();
				return;
			}
			this.busy = false;
			this.flash = { kind: "ok", message: "The bootloader is unlocked." };
			this.render();
		} catch (e) {
			this.busy = false;
			this.fail("Couldn't unlock the bootloader", errorText(e));
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
		const r = this.currentReport();
		if (!r) {
			out.push(
				notice("warn", null, this.phone ? "The phone hasn't been checked against this build yet." : "The phone isn't connected any more."),
				h("div", { class: "actions" }, h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("connect") } }, "Connect the phone")),
			);
			return out;
		}
		if (reportProblems(r, dev.codename).length || r.unlocked === false) {
			out.push(
				notice("danger", null, "This phone can't take this build. Go back to Connect to see why."),
				h("div", { class: "actions" }, h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("connect") } }, "Back to Connect")),
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
				h("dd", null, `${dev.model} · ${r.serial ?? ""}`),
			),
			this.unreadable(r).length ? this.unreadableNotice(this.unreadable(r)) : null,
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
		if (this.busy) return;
		const phone = this.phone;
		const rel = this.release!;
		const dev = this.device!;
		const zipFile = this.zipFile;
		// A stale panel (the phone was unplugged meanwhile) shows what's missing instead
		if (!phone || !zipFile || !this.currentReport()) {
			this.render();
			return;
		}
		this.busy = true;
		this.awake.on();
		this.renderStepper();
		this.bloom.setMode("install");
		this.bloom.setProgress(0);
		this.setStatus("Getting ready…", "Reading the build");

		const list = h("ol", { class: "steps" });
		const bar = progressBar("Install");
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
		// The Install button is gone: the keyboard goes to the new heading
		this.keepFocus(() =>
			this.panel.replaceChildren(
				h("h2", null, "Installing ExpressiveOS"),
				h("p", { class: "lead" }, "Keep the phone plugged in and this tab open."),
				bar,
				this.reconnectBox!,
				list,
				h("details", { class: "log" }, h("summary", null, "Details"), pre),
			),
		);

		let steps: Step[];
		let images: ImageSource;
		try {
			const zip = await ZipReader.open(zipFile);
			const has = (n: string) => !!zip.entry(n);
			// The phone, checked again against this very zip's android-info.txt before anything is
			// written, as fastboot's flashall does: whatever Connect showed, this is what counts
			this.setStatus(null, "Checking the phone against the build");
			const info = has("android-info.txt") ? await zip.text("android-info.txt") : null;
			const problems = await checkBeforeInstall(phone, info, dev.codename);
			if (problems.length) {
				const why = problems.map((p) => this.problemText(p)).join(" ");
				// An unexpected answer says what it is itself: whether the phone can take the build isn't known
				this.installFailed(problems.some((p) => p.kind === "unexpected") ? why : `This phone can't take this build. ${why}`, null, false);
				return;
			}
			// fastboot says "android-info.txt syntax error" for these and goes on, as the install does
			for (const line of info ? parseRequirements(info).errors : []) this.logger("note", `android-info.txt syntax error, skipped: ${line}`);
			const fbInfo = has("fastboot-info.txt") ? await zip.text("fastboot-info.txt") : null;
			const logical = has("super_empty.img") ? logicalPartitions(await zip.bytes("super_empty.img", 16 * 1024 * 1024)) : null;
			// A build without a stock init_boot has no root: its zip's own init_boot is the stock one
			steps = buildPlan(fbInfo, has, logical, { wipe: this.wipe, root: this.root || !rel.initBootStock, hasStockInitBoot: !!rel.initBootStock });
			let stock: Blob | null = null;
			if (steps.some((s) => s.kind === "flash" && s.image.kind === "stock-init-boot")) {
				this.setStatus(null, "Downloading the stock init_boot");
				const sib = rel.initBootStock!;
				stock = await fetchVerified(fileUrl(dev.codename, rel, sib.file), sib.size, sib.sha256);
			}
			images = {
				image: async (ref) => (ref.kind === "zip" ? zip.blob(ref.name) : stock!),
				superEmpty: () => zip.blob("super_empty.img"),
				size: (ref) => (ref.kind === "zip" ? (zip.entry(ref.name)?.size ?? 0) : (rel.initBootStock?.size ?? 0)),
			};
		} catch (e) {
			this.installFailed(e instanceof ZipError || e instanceof PlanError || e instanceof FastbootInfoError ? `The build can't be installed: ${e.message}` : this.explain(e), null, false, e);
			return;
		}

		const rows = steps.map((s) => {
			const note = h("span", { class: "step-note" });
			// The dot's colour, in words
			const state = h("span", { class: "sr-only" });
			const li = h("li", null, h("span", { class: "dot", "aria-hidden": "true" }), h("span", null, describe(s), state), note);
			list.append(li);
			return { li, note, state };
		});
		const showState = (i: number, state: "running" | "done" | "skipped" | "failed") => {
			const row = rows[i];
			row.li.className = `is-${state}`;
			row.state.textContent = state === "running" ? " (in progress)" : state === "done" ? " (done)" : state === "failed" ? " (failed)" : "";
			if (state === "running") row.li.setAttribute("aria-current", "step");
			else row.li.removeAttribute("aria-current");
		};
		const weights = stepWeights(steps, images);
		const total = weights.reduce((a, b) => a + b, 0);
		const before = weights.map((_, i) => weights.slice(0, i).reduce((a, b) => a + b, 0));
		let current = 0;
		let shown = 0;
		const installed = this.milestones("Installing");
		const setOverall = (f: number) => {
			const v = Math.max(shown, Math.min(1, f));
			shown = v;
			this.bloom.setProgress(v);
			setBar(bar, v);
			// Each step's name is said as it starts (below), and the whole every 10%
			this.setStatus(`Installing ${Math.floor(v * 100)}%`, undefined, true);
			installed(v);
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
						showState(i, state);
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
			if (e instanceof InstallError) showState(e.stepIndex, "failed");
			this.installFailed(this.explain(cause), e instanceof InstallError ? describe(e.step) : null, true, cause);
			return;
		}
		this.busy = false;
		this.awake.off();
		void this.dropPhone();
		this.go("done");
	}

	private explain(e: unknown): string {
		if (e instanceof FastbootError) {
			if (/lock/i.test(e.reply)) return `${e.message}. The bootloader may be locked; connect again to check.`;
			return e.message;
		}
		if (e instanceof ProtocolError || e instanceof UsbError) return `${e.message}`;
		// What to do next is under it (installFailed): the phone has to be restarted first
		if (e instanceof DOMException && e.name === "NetworkError") return "The USB connection to the phone was lost. Check the cable.";
		return errorText(e);
	}

	/**
	 * @param wrote whether anything may have been written to the phone
	 * @param cause what went wrong, for a link to what helps with it
	 */
	private installFailed(message: string, step: string | null, wrote = true, cause: unknown = null) {
		// Read before the phone is dropped. A session that broke part way (USB failed, or a reply
		// never came) may have left the phone in the middle of a command, and where the browser can't
		// reset USB (Chrome on Windows) only a restart clears that.
		const broken = !!this.phone?.client.isBroken;
		this.busy = false;
		this.awake.off();
		this.bloom.setMode("error");
		this.setStatus(wrote ? "The install stopped" : "The install didn't start", step ?? "");
		// The connection may be gone; the next try connects afresh
		void this.dropPhone();
		this.renderStepper();
		// A reply that never came already says to restart the phone (client.ts's timeout message)
		const toldToRestart = /Restart it into Fastboot Mode/.test(message);
		let next: string;
		if (wrote && broken && toldToRestart) {
			next = "Nothing is lost by trying again, and the phone won't start ExpressiveOS until an install finishes.";
		} else if (broken && toldToRestart) {
			next = "Nothing was written to the phone.";
		} else if (wrote && broken) {
			next =
				"Restart the phone into Fastboot Mode first: hold Power and Volume down until it restarts. Then connect it and install again. Nothing is lost by trying again, and the phone won't start ExpressiveOS until an install finishes.";
		} else if (wrote) {
			next =
				"Nothing is lost by trying again: put the phone in Fastboot Mode if it isn't (hold Power and Volume down), connect it and install again. The phone won't start ExpressiveOS until an install finishes.";
		} else if (broken) {
			next = "Nothing was written to the phone. Restart it into Fastboot Mode before you try again: hold Power and Volume down until it restarts.";
		} else {
			next = "Nothing was written to the phone.";
		}
		const box = notice("danger", step ? `Stopped at: ${step}` : "The install didn't start", message, helpLink(helpFor(cause)), next);
		const actions = h(
			"div",
			{ class: "actions" },
			h("button", { class: "btn btn-primary", type: "button", on: { click: () => this.go("connect") } }, "Try again"),
		);
		// The Reconnect button may have had the keyboard: it goes to what went wrong
		this.keepFocus(() => {
			this.showReconnect(false);
			this.panel.querySelector(".lead")?.after(box, actions);
		}, box);
	}

	// ---------- 6. Done ----------

	/**
	 * What a rooted install still needs, as the ROM sets it up (expressiveos-cheetah/ksu/README.md,
	 * ksu-firstboot.sh): on a new /data, KernelSU Next's first-boot services install ksud, turn on
	 * susfs auto-load and install NeoZygisk, and both work from the second boot. A /data that has
	 * booted before gets ksud and nothing else.
	 */
	private rootSetup(): string {
		if (this.wipe) {
			return "KernelSU Next sets itself up during the first start. Restart the phone once after setup, before signing in to banking or payment apps, so susfs (root hiding) and Zygisk are on. No app gets root until you allow it in the KernelSU Next app.";
		}
		return "If this phone already had root with ExpressiveOS, it carries on as before. If it didn't, KernelSU Next works, but susfs (root hiding) and Zygisk aren't set up yet: turn them on in the KernelSU Next app, then restart the phone.";
	}

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
				rooted ? h("li", null, h("strong", null, "Root: "), this.rootSetup()) : null,
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
									const btn = ev.currentTarget as HTMLButtonElement;
									btn.disabled = true;
									// This tab lets go of it first; another tab may still be using it
									await this.setZip(null);
									btn.textContent = (await removeStored(name).catch(() => false)) ? "Download removed" : "Another tab or window is using it, so it was kept";
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
							// Another phone: its install type is chosen again (keeping data is only for a
							// phone that runs ExpressiveOS already), and its log starts empty
							this.wipe = true;
							this.logLines = [];
							this.reached = stepIndex("build");
							this.go("build");
						},
					},
				},
				"Install on another phone",
			),
		);
		return out;
	}
}
