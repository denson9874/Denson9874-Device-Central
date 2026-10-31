// The browser's Connector: restarts go through WebUSB, and when the phone comes back as a device
// the site may not use yet, the page shows a Reconnect button (the browser's chooser needs a click).

import type { Connector, Link } from "./device.ts";
import { Reconnector, UsbError, UsbTransport, requestPhone } from "./webusb.ts";

export async function linkTo(device: USBDevice): Promise<Link> {
	let last: unknown;
	// A phone that just came back can need a moment before it can be opened
	for (let i = 0; i < 6; i++) {
		try {
			const t = await UsbTransport.open(device);
			return { transport: t, serial: device.serialNumber ?? "", close: () => t.close() };
		} catch (e) {
			last = e;
			await new Promise((r) => setTimeout(r, 1000));
		}
	}
	throw last;
}

function waitForDisconnect(device: USBDevice, timeoutMs: number): { promise: Promise<boolean>; cancel(): void } {
	let cancel = () => {};
	const promise = new Promise<boolean>((resolve) => {
		const onDisconnect = (ev: USBConnectionEvent) => {
			if (ev.device === device) finish(true);
		};
		const poll = setInterval(async () => {
			const list = await navigator.usb.getDevices().catch(() => null);
			if (list && !list.includes(device)) finish(true);
		}, 500);
		const timer = setTimeout(() => finish(false), timeoutMs);
		const finish = (gone: boolean) => {
			clearInterval(poll);
			clearTimeout(timer);
			navigator.usb.removeEventListener("disconnect", onDisconnect);
			resolve(gone);
		};
		cancel = () => finish(false);
		navigator.usb.addEventListener("disconnect", onDisconnect);
	});
	return { promise, cancel };
}

export interface ReconnectUi {
	/** Show or hide the "Reconnect" prompt. */
	needsReconnect(show: boolean): void;
	/** The phone is restarting (true) or back (false). */
	restarting(on: boolean): void;
}

export class WebUsbConnector implements Connector {
	private reconnector = new Reconnector();

	constructor(private readonly ui: ReconnectUi) {}

	async restart(link: Link, send: () => Promise<void>, signal?: AbortSignal): Promise<Link> {
		const device = (link.transport as UsbTransport).device;
		const gone = waitForDisconnect(device, 30_000);
		this.ui.restarting(true);
		try {
			try {
				await send();
			} catch (e) {
				gone.cancel();
				throw e;
			}
			await link.close();
			if (!(await gone.promise)) throw new UsbError("The phone didn't restart. Unplug it, check it shows Fastboot Mode, plug it back in and try again.");
			const android = typeof navigator !== "undefined" && /Android/i.test(navigator.userAgent);
			const d = await this.reconnector.wait(link.serial, {
				timeoutMs: 3 * 60_000,
				// Chrome on Android can't recognise the phone again without the user picking it
				needsUserAfterMs: android ? 0 : 20_000,
				needsUser: () => this.ui.needsReconnect(true),
				signal,
			});
			this.ui.needsReconnect(false);
			return await linkTo(d);
		} finally {
			this.ui.needsReconnect(false);
			this.ui.restarting(false);
		}
	}

	async release(link: Link, send: () => Promise<void>): Promise<void> {
		try {
			await send();
		} finally {
			await link.close();
		}
	}

	/** The Reconnect button: the user picks the phone in the browser's chooser. */
	async pick(): Promise<void> {
		const d = await requestPhone();
		if (!this.reconnector.offer(d)) throw new UsbError("That isn't the phone being installed, or it isn't in Fastboot Mode yet. Choose it again.");
	}
}
