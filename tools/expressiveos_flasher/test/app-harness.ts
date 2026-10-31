// The page's App in Node: a small DOM (elements, text, events and the few selectors app.ts uses),
// the simulated Pixel (fake-phone.ts) behind stand-ins for WebUSB, and the browser's storage of
// downloads as a map. test/app.test.ts mocks the page's modules with what's here. A phone running
// Android (fake-adb.ts) can be plugged in as well: the page talks to it with the real ADB code.

import type { Transport } from "../src/fastboot/client.ts";
import type { Link } from "../src/fastboot/device.ts";
import type { Reconnector } from "../src/fastboot/webusb.ts";
import type { Release } from "../src/releases.ts";
import type { Held, Progress } from "../src/store/store.ts";
import type { FakeAdbUsbDevice } from "./fake-adb.ts";
import type { FakePhone, FakeTransport } from "./fake-phone.ts";

// ---------- DOM ----------

export class FakeNode extends EventTarget {
	parentNode: FakeElement | null = null;

	get textContent(): string {
		return "";
	}

	set textContent(_v: string) {}

	remove() {
		this.parentNode?.detach(this);
	}

	before(...nodes: Array<FakeNode | string>) {
		this.parentNode?.insert(this.parentNode.childNodes.indexOf(this), nodes);
	}

	after(...nodes: Array<FakeNode | string>) {
		this.parentNode?.insert(this.parentNode.childNodes.indexOf(this) + 1, nodes);
	}
}

export class FakeText extends FakeNode {
	constructor(public data: string) {
		super();
	}

	override get textContent() {
		return this.data;
	}

	override set textContent(v: string) {
		this.data = v;
	}
}

type Compound = { tag?: string; id?: string; classes: string[]; attrs: Array<[string, string | null]> };

function parseSelector(sel: string): Compound[] {
	return sel
		.trim()
		.split(/\s+/)
		.map((part) => {
			const c: Compound = { classes: [], attrs: [] };
			for (const m of part.matchAll(/^([a-z][\w-]*)|\.([\w-]+)|#([\w-]+)|\[([\w-]+)(?:="?([^"\]]*)"?)?\]/gi)) {
				if (m[1]) c.tag = m[1].toLowerCase();
				else if (m[2]) c.classes.push(m[2]);
				else if (m[3]) c.id = m[3];
				else c.attrs.push([m[4], m[5] ?? null]);
			}
			return c;
		});
}

export class FakeElement extends FakeNode {
	childNodes: FakeNode[] = [];
	className = "";
	id = "";
	dataset: Record<string, string> = {};
	style: Record<string, string> = {};
	hidden = false;
	disabled = false;
	checked = false;
	value = "";
	files: File[] | null = null;
	scrollTop = 0;
	scrollHeight = 0;
	offsetWidth = 0;
	private attrs = new Map<string, string>();

	constructor(readonly tagName: string) {
		super();
	}

	readonly classList = {
		add: (...c: string[]) => (this.className = [...new Set([...this.classNames(), ...c])].join(" ")),
		remove: (...c: string[]) => (this.className = this.classNames().filter((x) => !c.includes(x)).join(" ")),
		toggle: (c: string, on?: boolean) => {
			const has = this.classNames().includes(c);
			if (on ?? !has) this.classList.add(c);
			else this.classList.remove(c);
		},
		contains: (c: string) => this.classNames().includes(c),
	};

	private classNames() {
		return this.className.split(/\s+/).filter(Boolean);
	}

	get children(): FakeElement[] {
		return this.childNodes.filter((n): n is FakeElement => n instanceof FakeElement);
	}

	get firstElementChild() {
		return this.children[0] ?? null;
	}

	get firstChild() {
		return this.childNodes[0] ?? null;
	}

	override get textContent(): string {
		return this.childNodes.map((n) => n.textContent).join("");
	}

	override set textContent(v: string) {
		this.replaceChildren(v);
	}

	insert(at: number, nodes: Array<FakeNode | string>) {
		const list = nodes.map((n) => (typeof n === "string" ? new FakeText(n) : n));
		for (const n of list) n.remove();
		this.childNodes.splice(at < 0 ? this.childNodes.length : at, 0, ...list);
		for (const n of list) n.parentNode = this;
	}

	detach(n: FakeNode) {
		const i = this.childNodes.indexOf(n);
		if (i >= 0) this.childNodes.splice(i, 1);
		n.parentNode = null;
	}

	append(...nodes: Array<FakeNode | string>) {
		this.insert(this.childNodes.length, nodes);
	}

	prepend(...nodes: Array<FakeNode | string>) {
		this.insert(0, nodes);
	}

	replaceChildren(...nodes: Array<FakeNode | string>) {
		for (const n of [...this.childNodes]) this.detach(n);
		this.append(...nodes);
	}

	setAttribute(k: string, v: string) {
		this.attrs.set(k, v);
		if (k === "id") this.id = v;
	}

	getAttribute(k: string) {
		if (k === "id") return this.id || null;
		return this.attrs.get(k) ?? null;
	}

	removeAttribute(k: string) {
		this.attrs.delete(k);
	}

	focus() {}
	scrollIntoView() {}

	click() {
		if (!this.disabled) this.dispatchEvent(new Event("click"));
	}

	private matches(c: Compound): boolean {
		if (c.tag && this.tagName !== c.tag) return false;
		if (c.id && this.id !== c.id) return false;
		if (!c.classes.every((x) => this.classNames().includes(x))) return false;
		return c.attrs.every(([k, v]) => (v === null ? this.getAttribute(k) !== null : this.getAttribute(k) === v));
	}

	private *descendants(): Generator<FakeElement> {
		for (const c of this.children) {
			yield c;
			yield* c.descendants();
		}
	}

	querySelectorAll(sel: string): FakeElement[] {
		const chain = parseSelector(sel);
		const last = chain[chain.length - 1];
		return [...this.descendants()].filter((el) => {
			if (!el.matches(last)) return false;
			let i = chain.length - 2;
			for (let p = el.parentNode; p && i >= 0; p = p.parentNode) if (p.matches(chain[i])) i--;
			return i < 0;
		});
	}

	querySelector(sel: string): FakeElement | null {
		return this.querySelectorAll(sel)[0] ?? null;
	}
}

export interface Page {
	body: FakeElement;
	panel: FakeElement;
	stepper: FakeElement;
	statusTitle: FakeElement;
	statusDetail: FakeElement;
}

/** document, window, location and the page's skeleton (index.html's ids). */
export function fakeDom(): { globals: Record<string, unknown>; page: Page } {
	const make = (tag: string, id?: string) => {
		const e = new FakeElement(tag);
		if (id) e.id = id;
		return e;
	};
	const body = make("body");
	const panel = make("section", "panel");
	const stepper = make("ol", "stepper");
	const statusTitle = make("p", "status-title");
	const statusDetail = make("p", "status-detail");
	body.append(panel, stepper, statusTitle, statusDetail, make("div", "stage"), make("span", "brand-mark"), make("button", "theme-toggle"));
	const document = Object.assign(new EventTarget(), {
		body,
		documentElement: { dataset: {} as Record<string, string> },
		visibilityState: "visible",
		createElement: (tag: string) => new FakeElement(tag.toLowerCase()),
		createElementNS: (_ns: string, tag: string) => new FakeElement(tag),
		getElementById: (id: string) => body.querySelector(`#${id}`),
	});
	const window = Object.assign(new EventTarget(), { matchMedia: () => ({ matches: false }) });
	return {
		globals: { document, window, Node: FakeNode, location: { search: "" }, CSS: { escape: (s: string) => s }, matchMedia: window.matchMedia },
		page: { body, panel, stepper, statusTitle, statusDetail },
	};
}

/** The buttons in an element, by their text. */
export function buttonsIn(root: FakeElement): string[] {
	return root.querySelectorAll("button").map((b) => b.textContent);
}

export function buttonIn(root: FakeElement, label: string | RegExp): FakeElement | null {
	return root.querySelectorAll("button").find((b) => (typeof label === "string" ? b.textContent === label : label.test(b.textContent))) ?? null;
}

// ---------- WebUSB ----------

/** A phone on USB: a new one each time the phone comes back from a restart, as with a real one. */
export class FakeUsbDevice {
	readonly vendorId = 0x18d1;
	readonly productId = 0x4ee0;
	/** Its fastboot interface, as webusb.ts's isFastbootDevice and the browser's chooser see it. */
	readonly configurations = [
		{
			configurationValue: 1,
			interfaces: [
				{
					interfaceNumber: 0,
					alternates: [
						{
							alternateSetting: 0,
							interfaceClass: 0xff,
							interfaceSubclass: 0x42,
							interfaceProtocol: 0x03,
							endpoints: [
								{ endpointNumber: 1, direction: "in", type: "bulk" },
								{ endpointNumber: 1, direction: "out", type: "bulk" },
							],
						},
					],
				},
			],
		},
	];
	opened = false;
	/** Its connections closed by the page (once each close has finished). */
	closes = 0;
	/** Holds each close of a connection until it settles (a slow USB close). */
	closeGate: Promise<void> | null = null;
	/** What opening it throws (the computer won't let the browser have it, say). */
	openError: unknown = null;
	transports: FakeUsbTransport[] = [];

	constructor(readonly phone: FakePhone) {}

	get serialNumber() {
		return this.phone.serial;
	}
}

/** UsbTransport's stand-in: the page tells its phone's link apart by `device`. */
export class FakeUsbTransport implements Transport {
	constructor(
		readonly device: FakeUsbDevice,
		readonly inner: FakeTransport,
	) {}

	send(data: Uint8Array) {
		return this.inner.send(data);
	}

	receive(maxLength: number) {
		return (this.inner.receive as (n: number) => Promise<Uint8Array>).call(this.inner, maxLength);
	}
}

export const world = {
	/** The phone plugged in now, in Fastboot Mode. */
	device: null as FakeUsbDevice | null,
	/** The phone plugged in now, running Android with USB debugging on. */
	android: null as FakeAdbUsbDevice | null,
	/** Devices the page isn't allowed to use until the user picks them (getDevices leaves them out). */
	unpermitted: new WeakSet<object>(),
	/** How long the page waits for a phone back in Fastboot Mode before asking the user to choose it (Choose the phone again), and at all. */
	askAfterMs: 0,
	reconnectTimeoutMs: 5000,
	usb: new EventTarget(),
	bloom: null as FakeBloom | null,
	/** Finished downloads in the browser, by store name. */
	stored: new Map<string, File>(),
	/** What a press of Download gets. */
	download: (_name: string, _signal?: AbortSignal): Promise<File> => Promise.reject(new Error("no download")),
	/** What checking a zip the user picked gives (its SHA-256). */
	hash: (_f: File, _onProgress: (p: Progress) => void, _signal?: AbortSignal): Promise<string> => Promise.reject(new Error("no hash")),
	/** The stock init_boot of each release, by file name. */
	files: new Map<string, Uint8Array>(),
	releases: [] as Release[],
};

export function plugIn(phone: FakePhone): FakeUsbDevice {
	world.device = new FakeUsbDevice(phone);
	return world.device;
}

export function unplug() {
	const d = world.device;
	world.device = null;
	if (d) world.usb.dispatchEvent(Object.assign(new Event("disconnect"), { device: d }));
}

type Described = { configurations: Array<{ interfaces: Array<{ alternates: Array<{ interfaceClass: number; interfaceSubclass: number; interfaceProtocol: number }> }> }> };

/** Whether the browser's chooser lists a device for these filters (by interface, as the page's filters are). */
function listed(d: Described, filters: USBDeviceFilter[] | undefined): boolean {
	if (!filters?.length) return true;
	const alts = d.configurations.flatMap((c) => c.interfaces.flatMap((i) => i.alternates));
	return filters.some((f) =>
		alts.some(
			(a) =>
				(f.classCode === undefined || f.classCode === a.interfaceClass) &&
				(f.subclassCode === undefined || f.subclassCode === a.interfaceSubclass) &&
				(f.protocolCode === undefined || f.protocolCode === a.interfaceProtocol),
		),
	);
}

const plugged = () => [world.device, world.android].filter((d) => d !== null);

export function fakeNavigatorUsb() {
	world.usb = Object.assign(new EventTarget(), {
		getDevices: async () => plugged().filter((d) => !world.unpermitted.has(d)),
		// The chooser: the phone, if the filters list it, which the user picks (and so allows)
		requestDevice: async (o?: USBDeviceRequestOptions) => {
			const d = plugged().find((x) => listed(x as unknown as Described, o?.filters));
			if (!d) throw new DOMException("No device selected.", "NotFoundError");
			world.unpermitted.delete(d);
			return d;
		},
	});
	return world.usb;
}

export async function linkTo(device: FakeUsbDevice): Promise<Link> {
	if (device.openError) throw device.openError;
	const t = new FakeUsbTransport(device, device.phone.connect());
	device.transports.push(t);
	return {
		transport: t,
		serial: device.phone.serial,
		// Closing a USBDevice closes it for every link the page has on it
		close: async () => {
			await device.closeGate;
			device.closes++;
			for (const x of device.transports) x.inner.closed = true;
		},
	};
}

/**
 * WebUsbConnector's stand-in: restarts the simulated phone and connects to it again. A phone
 * restarted into Fastboot Mode over USB debugging is waited for with the page's own Reconnector,
 * on the fake navigator.usb, with world's timings.
 */
export class WebUsbConnector {
	private reconnector: Reconnector | null = null;

	constructor(private readonly ui: { needsReconnect(show: boolean): void }) {}

	async restart(link: Link, send: () => Promise<void>): Promise<Link> {
		const phone = (link.transport as FakeUsbTransport).device.phone;
		await send();
		await link.close();
		phone.boot();
		if (phone.mode === "android") throw new Error("the phone started Android instead of fastboot");
		return linkTo(plugIn(phone));
	}

	async release(link: Link, send: () => Promise<void>): Promise<void> {
		const phone = (link.transport as FakeUsbTransport).device.phone;
		await send();
		await link.close();
		phone.boot();
	}

	async waitForFastboot(serial: string, opts: { signal?: AbortSignal; timeoutMessage: string }): Promise<Link> {
		// Imported here: webusb.ts's mock imports this module
		const { Reconnector } = await import("../src/fastboot/webusb.ts");
		const r = (this.reconnector ??= new Reconnector());
		try {
			const d = await r.wait(serial, {
				timeoutMs: world.reconnectTimeoutMs,
				needsUserAfterMs: world.askAfterMs,
				needsUser: () => this.ui.needsReconnect(true),
				signal: opts.signal,
				timeoutMessage: opts.timeoutMessage,
			});
			this.ui.needsReconnect(false);
			return await linkTo(d as unknown as FakeUsbDevice);
		} finally {
			this.ui.needsReconnect(false);
		}
	}

	async pick() {
		const { Reconnector } = await import("../src/fastboot/webusb.ts");
		return (this.reconnector ??= new Reconnector()).pick();
	}
}

// ---------- The Bloom stage ----------

export class FakeBloom {
	mode = "idle";
	blooming = false;

	constructor() {
		world.bloom = this;
	}

	setMode(m: string) {
		this.mode = m;
		if (m !== "complete") this.blooming = false;
	}

	setProgress() {}
	setSpeed() {}
	pulse() {}

	celebrate() {
		this.setMode("complete");
		this.blooming = true;
	}
}

// ---------- Downloads in the browser ----------

export const store = {
	storageSupported: () => true,
	storedFile: async (name: string) => world.stored.get(name) ?? null,
	openStored: async (name: string): Promise<Held | null> => {
		const file = world.stored.get(name);
		return file ? { file, release: async () => {} } : null;
	},
	partialSize: async () => 0,
	listStored: async () => [],
	removeStored: async (name: string) => world.stored.delete(name) || true,
	downloadRelease: async (_url: string, name: string, _size: number, _sha: string, _p: unknown, signal?: AbortSignal): Promise<Held> => {
		const file = await world.download(name, signal);
		world.stored.set(name, file);
		return { file, release: async () => {} };
	},
	hashFile: (f: File, onProgress: (p: Progress) => void, signal?: AbortSignal) => world.hash(f, onProgress, signal),
	fetchVerified: async (url: string) => {
		const b = world.files.get(decodeURIComponent(url.split("/").pop()!));
		if (!b) throw new Error(`no ${url}`);
		return new Blob([b.slice()]);
	},
};
