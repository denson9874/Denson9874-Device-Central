// WebUSB for USB debugging: a Pixel running Android is a composite device (MTP or PTP, and ADB),
// so the ADB interface is found among the others, claimed on its own, and its bulk pipes are used
// the way adb's libusb client uses them (client_usb_libusb.cpp).

import { type HostOs, hostOs, openFailure } from "../fastboot/webusb.ts";
import { AdbError, browserSaid } from "./error.ts";
import type { AdbReadPipe } from "./message.ts";

/** The ADB interface: vendor specific class, subclass 0x42, protocol 1 (fastboot is protocol 3). */
export const ADB_FILTER: USBDeviceFilter = { classCode: 0xff, subclassCode: 0x42, protocolCode: 0x01 };

export interface AdbInterface {
	configuration: number;
	interfaceNumber: number;
	alternate: number;
	epIn: number;
	epOut: number;
	inPacketSize: number;
	outPacketSize: number;
}

/** The ADB interface and its bulk endpoints, looking in the active configuration first. */
export function findAdbInterface(device: USBDevice): AdbInterface | null {
	const active = device.configuration?.configurationValue;
	const confs = [...device.configurations].sort((a, b) => Number(b.configurationValue === active) - Number(a.configurationValue === active));
	for (const conf of confs) {
		for (const iface of conf.interfaces) {
			for (const alt of iface.alternates) {
				if (alt.interfaceClass !== ADB_FILTER.classCode || alt.interfaceSubclass !== ADB_FILTER.subclassCode || alt.interfaceProtocol !== ADB_FILTER.protocolCode) continue;
				const bulkIn = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "in");
				const bulkOut = alt.endpoints.find((e) => e.type === "bulk" && e.direction === "out");
				if (!bulkIn || !bulkOut) continue;
				return {
					configuration: conf.configurationValue,
					interfaceNumber: iface.interfaceNumber,
					alternate: alt.alternateSetting,
					epIn: bulkIn.endpointNumber,
					epOut: bulkOut.endpointNumber,
					// 512 is a high-speed bulk endpoint's size, for a browser that doesn't say
					inPacketSize: bulkIn.packetSize || 512,
					outPacketSize: bulkOut.packetSize || 512,
				};
			}
		}
	}
	return null;
}

/** A phone running Android with USB debugging on. */
export function isAdbDevice(device: USBDevice): boolean {
	return findAdbInterface(device) !== null;
}

/**
 * Why the browser couldn't use the phone's USB debugging interface, and what to do. As with
 * fastboot (openFailure), Chrome rejects open() with a SecurityError when the system won't hand
 * it the device, and claimInterface() with a NetworkError when another program holds it. Here that
 * program is nearly always an adb server (adb itself, Android Studio or scrcpy start one), which
 * claims every phone with USB debugging on. On Windows a program holding the phone makes open()
 * fail with "Access denied." too, so that advice names both causes.
 */
export function adbOpenFailure(stage: Parameters<typeof openFailure>[0], e: unknown, os: HostOs = hostOs()): AdbError {
	const said = browserSaid(e);
	const name = e instanceof DOMException || e instanceof Error ? e.name : "";
	if (stage === "open" && name === "SecurityError" && os === "windows") {
		return new AdbError(
			"access",
			`Windows isn't letting the browser use the phone. If adb, Android Studio or scrcpy is running on this computer, close Android Studio and scrcpy, run adb kill-server in a terminal and try again. Otherwise install the Google USB Driver, then unplug the phone, plug it back in and try again.${said}`,
			{ cause: e },
		);
	}
	if ((stage === "claim" || stage === "configure") && name === "NetworkError") {
		if (os === "android") return new AdbError("in-use", `Another app or tab is using the phone's USB debugging connection. Close it, then try again.${said}`, { cause: e });
		return new AdbError(
			"in-use",
			`Another program on this computer is using the phone's USB debugging connection, usually an adb server started by adb, Android Studio or scrcpy. Close Android Studio and scrcpy if they're open, and any other tab using the phone. Then run adb kill-server in a terminal and try again.${said}`,
			{ cause: e },
		);
	}
	const u = openFailure(stage, e, os);
	return new AdbError(u.kind === "other" ? "usb" : u.kind, u.message, { cause: e });
}

/** The phone's ADB interface, opened and claimed: one bulk pipe each way. */
export class AdbUsb implements AdbReadPipe {
	private closed = false;

	private constructor(
		readonly device: USBDevice,
		readonly iface: AdbInterface,
	) {}

	static async open(device: USBDevice, os?: HostOs): Promise<AdbUsb> {
		const iface = findAdbInterface(device);
		if (!iface) throw new AdbError("usb", "This USB device isn't a phone with USB debugging turned on.");
		let stage: Parameters<typeof openFailure>[0] = "open";
		const wasOpen = device.opened;
		try {
			if (!device.opened) await device.open();
			stage = "configure";
			// A composite phone is already configured; choosing again would upset its other functions
			if (device.configuration?.configurationValue !== iface.configuration) await device.selectConfiguration(iface.configuration);
			stage = "claim";
			await device.claimInterface(iface.interfaceNumber);
			stage = "alternate";
			if (iface.alternate !== 0) await device.selectAlternateInterface(iface.interfaceNumber, iface.alternate);
		} catch (e) {
			if (stage === "alternate") await device.releaseInterface(iface.interfaceNumber).catch(() => {});
			if (!wasOpen && device.opened) await device.close().catch(() => {});
			throw adbOpenFailure(stage, e, os);
		}
		return new AdbUsb(device, iface);
	}

	private gone(e: unknown): AdbError {
		return new AdbError("usb", `The phone stopped answering over USB. Check the cable, then try again.${browserSaid(e)}`, { cause: e });
	}

	private async transferOut(data: Uint8Array): Promise<void> {
		let r: USBOutTransferResult;
		try {
			r = await this.device.transferOut(this.iface.epOut, data as Uint8Array<ArrayBuffer>);
		} catch (e) {
			throw this.gone(e);
		}
		if (r.status !== "ok") {
			if (r.status === "stall") await this.device.clearHalt("out", this.iface.epOut).catch(() => {});
			throw this.gone(`USB write failed (${r.status})`);
		}
		if (r.bytesWritten !== data.byteLength) throw this.gone(`USB wrote ${r.bytesWritten} of ${data.byteLength} bytes`);
	}

	/**
	 * One write, as one bulk transfer. A write that fills its last packet is followed by a
	 * zero-length packet, as adb's libusb client does: adbd reads in large blocks and only sees the
	 * end of a transfer at a short packet.
	 */
	async write(data: Uint8Array): Promise<void> {
		await this.transferOut(data);
		if (data.byteLength > 0 && data.byteLength % this.iface.outPacketSize === 0) await this.transferOut(new Uint8Array(0));
	}

	/**
	 * One bulk IN transfer of whole packets that holds at least `want` bytes. Asking for less than
	 * a packet would overflow when the phone sends a full one; asking for no more than the bytes
	 * still due keeps one transfer from running into the phone's next message.
	 */
	async read(want: number): Promise<Uint8Array> {
		const ps = this.iface.inPacketSize;
		const length = Math.max(ps, Math.ceil(want / ps) * ps);
		let r: USBInTransferResult;
		try {
			r = await this.device.transferIn(this.iface.epIn, length);
		} catch (e) {
			throw this.gone(e);
		}
		if (r.status !== "ok") {
			if (r.status === "stall") await this.device.clearHalt("in", this.iface.epIn).catch(() => {});
			throw this.gone(`USB read failed (${r.status})`);
		}
		return r.data ? new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength) : new Uint8Array(0);
	}

	/** Lets go of the interface and the device, quietly: the phone may already be gone. */
	async close(): Promise<void> {
		if (this.closed) return;
		this.closed = true;
		try {
			await this.device.releaseInterface(this.iface.interfaceNumber);
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
