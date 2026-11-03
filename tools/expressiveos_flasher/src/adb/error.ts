// What can go wrong talking to a phone over USB debugging (ADB), and what the page should do about it.

/**
 * - "access": the computer won't let the browser open the phone (a missing driver or udev rule).
 * - "in-use": another program holds the phone's USB debugging interface, usually an adb server.
 * - "unauthorized": the phone didn't allow USB debugging for this browser (no answer to "Allow USB
 *   debugging?" in time, or it kept refusing the key).
 * - "timeout": the phone didn't answer at all.
 * - "refused": the phone answered, but wouldn't restart into Fastboot Mode.
 * - "protocol": the phone sent something malformed.
 * - "usb": a USB transfer failed, or the phone went away before it was ready.
 */
export type AdbErrorKind = "access" | "in-use" | "unauthorized" | "timeout" | "refused" | "protocol" | "usb";

export class AdbError extends Error {
	constructor(
		readonly kind: AdbErrorKind,
		message: string,
		options?: { cause?: unknown },
	) {
		super(message, options);
		this.name = "AdbError";
	}
}

/** What the browser said, as a sentence to end a message with. */
export function browserSaid(e: unknown): string {
	const msg = e instanceof Error ? e.message : e === undefined ? "" : String(e);
	return msg ? ` The browser said: ${msg}` : "";
}

/** A malformed message from the phone. */
export function malformed(what: string): AdbError {
	return new AdbError("protocol", `USB debugging on the phone sent something this page can't read: ${what}. Unplug the phone, plug it back in and try again.`);
}
