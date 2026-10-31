// navigator.usb for the browser tests: the simulated Pixel (test/fake-phone.ts) behind WebUSB's
// API. A restart drops the device and brings it back as a new USBDevice a moment later; with
// window.__FAKE_OPTS__.askAgain set, the browser "forgets" it, as Chrome on Android does, so the
// page has to ask the user to pick it again.
//
// With __FAKE_OPTS__.android, the phone starts out running Android with USB debugging on: a
// composite device with an MTP and an ADB interface and a simulated adbd (test/fake-adb.ts), which
// asks "Allow USB debugging?" and has a simulated user answer it. reboot:bootloader takes it off
// USB, and it comes back in Fastboot Mode after restartMs as the fastboot phone, with the fastboot
// product id. As in Chrome, the site may use a device only once the user picked it (by product id
// and serial number), and only those are in getDevices() and its connect events: so the phone back
// in Fastboot Mode has to be chosen again unless it was chosen in Fastboot Mode before.

import { deviceByCodename } from "../src/devices.ts";
import { AdbKey, KEY_STORAGE_NAME } from "../src/adb/key.ts";
import { FakeAdbPhone, type FakeAdbUsbDevice } from "../test/fake-adb.ts";
import { FakePhone, type FakeOptions, type FakeTransport } from "../test/fake-phone.ts";

/** A phone that starts running Android with USB debugging on. */
interface AndroidOptions {
	/** This browser's key is allowed already: "Always allow from this computer" was ticked on an earlier visit. */
	allowed?: boolean;
	/** What the simulated user does when the phone asks "Allow USB debugging?" (default: Allow, with Always allow ticked). */
	answer?: "allow" | "always" | "deny" | "none";
	/** How long until they do. */
	answerDelayMs?: number;
	/** An adb server on the computer holds the ADB interface: claimInterface() fails as Chrome's does. */
	adbServer?: boolean;
}

declare global {
	interface Window {
		__FAKE_OPTS__?: FakeOptions & { askAgain?: boolean; restartMs?: number; noPhone?: boolean; msPerMiB?: number; android?: AndroidOptions };
		__fakePhone: FakePhone;
		/** The phone's adbd, while it starts out running Android. */
		__fakeAdb: FakeAdbPhone | null;
		__fakeUsbLog: string[];
	}
}

const opts = window.__FAKE_OPTS__ ?? {};
const phone = new FakePhone(opts);
window.__fakePhone = phone;
window.__fakeUsbLog = [];

const ENDPOINTS = [
	{ endpointNumber: 1, direction: "in", type: "bulk", packetSize: 512 },
	{ endpointNumber: 1, direction: "out", type: "bulk", packetSize: 512 },
];

class FakeDevice {
	readonly vendorId = 0x18d1;
	readonly productId = 0x4ee0;
	readonly productName = "Pixel 7 Pro";
	readonly manufacturerName = "Google";
	readonly serialNumber = phone.serial;
	opened = false;
	configuration: unknown = null;
	readonly configurations = [
		{
			configurationValue: 1,
			interfaces: [
				{
					interfaceNumber: 0,
					alternates: [{ alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x03, endpoints: ENDPOINTS }],
				},
			],
		},
	];
	gone = false;

	constructor(readonly transport: FakeTransport) {}

	async open() {
		if (this.gone) throw new DOMException("The device was disconnected.", "NotFoundError");
		this.opened = true;
	}
	async close() {
		this.opened = false;
	}
	async selectConfiguration() {
		this.configuration = this.configurations[0];
	}
	async claimInterface() {}
	async releaseInterface() {}
	async selectAlternateInterface() {}
	async clearHalt() {}
	async transferOut(_ep: number, data: BufferSource) {
		if (this.gone) throw new DOMException("The device was disconnected.", "NetworkError");
		const b = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
		// USB isn't instant: a pace per MiB of data, so the page's progress can be watched
		if (b.byteLength > 64 && opts.msPerMiB) await new Promise((r) => setTimeout(r, (b.byteLength / 1048576) * opts.msPerMiB!));
		await this.transport.send(b);
		return { status: "ok", bytesWritten: b.byteLength };
	}
	async transferIn(_ep: number, _len: number) {
		if (this.gone) throw new DOMException("The device was disconnected.", "NetworkError");
		const r = await this.transport.receive();
		maybeRestart(this);
		return { status: "ok", data: new DataView(r.buffer, r.byteOffset, r.byteLength) };
	}
}

type Plugged = FakeDevice | FakeAdbUsbDevice;
type Described = { configurations: Array<{ interfaces: Array<{ alternates: Array<{ interfaceClass: number; interfaceSubclass: number; interfaceProtocol: number }> }> }> };

const usb = new EventTarget() as EventTarget & Record<string, unknown>;
/** What the site may use, as Chrome keeps it: a device's product id and serial number. */
let permitted = new Set<string>();
const permit = (d: Plugged) => `${d.vendorId}:${d.productId}:${d.serialNumber}`;

function fire(type: "connect" | "disconnect", device: Plugged) {
	const ev = new Event(type) as Event & { device: Plugged };
	ev.device = device;
	usb.dispatchEvent(ev);
}

/** The phone, while it restarts: a chooser opened meanwhile shows it once it's back, and the user picks it then. */
let arriving: { promise: Promise<void>; resolve: () => void } | null = null;

function goingAway() {
	let resolve!: () => void;
	const promise = new Promise<void>((r) => (resolve = r));
	arriving = { promise, resolve };
}

/** The phone back on USB: the page hears of it only if it may use it. */
function plug(d: Plugged) {
	current = d;
	arriving?.resolve();
	arriving = null;
	if (permitted.has(permit(d))) fire("connect", d);
}

/** Whether the browser's chooser lists a device for these filters (the page's filter by interface). */
function listed(d: Plugged, filters: USBDeviceFilter[] | undefined): boolean {
	if (!filters?.length) return true;
	const alts = (d as unknown as Described).configurations.flatMap((c) => c.interfaces.flatMap((i) => i.alternates));
	return filters.some((f) =>
		alts.some(
			(a) =>
				(f.classCode === undefined || f.classCode === a.interfaceClass) &&
				(f.subclassCode === undefined || f.subclassCode === a.interfaceSubclass) &&
				(f.protocolCode === undefined || f.protocolCode === a.interfaceProtocol),
		),
	);
}

// ---- A phone that starts out running Android ----

/** The key the page made and kept for USB debugging, as the phone would have stored it. */
function pageKey(): string | null {
	try {
		const saved = localStorage.getItem(KEY_STORAGE_NAME);
		const key = saved ? AdbKey.fromJwk(JSON.parse(saved) as JsonWebKey) : null;
		return key ? btoa(String.fromCharCode(...key.androidPublicKey())) : null;
	} catch {
		return null;
	}
}

let adb: FakeAdbPhone | null = null;
if (opts.android) {
	const a = opts.android;
	adb = new FakeAdbPhone({
		serial: phone.serial,
		device: phone.product,
		model: deviceByCodename(phone.product)?.model ?? "Pixel",
		answer: a.answer ?? "always",
		answerDelayMs: a.answerDelayMs ?? 1500,
		claimError: a.adbServer ? new DOMException("Unable to claim interface.", "NetworkError") : undefined,
		rebootDelayMs: 100,
	});
	const phoneAdb = adb;
	// Allowed before this visit: the phone knows the key the page keeps, once there is one
	if (a.allowed) {
		phoneAdb.onMessage = (m) => {
			const key = m.command === "AUTH" && m.arg0 === 2 ? pageKey() : null;
			if (key) phoneAdb.trustedKeys.add(key);
			return false;
		};
	}
	phone.mode = "android";
	phoneAdb.onDisconnect = (d) => {
		if (phoneAdb.mode !== "bootloader") return;
		window.__fakeUsbLog.push("restart -> bootloader (from Android)");
		current = null;
		goingAway();
		fire("disconnect", d);
		setTimeout(() => {
			phone.mode = "bootloader";
			plug(new FakeDevice(phone.connect()));
		}, opts.restartMs ?? 1200);
	};
}
window.__fakeAdb = adb;

let current: Plugged | null = opts.noPhone ? null : adb ? adb.usb : new FakeDevice(phone.connect());

function maybeRestart(d: FakeDevice) {
	if (phone.mode !== "off" || d.gone) return;
	// The phone answered a reboot command: it drops off USB, and comes back in its new mode
	d.gone = true;
	window.__fakeUsbLog.push(`restart -> ${phone.nextMode}`);
	setTimeout(() => {
		current = null;
		// Chrome on Android forgets a phone that goes away
		if (opts.askAgain) permitted.delete(permit(d));
		goingAway();
		fire("disconnect", d);
		setTimeout(() => {
			phone.boot();
			if (phone.mode === "android") {
				arriving?.resolve();
				arriving = null;
				return;
			}
			plug(new FakeDevice(phone.connect()));
		}, opts.restartMs ?? 1200);
	}, 150);
}

Object.assign(usb, {
	async requestDevice(o?: USBDeviceRequestOptions) {
		await new Promise((r) => setTimeout(r, 50));
		if (!current && arriving) await arriving.promise;
		if (!current || !listed(current, o?.filters)) throw new DOMException("No device selected.", "NotFoundError");
		permitted.add(permit(current));
		return current;
	},
	async getDevices() {
		return current && permitted.has(permit(current)) ? [current] : [];
	},
});

Object.defineProperty(navigator, "usb", { value: usb, configurable: true });
// Plugging the phone in later (tests that start with none)
(window as unknown as { __plugIn: () => void }).__plugIn = () => {
	current = new FakeDevice(phone.connect());
	fire("connect", current);
};
// Forget what was allowed (a new visit)
(window as unknown as { __forget: () => void }).__forget = () => {
	permitted = new Set();
};
