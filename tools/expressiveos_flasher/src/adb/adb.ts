// Restarting a phone that runs Android into Fastboot Mode over USB debugging, as Google's Android
// Flash Tool does. This is the whole of what the page does with ADB: connect (CNXN), prove this
// browser's key or offer it to the phone (AUTH), then open the one service "reboot:bootloader".
// It never opens a shell or any other service.
//
// The handshake follows AOSP adb's host side (adb.cpp's handle_packet, send_connect and
// handle_new_connection, client_auth.cpp's send_auth_response): this side starts at
// A_VERSION_MIN, so everything it sends before the phone's CNXN carries a checksum, and it skips
// checksums after that when the phone also speaks 0x01000001.

import { AdbError, malformed } from "./error.ts";
import { type AdbKey, browserAdbKey, defaultKeyName } from "./key.ts";
import {
	A_AUTH,
	A_CLSE,
	A_CNXN,
	A_OKAY,
	A_OPEN,
	A_STLS,
	A_VERSION,
	A_VERSION_MIN,
	A_VERSION_SKIP_CHECKSUM,
	A_WRTE,
	AUTH_RSAPUBLICKEY,
	AUTH_SIGNATURE,
	AUTH_TOKEN,
	type AdbBanner,
	type AdbMessage,
	MAX_PAYLOAD,
	MessageReader,
	TOKEN_SIZE,
	encodeHeader,
	parseBanner,
} from "./message.ts";
import { AdbUsb } from "./usb.ts";
import type { HostOs } from "../fastboot/webusb.ts";

export { AdbError, type AdbErrorKind } from "./error.ts";
export { ADB_FILTER, isAdbDevice } from "./usb.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

/** adb's host banner, as old adb sent it: no features are needed to restart a phone. */
const HOST_BANNER = enc.encode("host::\0");
const REBOOT_SERVICE = "reboot:bootloader";
/** The id of this side's only stream. */
const LOCAL_ID = 1;
/** A phone that sends this many tokens without letting the key in won't. */
const MAX_TOKENS = 8;
/** How many times the restart is asked for again after the phone started over. */
const MAX_REOPENS = 2;
/** A read that outlasted the watch after the phone accepted the restart. */
const SETTLED = Symbol("settled");
/** What the phone left queued for an earlier connection comes at once: this long with nothing means it's all read. */
const DRAIN_QUIET_MS = 150;
/** A drain's read that saw nothing in DRAIN_QUIET_MS. */
const QUIET = Symbol("quiet");

export interface ConnectOptions {
	/** Stops waiting (for the phone or for the user): the promise rejects with the signal's reason. */
	signal?: AbortSignal;
	/**
	 * The phone is showing "Allow USB debugging?" for this browser's key, so the page should ask
	 * the user to unlock it and tap Allow. Called once per connection, and can come during
	 * rebootToBootloader() when the phone asks for the key again.
	 */
	onAllowPrompt?: () => void;
	/** How long the phone has to answer at all. Default 10 s. */
	answerTimeoutMs?: number;
	/** How long the user has to tap Allow on the phone; 0 waits until the signal fires. Default 3 min. */
	allowTimeoutMs?: number;
	/** How long to watch the phone after it accepted the restart, for a failure it reports. Default 2 s. */
	settleMs?: number;
	/** This browser's key (made and kept in the browser on first use when not given). */
	key?: AdbKey;
	/** The name the phone files the key under (default "ExpressiveOS Flasher@<host>"). */
	keyName?: string;
	/** The system the browser runs on, for the advice in a failure to open the phone. */
	os?: HostOs;
}

/** A phone connected over USB debugging. */
export interface AdbConnection {
	readonly device: USBDevice;
	/** The USB serial number, the same one the phone shows in Fastboot Mode. */
	readonly serial: string;
	/** ro.product.device: the codename, such as cheetah (what fastboot's getvar product reports). */
	readonly product: string;
	/** ro.product.model, such as Pixel 7 Pro. */
	readonly model: string;
	/** ro.product.name: the build's product name, such as cheetah or lineage_cheetah. */
	readonly name: string;
	/** "device" for a phone running Android ("recovery", "sideload" or "rescue" otherwise). */
	readonly state: string;
	readonly features: readonly string[];
	/**
	 * Asks the phone to restart into Fastboot Mode, then lets go of it. Resolves once the phone
	 * accepted (or dropped off USB right after the request, as a restarting phone does): it then
	 * comes back as a new USB device in Fastboot Mode. Rejects with an AdbError ("refused",
	 * "timeout", "unauthorized" or "usb") when it didn't take the request. The signal defaults
	 * to connectAdb's.
	 */
	rebootToBootloader(opts?: { signal?: AbortSignal }): Promise<void>;
	/** Lets go of the phone, quietly. */
	close(): Promise<void>;
}

function aborted(signal: AbortSignal): unknown {
	return signal.reason ?? new DOMException("Aborted", "AbortError");
}

class Session {
	private readonly reader: MessageReader;
	/** This side's protocol version: the minimum until the phone's CNXN says more. */
	private version = A_VERSION_MIN;
	private pending: Promise<AdbMessage> | null = null;
	private tokens = 0;
	/** The next token gets a signature (the phone may know the key), not the public key. */
	private signNext = true;
	private prompted = false;
	/** An OPEN reboot:bootloader went to the phone. */
	private askedToReboot = false;
	/** The public key went to the phone: waiting for the user. */
	private awaitingUser = false;
	private deadline = 0;
	online = false;
	banner: AdbBanner = { state: "", device: "", model: "", name: "", features: [] };
	closed = false;

	constructor(
		readonly usb: AdbUsb,
		private readonly key: AdbKey,
		private readonly opts: ConnectOptions,
	) {
		this.reader = new MessageReader(usb);
	}

	private get answerMs() {
		return this.opts.answerTimeoutMs ?? 10_000;
	}

	private get allowMs() {
		return this.opts.allowTimeoutMs ?? 3 * 60_000;
	}

	private async send(command: number, arg0: number, arg1: number, payload: Uint8Array = new Uint8Array(0)): Promise<void> {
		const m = { command, arg0, arg1, payload };
		await this.usb.write(encodeHeader(m, this.version < A_VERSION_SKIP_CHECKSUM));
		if (payload.byteLength) await this.usb.write(payload);
	}

	/**
	 * The next message, or a failure when the deadline passes or the signal fires. A read left
	 * behind is picked up by the next call, with what it got if it finished in between; after a
	 * failure the session is closed, which ends it.
	 */
	private next(deadline: number, signal: AbortSignal | undefined, late: () => unknown): Promise<AdbMessage> {
		const read = (this.pending ??= this.reader.next());
		return new Promise<AdbMessage>((resolve, reject) => {
			let timer: ReturnType<typeof setTimeout> | undefined;
			let done = false;
			const finish = (err: unknown, m?: AdbMessage) => {
				if (done) return;
				done = true;
				clearTimeout(timer);
				signal?.removeEventListener("abort", onAbort);
				if (m) resolve(m);
				else reject(err);
			};
			// A read whose caller stopped waiting keeps its message (or failure) for the next call
			const take = () => {
				if (done) return false;
				if (this.pending === read) this.pending = null;
				return true;
			};
			const onAbort = () => finish(aborted(signal!));
			if (signal?.aborted) return onAbort();
			signal?.addEventListener("abort", onAbort);
			if (Number.isFinite(deadline)) timer = setTimeout(() => finish(late()), Math.max(0, deadline - Date.now()));
			read.then(
				(m) => take() && finish(null, m),
				(e) => take() && finish(e),
			);
		});
	}

	private noAnswer(what: "connect" | "reboot" = "connect"): AdbError {
		if (this.awaitingUser) {
			return new AdbError("unauthorized", 'The phone didn\'t allow USB debugging in time. Unlock the phone, tap Allow when it asks "Allow USB debugging?", then try again.');
		}
		if (what === "reboot") return new AdbError("timeout", "The phone didn't answer the request to restart into Fastboot Mode. Unplug it, plug it back in and try again.");
		return new AdbError("timeout", "The phone didn't answer over USB debugging. Unplug it, plug it back in and try again.");
	}

	/**
	 * Reads away what the phone sent to an earlier connection that let go without reading it, then
	 * sends this side's CNXN. A phone keeps its unread writes queued on USB across connections: a
	 * CNXN for an Allow tapped after the page stopped waiting, or the token for a CNXN whose
	 * connection closed once it was online (Detect does that). Read here, a stale token would be
	 * signed after the phone made a new one, and the phone would ask "Allow USB debugging?" for a
	 * key it trusts. Nothing can belong to this connection before its CNXN, and what is queued comes
	 * at once, so the pipe is read until it's quiet. The read left waiting takes the phone's answer.
	 */
	async start(signal?: AbortSignal): Promise<void> {
		const until = Date.now() + this.answerMs;
		for (;;) {
			try {
				await this.next(Math.min(until, Date.now() + DRAIN_QUIET_MS), signal, () => QUIET);
			} catch (e) {
				if (e === QUIET) break;
				throw e;
			}
			if (Date.now() >= until) break;
		}
		this.deadline = Date.now() + this.answerMs;
		await this.send(A_CNXN, A_VERSION, MAX_PAYLOAD, HOST_BANNER);
	}

	/**
	 * Handles CNXN, AUTH and STLS, which can come at any time: a phone asks for the key again
	 * when it sees a new CNXN, and an Allow tapped for an earlier connection the page stopped
	 * waiting for sends a CNXN when it's tapped (start() reads away one that's already queued).
	 * Anything else is left alone.
	 */
	private async handshake(m: AdbMessage): Promise<void> {
		switch (m.command) {
			case A_CNXN: {
				if (m.arg0 < A_VERSION_MIN) throw malformed(`a CNXN of version 0x${m.arg0.toString(16)}, older than any adb`);
				this.version = Math.min(m.arg0, A_VERSION);
				this.banner = parseBanner(dec.decode(m.payload));
				this.online = true;
				this.awaitingUser = false;
				this.signNext = true;
				return;
			}
			case A_STLS:
				throw new AdbError("protocol", "USB debugging on the phone asked for an encrypted connection, which this page can't make over USB. Unplug the phone, plug it back in and try again.");
			case A_AUTH: {
				if (m.arg0 !== AUTH_TOKEN) throw malformed(`an AUTH message of type ${m.arg0}, where a token was expected`);
				if (m.payload.byteLength !== TOKEN_SIZE) throw malformed(`a token of ${m.payload.byteLength} bytes instead of ${TOKEN_SIZE}`);
				this.online = false;
				if (++this.tokens > MAX_TOKENS) {
					throw new AdbError(
						"unauthorized",
						"The phone didn't accept this browser's key for USB debugging. On the phone, open Developer options and tap Revoke USB debugging authorizations, then try again and tap Allow.",
					);
				}
				// As adb does with one key: sign the token; when the phone asks again, it doesn't know
				// the key, so offer it, and the phone asks the user
				if (this.signNext) {
					this.signNext = false;
					await this.send(A_AUTH, AUTH_SIGNATURE, 0, this.key.sign(m.payload));
					if (!this.awaitingUser) this.deadline = Date.now() + this.answerMs;
				} else {
					this.signNext = true;
					await this.send(A_AUTH, AUTH_RSAPUBLICKEY, 0, this.key.publicKeyPayload(this.opts.keyName ?? defaultKeyName()));
					this.awaitingUser = true;
					this.deadline = this.allowMs > 0 ? Date.now() + this.allowMs : Infinity;
					if (!this.prompted) {
						this.prompted = true;
						this.opts.onAllowPrompt?.();
					}
				}
			}
		}
	}

	/** Reads until the phone's CNXN. Anything else that comes first is ignored, as protocol.txt says. */
	async untilOnline(signal?: AbortSignal): Promise<void> {
		while (!this.online) {
			const m = await this.next(this.deadline, signal, () => this.noAnswer());
			await this.handshake(m);
		}
	}

	/**
	 * OPEN reboot:bootloader, then what the phone says: OKAY when it took the request (and maybe
	 * CLSE, or nothing as it shuts down), CLSE alone when it refused. "again" when the phone
	 * started over first, so it ignored the request.
	 */
	private async requestReboot(signal?: AbortSignal): Promise<"done" | "again"> {
		await this.send(A_OPEN, LOCAL_ID, 0, enc.encode(`${REBOOT_SERVICE}\0`));
		this.askedToReboot = true;
		let accepted = false;
		let output = "";
		let deadline = Date.now() + this.answerMs;
		for (;;) {
			let m: AdbMessage;
			try {
				m = await this.next(deadline, signal, () => (accepted ? SETTLED : this.noAnswer("reboot")));
			} catch (e) {
				if (e === SETTLED) return "done";
				throw e;
			}
			if (m.command === A_OKAY && m.arg1 === LOCAL_ID && !accepted) {
				accepted = true;
				// /system/bin/reboot waits for the phone to go down, so a CLSE rarely comes: watch a
				// moment for a failure it reports, then let go
				deadline = Date.now() + (this.opts.settleMs ?? 2000);
			} else if (m.command === A_WRTE && m.arg1 === LOCAL_ID) {
				output += dec.decode(m.payload);
				await this.send(A_OKAY, LOCAL_ID, m.arg0);
			} else if (m.command === A_CLSE && m.arg1 === LOCAL_ID) {
				const said = output.trim().replace(/\s+/g, " ");
				if (accepted && !said) return "done";
				throw new AdbError(
					"refused",
					`The phone didn't restart into Fastboot Mode when asked over USB debugging. Turn the phone off. Then hold Power and Volume down together until you see Fastboot Mode.${said ? ` The phone said: ${said}` : ""}`,
				);
			} else if (!accepted && (m.command === A_AUTH || m.command === A_CNXN || m.command === A_STLS)) {
				// The phone started over (it read a CNXN of ours after the one it answered, or the user
				// allowed an earlier connection): connect again, then ask again. It dropped this OPEN
				// (adbd takes one only while online), so losing the phone before the next OPEN (while
				// the user is asked to allow it, for one) isn't the restart
				this.askedToReboot = false;
				await this.handshake(m);
				return "again";
			}
		}
	}

	async rebootToBootloader(signal?: AbortSignal): Promise<void> {
		if (this.closed) throw new AdbError("usb", "The connection to the phone is closed. Connect again.");
		try {
			for (let tries = 0; ; tries++) {
				await this.untilOnline(signal);
				if ((await this.requestReboot(signal)) === "done") return;
				if (tries >= MAX_REOPENS) throw new AdbError("refused", "The phone kept starting over instead of restarting into Fastboot Mode. Unplug it, plug it back in and try again.");
			}
		} catch (e) {
			// A phone that restarts drops off USB: once it was asked, losing it is the restart
			if (this.askedToReboot && e instanceof AdbError && e.kind === "usb") return;
			throw e;
		} finally {
			await this.close();
		}
	}

	async close(): Promise<void> {
		this.closed = true;
		await this.usb.close();
	}
}

/**
 * Connects to a phone running Android with USB debugging on: opens its ADB interface, then
 * proves this browser's key, or offers it to the phone and waits (up to allowTimeoutMs) for the
 * user to tap Allow. The phone's product, model and name come from its CNXN banner.
 *
 * Fails with an AdbError: "access" or "in-use" when the browser can't have the interface (an adb
 * server on the computer is the usual reason), "timeout" when the phone doesn't answer,
 * "unauthorized" when the user doesn't allow it, "protocol" or "usb" otherwise. The signal's
 * reason when it fires.
 */
export async function connectAdb(device: USBDevice, opts: ConnectOptions = {}): Promise<AdbConnection> {
	const { signal } = opts;
	if (signal?.aborted) throw aborted(signal);
	const key = opts.key ?? (await browserAdbKey());
	if (signal?.aborted) throw aborted(signal);
	const usb = await AdbUsb.open(device, opts.os);
	const session = new Session(usb, key, opts);
	try {
		await session.start(signal);
		await session.untilOnline(signal);
	} catch (e) {
		await session.close();
		throw e;
	}
	const b = session.banner;
	return {
		device,
		serial: device.serialNumber ?? "",
		product: b.device,
		model: b.model,
		name: b.name,
		state: b.state,
		features: b.features,
		rebootToBootloader: (o) => session.rebootToBootloader(o?.signal ?? signal),
		close: () => session.close(),
	};
}
