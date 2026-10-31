// Opening the phone over WebUSB: what each failure Chrome reports means for the user, and the
// reset a phone gets when the last session left it part way through a command. The USBDevice is
// a stand-in that fails the way Chrome does (Blink's usb_device.cc).

import { afterEach, describe, expect, it, vi } from "vitest";
import { WebUsbConnector, linkTo } from "../src/fastboot/usb-connector.ts";
import { FASTBOOT_FILTER, UsbError, UsbTransport, hostOs, openFailure } from "../src/fastboot/webusb.ts";

type Hook = () => Promise<void>;

function fakeDevice(o: { open?: Hook; selectConfiguration?: Hook; claimInterface?: Hook; reset?: Hook | null } = {}) {
	const calls: string[] = [];
	const configurations = [
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
	const d: Record<string, unknown> = {
		serialNumber: "28161FDH2000AB",
		opened: false,
		configuration: null,
		configurations,
		async open() {
			calls.push("open");
			await o.open?.();
			d.opened = true;
		},
		async selectConfiguration() {
			calls.push("configure");
			await o.selectConfiguration?.();
			d.configuration = configurations[0];
		},
		async claimInterface() {
			calls.push("claim");
			await o.claimInterface?.();
		},
		async releaseInterface() {
			calls.push("release");
		},
		async close() {
			calls.push("close");
			d.opened = false;
		},
	};
	if (o.reset !== null) {
		d.reset = async () => {
			calls.push("reset");
			await o.reset?.();
			// Chrome on Linux forgets the configuration after a reset
			d.configuration = null;
		};
	}
	return { device: d as unknown as USBDevice, calls };
}

const denied = () => Promise.reject(new DOMException("Access denied.", "SecurityError"));
const claimed = () => Promise.reject(new DOMException("Unable to claim interface.", "NetworkError"));

const UA = {
	windows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
	linux: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
	android: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
	chromeos: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
	mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
};

afterEach(() => {
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

describe("which system the browser runs on", () => {
	it("reads the user agent, and the platform hint first", () => {
		expect(hostOs({ userAgent: UA.windows })).toBe("windows");
		expect(hostOs({ userAgent: UA.linux })).toBe("linux");
		expect(hostOs({ userAgent: UA.android })).toBe("android");
		expect(hostOs({ userAgent: UA.chromeos })).toBe("chromeos");
		expect(hostOs({ userAgent: UA.mac })).toBe("mac");
		expect(hostOs({ userAgent: UA.linux, userAgentData: { platform: "Android" } })).toBe("android");
		expect(hostOs({ userAgent: "" })).toBe("other");
		expect(hostOs(undefined)).toBe("other");
	});
});

describe("opening the phone", () => {
	it("tells Linux users to add a udev rule when the browser is denied the phone, not that it's in use", async () => {
		vi.stubGlobal("navigator", { userAgent: UA.linux });
		const { device, calls } = fakeDevice({ open: denied });
		const err = await UsbTransport.open(device).catch((e) => e);
		expect(err).toBeInstanceOf(UsbError);
		expect((err as UsbError).kind).toBe("access");
		expect((err as UsbError).message).toMatch(/udev rule for Google's USB vendor id 18d1/);
		expect((err as UsbError).message).toMatch(/android-udev-rules/);
		expect((err as UsbError).message).toMatch(/unplug the phone, plug it back in/);
		expect((err as UsbError).message).toMatch(/The browser said: Access denied\.$/);
		expect((err as UsbError).message).not.toMatch(/in use|adb/);
		expect(calls).toEqual(["open"]);
	});

	it("tells Windows users to install the Google USB Driver", () => {
		const err = openFailure("open", new DOMException("Access denied.", "SecurityError"), "windows");
		expect(err.kind).toBe("access");
		expect(err.message).toMatch(/Install the Google USB Driver for the phone in Fastboot Mode/);
		// The page links to the driver beside the message (app.ts); an address in the text can't be clicked
		expect(err.message).not.toMatch(/https?:|win-usb/);
		expect(err.message).not.toMatch(/in use|adb|udev/);
	});

	it("gives Android and other systems their own advice", () => {
		const e = new DOMException("Access denied.", "SecurityError");
		expect(openFailure("open", e, "android").message).toMatch(/allow Chrome to use it when Android asks/);
		for (const os of ["mac", "chromeos", "other"] as const) {
			const err = openFailure("open", e, os);
			expect(err.kind).toBe("access");
			expect(err.message).toMatch(/didn't let the browser open the phone/);
			expect(err.message).not.toMatch(/udev|USB Driver/);
		}
	});

	it("keeps the advice to close adb, fastboot and other tabs for a phone something else holds", async () => {
		vi.stubGlobal("navigator", { userAgent: UA.linux });
		const { device } = fakeDevice({ claimInterface: claimed });
		const err = await UsbTransport.open(device).catch((e) => e);
		expect((err as UsbError).kind).toBe("in-use");
		expect((err as UsbError).message).toMatch(/in use by another program\. Close any adb or fastboot running on this computer, and any other tab using the phone/);
		expect((err as UsbError).message).not.toMatch(/udev/);
		const conf = openFailure("configure", new DOMException("Unable to set device configuration.", "NetworkError"), "windows");
		expect(conf.kind).toBe("in-use");
	});

	it("says what the browser said for anything else", () => {
		const gone = openFailure("open", new DOMException("The device was disconnected.", "NotFoundError"), "linux");
		expect(gone.kind).toBe("other");
		expect(gone.message).toBe("Couldn't open the phone. The browser said: The device was disconnected.");
		// A SecurityError from claiming is a protected interface class, not a permission problem
		expect(openFailure("claim", new DOMException("The requested interface implements a protected class.", "SecurityError"), "linux").kind).toBe("other");
	});

	it("doesn't keep retrying a phone the computer won't let the browser open", async () => {
		vi.stubGlobal("navigator", { userAgent: UA.windows });
		const { device, calls } = fakeDevice({ open: denied });
		const err = await linkTo(device).catch((e) => e);
		expect((err as UsbError).kind).toBe("access");
		expect(calls.filter((c) => c === "open")).toHaveLength(1);
	});

	it("still retries after a restart, while the phone's permissions settle", async () => {
		vi.useFakeTimers();
		vi.stubGlobal("navigator", { userAgent: UA.linux });
		let tries = 0;
		const { device } = fakeDevice({ open: () => (++tries < 3 ? denied() : Promise.resolve()) });
		const link = linkTo(device, { afterRestart: true });
		await vi.advanceTimersByTimeAsync(5000);
		await expect(link).resolves.toMatchObject({ serial: "28161FDH2000AB" });
		expect(tries).toBe(3);
	});
});

describe("a phone left part way through a command", () => {
	it("is reset before it's used again, and only then", async () => {
		const { device, calls } = fakeDevice();
		const first = await UsbTransport.open(device);
		await first.close();
		expect(calls).toEqual(["open", "configure", "claim", "release", "close"]);
		calls.length = 0;

		// The session broke (a download not finished): the next open resets the phone first, then
		// configures it again, since a reset drops the configuration
		const second = await UsbTransport.open(device);
		second.abandon();
		await second.close();
		calls.length = 0;
		const third = await UsbTransport.open(device);
		expect(calls).toEqual(["open", "reset", "configure", "claim"]);
		await third.close();
		calls.length = 0;

		await UsbTransport.open(device);
		expect(calls).not.toContain("reset");
	});

	it("still opens where the browser can't reset a device (Chrome on Windows)", async () => {
		const { device, calls } = fakeDevice({ reset: () => Promise.reject(new DOMException("Unable to reset the device.", "NetworkError")) });
		const t = await UsbTransport.open(device);
		t.abandon();
		await t.close();
		calls.length = 0;
		await expect(UsbTransport.open(device)).resolves.toBeInstanceOf(UsbTransport);
		expect(calls).toEqual(["open", "reset", "claim"]);

		const { device: old, calls: oldCalls } = fakeDevice({ reset: null });
		const t2 = await UsbTransport.open(old);
		t2.abandon();
		await t2.close();
		oldCalls.length = 0;
		await expect(UsbTransport.open(old)).resolves.toBeInstanceOf(UsbTransport);
		expect(oldCalls).toEqual(["open", "claim"]);
	});
});

describe("a phone restarted into Fastboot Mode over USB debugging", () => {
	const SERIAL = "28161FDH2000AB";
	const timeoutMessage = "The phone didn't come back in Fastboot Mode.";

	/** navigator.usb with the devices the site may use, and the one the chooser offers. */
	function browser(ua: string) {
		const allowed: USBDevice[] = [];
		const requests: USBDeviceRequestOptions[] = [];
		let offered: USBDevice | null = null;
		const usb = Object.assign(new EventTarget(), {
			getDevices: async () => allowed.slice(),
			requestDevice: async (o: USBDeviceRequestOptions) => {
				requests.push(o);
				if (!offered) throw new DOMException("No device selected.", "NotFoundError");
				allowed.push(offered);
				return offered;
			},
		});
		vi.stubGlobal("navigator", { userAgent: ua, usb });
		return { allowed, requests, offer: (d: USBDevice) => (offered = d) };
	}

	const ui = () => ({ needsReconnect: vi.fn<(show: boolean) => void>(), restarting: vi.fn<(on: boolean) => void>() });

	/** The browser's localStorage. */
	function storage() {
		const data = new Map<string, string>();
		vi.stubGlobal("localStorage", { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v) });
		return data;
	}

	it("is found without the user when this browser opened it in Fastboot Mode before, and opened", async () => {
		vi.useFakeTimers();
		const data = storage();
		const b = browser(UA.linux);
		// An earlier visit opened it in Fastboot Mode, so the site may use it there
		await (await linkTo(fakeDevice().device)).close();
		expect(JSON.parse(data.get("eos-flasher-fastboot-opened")!)).toEqual([SERIAL]);
		const u = ui();
		const link = new WebUsbConnector(u).waitForFastboot(SERIAL, { timeoutMessage });
		// A Pixel takes several seconds to get there: nobody is asked meanwhile
		await vi.advanceTimersByTimeAsync(15_000);
		const { device, calls } = fakeDevice();
		b.allowed.push(device);
		await vi.advanceTimersByTimeAsync(1000);
		await expect(link).resolves.toMatchObject({ serial: SERIAL });
		expect(calls).toEqual(["open", "configure", "claim"]);
		expect(u.needsReconnect).not.toHaveBeenCalledWith(true);
	});

	it("asks the user to choose it again by 20 seconds on a computer when it isn't found though this browser opened it before", async () => {
		vi.useFakeTimers();
		const data = storage();
		data.set("eos-flasher-fastboot-opened", JSON.stringify(["OTHERPHONE01", SERIAL]));
		browser(UA.mac);
		const u = ui();
		const link = new WebUsbConnector(u).waitForFastboot(SERIAL, { timeoutMessage });
		link.catch(() => {});
		await vi.advanceTimersByTimeAsync(19_000);
		expect(u.needsReconnect).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(1500);
		expect(u.needsReconnect).toHaveBeenLastCalledWith(true);
	});

	it("asks the user to choose it again after about 10 seconds on a computer, and takes only that phone in Fastboot Mode", async () => {
		vi.useFakeTimers();
		const b = browser(UA.windows);
		const u = ui();
		const c = new WebUsbConnector(u);
		const link = c.waitForFastboot(SERIAL, { timeoutMessage });
		// A phone this browser never opened in Fastboot Mode can't be found without the user, who is
		// asked about when it gets there, not before
		await vi.advanceTimersByTimeAsync(9000);
		expect(u.needsReconnect).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(1500);
		expect(u.needsReconnect).toHaveBeenLastCalledWith(true);
		// Another phone is chosen: the wait goes on
		const other = fakeDevice().device;
		(other as unknown as { serialNumber: string }).serialNumber = "OTHERPHONE01";
		b.offer(other);
		await expect(c.pick()).rejects.toThrow("That isn't the phone the page is waiting for, or it isn't in Fastboot Mode yet. Choose it again.");
		await vi.advanceTimersByTimeAsync(2000);
		// The chooser lists only phones in Fastboot Mode
		expect(b.requests.at(-1)).toEqual({ filters: [FASTBOOT_FILTER] });
		b.offer(fakeDevice().device);
		await c.pick();
		await expect(link).resolves.toMatchObject({ serial: SERIAL });
		expect(u.needsReconnect).toHaveBeenLastCalledWith(false);
	});

	it("asks at once on Chrome on Android, which never finds it on its own", async () => {
		vi.useFakeTimers();
		browser(UA.android);
		const u = ui();
		const link = new WebUsbConnector(u).waitForFastboot(SERIAL, { timeoutMessage });
		link.catch(() => {});
		await vi.advanceTimersByTimeAsync(10);
		expect(u.needsReconnect).toHaveBeenCalledWith(true);
	});

	/** requestDevice that stays open until the test picks a phone, or closes it with none. */
	function slowList(b: ReturnType<typeof browser>) {
		let answer: (d: USBDevice | null) => void = () => {};
		(navigator.usb as unknown as { requestDevice: () => Promise<USBDevice> }).requestDevice = () =>
			new Promise((resolve, reject) => {
				answer = (d) => {
					if (!d) return reject(new DOMException("No device selected.", "NotFoundError"));
					b.allowed.push(d);
					resolve(d);
				};
			});
		return { pick: (d: USBDevice | null) => answer(d) };
	}

	it("doesn't run out of time while the user is choosing it in the browser's list, and takes the phone picked late", async () => {
		vi.useFakeTimers();
		const list = slowList(browser(UA.android));
		const u = ui();
		const c = new WebUsbConnector(u);
		const link = c.waitForFastboot(SERIAL, { timeoutMessage });
		let settled = false;
		link.then(
			() => (settled = true),
			() => (settled = true),
		);
		await vi.advanceTimersByTimeAsync(100_000);
		const picking = c.pick();
		// The list is still open when the 2 minutes are up
		await vi.advanceTimersByTimeAsync(60_000);
		expect(settled).toBe(false);
		list.pick(fakeDevice().device);
		await picking;
		await expect(link).resolves.toMatchObject({ serial: SERIAL });
	});

	it("runs out of time once the list closes with no phone picked after its time", async () => {
		vi.useFakeTimers();
		const list = slowList(browser(UA.android));
		const c = new WebUsbConnector(ui());
		const link = c.waitForFastboot(SERIAL, { timeoutMessage });
		const failed = expect(link).rejects.toThrow(timeoutMessage);
		await vi.advanceTimersByTimeAsync(100_000);
		const picking = c.pick();
		await vi.advanceTimersByTimeAsync(30_000);
		list.pick(null);
		await expect(picking).rejects.toThrow("No phone was chosen");
		await failed;
	});

	it("fails with the page's message when it doesn't come back, and stops when the signal fires", async () => {
		vi.useFakeTimers();
		browser(UA.linux);
		const u = ui();
		const late = new WebUsbConnector(u).waitForFastboot(SERIAL, { timeoutMessage });
		const failed = expect(late).rejects.toThrow(timeoutMessage);
		await vi.advanceTimersByTimeAsync(2 * 60_000);
		await failed;
		expect(u.needsReconnect).toHaveBeenLastCalledWith(false);

		const ac = new AbortController();
		const cancelled = new WebUsbConnector(ui()).waitForFastboot(SERIAL, { timeoutMessage, signal: ac.signal });
		ac.abort();
		await expect(cancelled).rejects.toMatchObject({ name: "AbortError" });
		ac.abort();
		await expect(new WebUsbConnector(ui()).waitForFastboot(SERIAL, { timeoutMessage, signal: ac.signal })).rejects.toMatchObject({ name: "AbortError" });
	});
});
