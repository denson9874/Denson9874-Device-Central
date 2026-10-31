// WebUSB: finding a phone in fastboot mode, opening its fastboot interface, and finding it again
// after it restarts (bootloader <-> fastbootd), when it comes back as a new USB device.

import type { Transport } from "./client.ts";

export const FASTBOOT_FILTER: USBDeviceFilter = { classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03 };

export class UsbError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "UsbError";
	}
}

export function webUsbSupported(): boolean {
	return typeof navigator !== "undefined" && "usb" in navigator && !!navigator.usb;
}

interface FastbootInterface {
	configuration: number;
	interfaceNumber: number;
	alternate: number;
	epIn: number;
	epOut: number;
}

function findFastbootInterface(device: USBDevice): FastbootInterface | null {
	for (const conf of device.configurations) {
		for (const iface of conf.interfaces) {
			for (const alt of iface.alternates) {
				if (alt.interfaceClass !== 0xff || alt.interfaceSubclass !== 0x42 || alt.interfaceProtocol !== 0x03) continue;
				const bulkIn = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "in");
				const bulkOut = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "out");
				if (!bulkIn || !bulkOut) continue;
				return {
					configuration: conf.configurationValue,
					interfaceNumber: iface.interfaceNumber,
					alternate: alt.alternateSetting,
					epIn: bulkIn.endpointNumber,
					epOut: bulkOut.endpointNumber,
				};
			}
		}
	}
	return null;
}

export function isFastbootDevice(device: USBDevice): boolean {
	return findFastbootInterface(device) !== null;
}

/** An opened phone in fastboot mode. */
export class UsbTransport implements Transport {
	private constructor(
		readonly device: USBDevice,
		private readonly fb: FastbootInterface,
	) {}

	static async open(device: USBDevice): Promise<UsbTransport> {
		const fb = findFastbootInterface(device);
		if (!fb) throw new UsbError("This USB device isn't a phone in fastboot mode");
		try {
			if (!device.opened) await device.open();
			if (device.configuration?.configurationValue !== fb.configuration) await device.selectConfiguration(fb.configuration);
			await device.claimInterface(fb.interfaceNumber);
			if (fb.alternate !== 0) await device.selectAlternateInterface(fb.interfaceNumber, fb.alternate);
		} catch (e) {
			const msg = e instanceof Error ? e.message : String(e);
			throw new UsbError(
				/access|denied|busy|claim/i.test(msg)
					? `The phone is in use by another program (close any adb or fastboot running on this computer, and other tabs using it): ${msg}`
					: `Couldn't open the phone: ${msg}`,
			);
		}
		return new UsbTransport(device, fb);
	}

	get serial(): string {
		return this.device.serialNumber ?? "";
	}

	async send(data: Uint8Array): Promise<void> {
		const r = await this.device.transferOut(this.fb.epOut, data as Uint8Array<ArrayBuffer>);
		if (r.status !== "ok") {
			if (r.status === "stall") await this.device.clearHalt("out", this.fb.epOut).catch(() => {});
			throw new UsbError(`USB write failed (${r.status})`);
		}
		if (r.bytesWritten !== data.byteLength) throw new UsbError(`USB wrote ${r.bytesWritten} of ${data.byteLength} bytes`);
	}

	async receive(maxLength: number): Promise<Uint8Array> {
		const r = await this.device.transferIn(this.fb.epIn, maxLength);
		if (r.status !== "ok" || !r.data) {
			if (r.status === "stall") await this.device.clearHalt("in", this.fb.epIn).catch(() => {});
			throw new UsbError(`USB read failed (${r.status})`);
		}
		return new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength);
	}

	async close(): Promise<void> {
		try {
			await this.device.releaseInterface(this.fb.interfaceNumber);
		} catch {
			/* already gone */
		}
		try {
			await this.device.close();
		} catch {
			/* already gone */
		}
	}
}

/** Asks the user to pick the phone (needs a click). */
export async function requestPhone(): Promise<USBDevice> {
	try {
		return await navigator.usb.requestDevice({ filters: [FASTBOOT_FILTER] });
	} catch (e) {
		if (e instanceof DOMException && e.name === "NotFoundError") throw new UsbError("No phone was chosen");
		throw e;
	}
}

/**
 * Waits for the phone with this serial number to come back in fastboot mode (after a restart).
 * Phones the site was already allowed to use are found without asking; when the phone comes back
 * as a device the browser hasn't allowed yet, `needsUser` fires once so the page can show a button
 * that calls `offer()` with the device the user picks.
 */
export class Reconnector {
	private resolveDevice: ((d: USBDevice) => boolean) | null = null;

	async wait(serial: string, opts: { timeoutMs: number; needsUserAfterMs: number; needsUser: () => void; signal?: AbortSignal }): Promise<USBDevice> {
		const usb = navigator.usb;
		return new Promise<USBDevice>((resolve, reject) => {
			let done = false;
			const finish = (d: USBDevice | null, err?: unknown) => {
				if (done) return;
				done = true;
				clearInterval(poll);
				clearTimeout(userTimer);
				clearTimeout(timeout);
				usb.removeEventListener("connect", onConnect);
				this.resolveDevice = null;
				if (d) resolve(d);
				else reject(err);
			};
			const matches = (d: USBDevice) => isFastbootDevice(d) && (!serial || d.serialNumber === serial);
			const onConnect = (ev: USBConnectionEvent) => {
				if (matches(ev.device)) finish(ev.device);
			};
			usb.addEventListener("connect", onConnect);
			this.resolveDevice = (d) => {
				if (!matches(d)) return false;
				finish(d);
				return true;
			};
			const check = async () => {
				const list = await usb.getDevices();
				const d = list.find(matches);
				if (d) finish(d);
			};
			const poll = setInterval(() => void check().catch(() => {}), 1000);
			const userTimer = setTimeout(() => {
				if (!done) opts.needsUser();
			}, opts.needsUserAfterMs);
			const timeout = setTimeout(() => finish(null, new UsbError("The phone didn't come back. Check the cable and that it shows Fastboot Mode, then try again.")), opts.timeoutMs);
			opts.signal?.addEventListener("abort", () => finish(null, opts.signal?.reason ?? new DOMException("Aborted", "AbortError")));
		});
	}

	/**
	 * The device the user picked from the browser's chooser while we wait. False when it isn't the
	 * phone being waited for (then the wait goes on).
	 */
	offer(device: USBDevice): boolean {
		return this.resolveDevice?.(device) ?? false;
	}

	get waiting() {
		return this.resolveDevice !== null;
	}
}
