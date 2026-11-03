// The browser's Connector: restarts go through WebUSB, and when the phone comes back as a device
// the site may not use yet, the page shows a Reconnect button (the browser's chooser needs a click).
// A phone restarted into Fastboot Mode over USB debugging is waited for the same way.

import type { Connector, Link, Mode } from "./device.ts";
import { Reconnector, UsbError, UsbTransport } from "./webusb.ts";

/** Where the page notes, by serial number, the phones it opened in Fastboot Mode in this browser. */
const OPENED_IN_FASTBOOT = "eos-flasher-fastboot-opened";
const OPENED_KEPT = 16;

function openedInFastboot(): string[] {
	try {
		const list: unknown = JSON.parse(localStorage.getItem(OPENED_IN_FASTBOOT) ?? "[]");
		return Array.isArray(list) ? list.filter((s): s is string => typeof s === "string") : [];
	} catch {
		/* no storage, or blocked */
		return [];
	}
}

/**
 * Notes that this browser opened the phone in Fastboot Mode. Chrome keeps the site's permission
 * for it there (by vendor id, product id and serial number), so next time it's found on its own
 * after a restart, without the user. The browser can't say that of a phone that isn't plugged in.
 */
function noteOpenedInFastboot(serial: string | null | undefined) {
	if (!serial) return;
	try {
		const list = [serial, ...openedInFastboot().filter((s) => s !== serial)].slice(0, OPENED_KEPT);
		localStorage.setItem(OPENED_IN_FASTBOOT, JSON.stringify(list));
	} catch {
		/* storage blocked: the user is only asked a little sooner next time */
	}
}

/**
 * Opens the phone's fastboot interface. A phone that just came back from a restart can need a
 * moment before it can be opened (on Linux its udev permissions land just after it appears), so
 * that tries for a few seconds; a phone the user picked that the computer won't let the browser
 * open fails at once, since waiting doesn't fix a missing driver or permission.
 */
export async function linkTo(device: USBDevice, opts: { afterRestart?: boolean } = {}): Promise<Link> {
	let last: unknown;
	for (let i = 0; i < 6; i++) {
		try {
			const t = await UsbTransport.open(device);
			noteOpenedInFastboot(device.serialNumber);
			return { transport: t, serial: device.serialNumber ?? "", close: () => t.close() };
		} catch (e) {
			last = e;
			if (!opts.afterRestart && e instanceof UsbError && e.kind === "access") break;
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
	/** The phone is restarting (true) into `target`, or back (false). */
	restarting(on: boolean, target?: Mode): void;
}

/**
 * How long the page waits for a phone back from a restart before it asks the user to choose it
 * again on a computer (Chrome on Android always needs the user), and at all, by where it went.
 * fastbootd is Android's recovery starting in its fastboot mode: the phone shows the G logo
 * while the kernel and recovery start, which takes longer than the bootloader does. A computer's
 * browser usually finds the phone again on its own when fastbootd comes up (the same USB ids and
 * serial number as in the bootloader), so asking at 20 seconds asked users to choose a phone that
 * was still on the G logo and not in the list yet.
 */
export const RESTART_WAIT: Record<Mode, { askAfterMs: number; timeoutMs: number }> = {
	fastbootd: { askAfterMs: 60_000, timeoutMs: 5 * 60_000 },
	bootloader: { askAfterMs: 20_000, timeoutMs: 3 * 60_000 },
};

/** What the install says when the phone doesn't come back from a restart in time (`android`: Chrome on Android). */
export function restartTimeoutMessage(target: Mode, android: boolean): string {
	if (target === "bootloader") return "The phone didn't come back. Check the cable and that it shows Fastboot Mode, then try again.";
	const minutes = RESTART_WAIT.fastbootd.timeoutMs / 60_000;
	// The install goes on from fastbootd, so a phone that got there only needs connecting again.
	// One still on the G logo didn't start the recovery in the vendor_boot this build just wrote
	const there = android
		? "If it shows FASTBOOTD, it just wasn't chosen in the list in time: leave it on that screen, press Try again, connect it and choose it. The install goes on from there."
		: "If it shows FASTBOOTD, the browser lost it: leave it on that screen, plug it straight into the computer (no hub), press Try again and connect it. The install goes on from there.";
	return (
		`The phone didn't come back in fastbootd within ${minutes} minutes. ${there} ` +
		"If it's still on the G logo, fastbootd didn't start, and this build may not start on this phone: please report it in the ExpressiveOS Telegram group or XDA thread, with a screenshot of this page with Details open. " +
		"Google's Android Flash Tool puts the phone back on stock Android (leave Lock bootloader unticked)."
	);
}

export class WebUsbConnector implements Connector {
	private reconnector = new Reconnector();

	constructor(private readonly ui: ReconnectUi) {}

	async restart(link: Link, send: () => Promise<void>, signal?: AbortSignal, target: Mode = "bootloader"): Promise<Link> {
		const device = (link.transport as UsbTransport).device;
		const wait = RESTART_WAIT[target];
		const gone = waitForDisconnect(device, 30_000);
		this.ui.restarting(true, target);
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
				timeoutMs: wait.timeoutMs,
				// Chrome on Android can't recognise the phone again without the user picking it
				needsUserAfterMs: android ? 0 : wait.askAfterMs,
				needsUser: () => this.ui.needsReconnect(true),
				signal,
				timeoutMessage: restartTimeoutMessage(target, android),
			});
			this.ui.needsReconnect(false);
			return await linkTo(d, { afterRestart: true });
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

	/**
	 * Waits for the phone with this serial number to come back in Fastboot Mode after it was
	 * restarted into it over USB debugging, and opens it. In Fastboot Mode a Pixel has another USB
	 * product id, so the browser sees a new device: one the site was allowed to use before is
	 * found on its own, and otherwise the page shows its button for pick() (at once on Chrome on
	 * Android, which never finds it on its own). Fails with `timeoutMessage` when it doesn't come,
	 * unless the user is choosing it in the browser's list then.
	 */
	async waitForFastboot(serial: string, opts: { signal?: AbortSignal; timeoutMessage: string }): Promise<Link> {
		const android = typeof navigator !== "undefined" && /Android/i.test(navigator.userAgent);
		try {
			const d = await this.reconnector.wait(serial, {
				timeoutMs: 2 * 60_000,
				// A Pixel takes 8 to 15 seconds or so to get to Fastboot Mode. One this browser opened
				// there before is found on its own, so the user is asked only if it isn't by then; one it
				// never did needs the user, who is asked about when it gets there
				needsUserAfterMs: android ? 0 : openedInFastboot().includes(serial) ? 20_000 : 10_000,
				needsUser: () => this.ui.needsReconnect(true),
				signal: opts.signal,
				timeoutMessage: opts.timeoutMessage,
			});
			this.ui.needsReconnect(false);
			return await linkTo(d, { afterRestart: true });
		} finally {
			this.ui.needsReconnect(false);
		}
	}

	/** The Reconnect button: the user picks the phone in the browser's chooser (Reconnector.pick). */
	pick(): Promise<void> {
		return this.reconnector.pick();
	}
}
