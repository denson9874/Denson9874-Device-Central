// WebUSB: finding a phone in fastboot mode, opening its fastboot interface, and finding it again
// after it restarts (bootloader <-> fastbootd), when it comes back as a new USB device.

import type { Transport } from "./client.ts";

export const FASTBOOT_FILTER: USBDeviceFilter = { classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03 };

/**
 * What kind of USB failure: "access" when the computer won't let the browser open the phone (a
 * missing driver or permission, which waiting won't fix), "in-use" when another program or tab
 * holds it.
 */
export type UsbErrorKind = "access" | "in-use" | "other";

export class UsbError extends Error {
	constructor(
		message: string,
		readonly kind: UsbErrorKind = "other",
	) {
		super(message);
		this.name = "UsbError";
	}
}

/** The Google USB Driver's page. The page shows it as a link beside an "access" failure on Windows. */
export const USB_DRIVER_URL = "https://developer.android.com/studio/run/win-usb";

export type HostOs = "windows" | "linux" | "android" | "chromeos" | "mac" | "other";

/** The system the browser runs on, for advice that depends on it. */
export function hostOs(nav: { userAgent?: string; userAgentData?: { platform?: string } } | undefined = typeof navigator === "undefined" ? undefined : navigator): HostOs {
	const p = `${nav?.userAgentData?.platform ?? ""} ${nav?.userAgent ?? ""}`;
	if (/Windows/i.test(p)) return "windows";
	if (/Android/i.test(p)) return "android";
	if (/CrOS|Chrome ?OS/i.test(p)) return "chromeos";
	if (/mac ?OS|Macintosh/i.test(p)) return "mac";
	if (/Linux|X11/i.test(p)) return "linux";
	return "other";
}

/**
 * Why the browser couldn't use the phone, and what to do. Chrome rejects open() with a
 * SecurityError ("Access denied.") when the system won't hand it the device: on Linux the device
 * node isn't writable without a udev rule, and on Windows the phone isn't bound to WinUSB without
 * the Google USB Driver. When another program or tab holds the phone, open() works and
 * claimInterface() fails instead, with a NetworkError ("Unable to claim interface.").
 */
export function openFailure(stage: "open" | "configure" | "claim" | "alternate", e: unknown, os: HostOs = hostOs()): UsbError {
	const msg = e instanceof Error ? e.message : String(e);
	const said = msg ? ` The browser said: ${msg}` : "";
	const name = e instanceof DOMException || e instanceof Error ? e.name : "";
	if (stage === "open" && name === "SecurityError") {
		switch (os) {
			case "windows":
				return new UsbError(
					`Windows isn't letting the browser use the phone. Install the Google USB Driver for the phone in Fastboot Mode, then unplug the phone, plug it back in and connect again.${said}`,
					"access",
				);
			case "linux":
				return new UsbError(
					"Linux isn't letting the browser use the phone. Add a udev rule for Google's USB vendor id 18d1, for example by installing the android-udev-rules package (android-sdk-platform-tools-common on Debian and Ubuntu), " +
						'or by putting the line SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", TAG+="uaccess" in /etc/udev/rules.d/51-android.rules and running sudo udevadm control --reload-rules. ' +
						`Then unplug the phone, plug it back in and connect again. With the Chromium snap, also run sudo snap connect chromium:raw-usb.${said}`,
					"access",
				);
			case "android":
				return new UsbError(`Android didn't let Chrome use the phone. Unplug it, plug it back in and connect again, and allow Chrome to use it when Android asks.${said}`, "access");
			default:
				return new UsbError(
					`This computer didn't let the browser open the phone. Another program may be using it, or the browser may not be allowed to use it. Close other programs that use the phone, then unplug it, plug it back in and connect again.${said}`,
					"access",
				);
		}
	}
	if ((stage === "claim" || stage === "configure") && name === "NetworkError") {
		return new UsbError(
			`The phone is in use by another program. Close any adb or fastboot running on this computer, and any other tab using the phone, then connect again.${said}`,
			"in-use",
		);
	}
	return new UsbError(`Couldn't open the phone.${said}`);
}

// Phones this page left part way through a command (see Transport.abandon)
const unsettled = new WeakSet<USBDevice>();

/** A USB reset where the platform has one (Chrome on Windows doesn't). */
async function tryReset(device: USBDevice): Promise<boolean> {
	try {
		await device.reset();
		return true;
	} catch {
		return false;
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
		let stage: Parameters<typeof openFailure>[0] = "open";
		try {
			if (!device.opened) await device.open();
			// The last session stopped part way through a command, so the phone may still want the
			// rest of a download or hold a late reply. Only a USB reset brings it back to waiting for
			// a command (fastboot.js resets on every connect). A reset drops the configuration.
			const reset = unsettled.delete(device) && (await tryReset(device));
			stage = "configure";
			if (reset || device.configuration?.configurationValue !== fb.configuration) await device.selectConfiguration(fb.configuration);
			stage = "claim";
			await device.claimInterface(fb.interfaceNumber);
			stage = "alternate";
			if (fb.alternate !== 0) await device.selectAlternateInterface(fb.interfaceNumber, fb.alternate);
		} catch (e) {
			throw openFailure(stage, e);
		}
		return new UsbTransport(device, fb);
	}

	abandon(): void {
		unsettled.add(this.device);
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

/**
 * Asks the user to pick the phone (needs a click). The list shows only devices that match
 * `filters`: by default a phone in Fastboot Mode.
 */
export async function requestPhone(filters: USBDeviceFilter[] = [FASTBOOT_FILTER]): Promise<USBDevice> {
	try {
		return await navigator.usb.requestDevice({ filters });
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
	/** The browser's lists open for pick(): while one is, the wait doesn't run out of time. */
	private picking = 0;
	/** The wait's failure for running out of time, held until the last list closes. */
	private afterPick: (() => void) | null = null;

	async wait(
		serial: string,
		opts: { timeoutMs: number; needsUserAfterMs: number; needsUser: () => void; signal?: AbortSignal; timeoutMessage?: string },
	): Promise<USBDevice> {
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
				this.afterPick = null;
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
			const timeout = setTimeout(() => {
				const fail = () => finish(null, new UsbError(opts.timeoutMessage ?? "The phone didn't come back. Check the cable and that it shows Fastboot Mode, then try again."));
				// The phone the user is choosing in the browser's list right now may be the one: the pick decides
				if (this.picking > 0) this.afterPick = fail;
				else fail();
			}, opts.timeoutMs);
			const onAbort = () => finish(null, opts.signal?.reason ?? new DOMException("Aborted", "AbortError"));
			if (opts.signal?.aborted) onAbort();
			else opts.signal?.addEventListener("abort", onAbort, { once: true });
		});
	}

	/**
	 * The user picks the phone in the browser's list (`choose` opens it) while the page waits. The
	 * wait doesn't run out of time while the list is open: it ends with the phone picked, or when the
	 * list closes after its time is up. Rejects with a UsbError when the phone picked isn't the one
	 * waited for (the wait goes on), and as requestPhone does when none was picked.
	 */
	async pick(choose: () => Promise<USBDevice> = () => requestPhone()): Promise<void> {
		this.picking++;
		try {
			if (!this.offer(await choose())) throw new UsbError("That isn't the phone the page is waiting for, or it isn't in Fastboot Mode yet. Choose it again.");
		} finally {
			if (--this.picking === 0) this.afterPick?.();
		}
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
