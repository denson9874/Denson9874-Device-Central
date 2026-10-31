// navigator.usb for the browser tests: the simulated Pixel (test/fake-phone.ts) behind WebUSB's
// API. A restart drops the device and brings it back as a new USBDevice a moment later; with
// window.__FAKE_OPTS__.askAgain set, the browser "forgets" it, as Chrome on Android does, so the
// page has to ask the user to pick it again.

import { FakePhone, type FakeOptions, type FakeTransport } from "../test/fake-phone.ts";

declare global {
	interface Window {
		__FAKE_OPTS__?: FakeOptions & { askAgain?: boolean; restartMs?: number; noPhone?: boolean; msPerMiB?: number };
		__fakePhone: FakePhone;
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

const usb = new EventTarget() as EventTarget & Record<string, unknown>;
let current: FakeDevice | null = opts.noPhone ? null : new FakeDevice(phone.connect());
let permitted = new Set<FakeDevice>();

function fire(type: "connect" | "disconnect", device: FakeDevice) {
	const ev = new Event(type) as Event & { device: FakeDevice };
	ev.device = device;
	usb.dispatchEvent(ev);
}

function maybeRestart(d: FakeDevice) {
	if (phone.mode !== "off" || d.gone) return;
	// The phone answered a reboot command: it drops off USB, and comes back in its new mode
	d.gone = true;
	window.__fakeUsbLog.push(`restart -> ${phone.nextMode}`);
	setTimeout(() => {
		current = null;
		fire("disconnect", d);
		setTimeout(() => {
			phone.boot();
			if (phone.mode === "android") return;
			const nd = new FakeDevice(phone.connect());
			current = nd;
			if (!opts.askAgain) permitted.add(nd);
			fire("connect", nd);
		}, opts.restartMs ?? 1200);
	}, 150);
}

Object.assign(usb, {
	async requestDevice() {
		await new Promise((r) => setTimeout(r, 50));
		if (!current) throw new DOMException("No device selected.", "NotFoundError");
		permitted.add(current);
		return current;
	},
	async getDevices() {
		return current && permitted.has(current) ? [current] : [];
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
