// The fastboot wire protocol over a byte transport (WebUSB in the browser, a simulated phone in
// the tests): text commands, OKAY/FAIL/INFO/TEXT/DATA replies and the download data phase.
// Written from AOSP's protocol description (system/core/fastboot/README.md) and its host tool.

/** One USB bulk pipe each way. */
export interface Transport {
	send(data: Uint8Array): Promise<void>;
	/** One bulk IN transfer of at most `maxLength` bytes. */
	receive(maxLength: number): Promise<Uint8Array>;
	/**
	 * The session stopped part way through a command (a download not finished, or a reply not
	 * read), so the phone may still be waiting for bytes or holding a late reply. The next
	 * connection to it should reset it first.
	 */
	abandon?(): void;
}

/** Bytes to send in a download: in-memory pieces and Blob slices read lazily from disk. */
export type Part = Uint8Array | Blob;
export interface Payload {
	size: number;
	parts: Part[];
}

export function payloadOf(parts: Part[]): Payload {
	let size = 0;
	for (const p of parts) size += p instanceof Blob ? p.size : p.byteLength;
	return { size, parts };
}

/** The phone answered FAIL. */
export class FastbootError extends Error {
	constructor(
		readonly command: string,
		readonly reply: string,
	) {
		super(`The phone refused "${command}": ${reply || "no reason given"}`);
		this.name = "FastbootError";
	}
}

/** The phone didn't answer in time, or answered something that isn't fastboot. */
export class ProtocolError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "ProtocolError";
	}
}

export type LogKind = "cmd" | "info" | "okay" | "fail" | "data" | "note";
export type Logger = (kind: LogKind, text: string) => void;

// Replies are at most 256 bytes; asking for more never overflows a bulk IN transfer
const REPLY_MAX = 4096;
// Old bootloaders take commands of at most 64 bytes, and every command here fits
const COMMAND_MAX = 64;
/**
 * Bytes per USB transfer while downloading: AOSP fastboot's Linux size (it uses 1 MiB on Windows
 * and macOS). Linux's usbfs allows 16 MiB in flight in all, and Chrome refuses over 32 MiB.
 */
export const DEFAULT_TRANSFER_SIZE = 256 * 1024;

export interface CommandOptions {
	/** How long to wait for the final reply; 0 waits as long as it takes (a user decision). */
	timeoutMs?: number;
	onInfo?: (text: string) => void;
}

export interface CommandResult {
	/** The OKAY reply's text. */
	text: string;
	/** INFO and TEXT lines that came before it. */
	info: string[];
}

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
	if (!ms) return p;
	let timer: ReturnType<typeof setTimeout> | undefined;
	return Promise.race([
		p.finally(() => clearTimeout(timer)),
		new Promise<T>((_, reject) => {
			timer = setTimeout(
				() =>
					reject(
						new ProtocolError(
							`The phone didn't answer "${what}" within ${Math.round(ms / 1000)} s. Restart it into Fastboot Mode by holding Power and Volume down until it restarts, then connect again.`,
						),
					),
				ms,
			);
		}),
	]);
}

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export class FastbootClient {
	/**
	 * Set once a command stopped part way (a reply timed out or couldn't be read, or a download
	 * couldn't be finished): the pipe may hold a stale reply, or the phone may still be waiting
	 * for bytes, so the session is over.
	 */
	private broken = false;
	transferSize = DEFAULT_TRANSFER_SIZE;

	constructor(
		private readonly transport: Transport,
		private readonly log: Logger = () => {},
	) {}

	private breakSession() {
		if (this.broken) return;
		this.broken = true;
		this.transport.abandon?.();
	}

	private check(cmd: string) {
		if (this.broken) throw new ProtocolError("The connection to the phone was lost; reconnect it to go on");
		if (cmd.length > COMMAND_MAX) throw new ProtocolError(`Command too long: ${cmd}`);
		if (!/^[\x20-\x7e]+$/.test(cmd)) throw new ProtocolError(`Bad command: ${JSON.stringify(cmd)}`);
	}

	/** Reads replies until OKAY, FAIL or DATA. */
	private async readReply(cmd: string, opts: CommandOptions): Promise<{ status: "OKAY" | "DATA"; text: string; info: string[] }> {
		const info: string[] = [];
		const read = async () => {
			for (;;) {
				const packet = await this.transport.receive(REPLY_MAX);
				const reply = decoder.decode(packet);
				const status = reply.slice(0, 4);
				const text = reply.slice(4);
				switch (status) {
					case "INFO":
					case "TEXT":
						this.log("info", text);
						info.push(text);
						opts.onInfo?.(text);
						break;
					case "OKAY":
						this.log("okay", text);
						return { status, text, info } as const;
					case "DATA":
						this.log("data", text);
						return { status, text, info } as const;
					case "FAIL":
						this.log("fail", text);
						throw new FastbootError(cmd, text);
					default:
						throw new ProtocolError(`Unexpected reply to "${cmd}": ${JSON.stringify(reply.slice(0, 80))}`);
				}
			}
		};
		try {
			return await withTimeout(read(), opts.timeoutMs ?? 30_000, cmd);
		} catch (e) {
			// FAIL ends the command cleanly; anything else leaves its reply unaccounted for
			if (!(e instanceof FastbootError)) this.breakSession();
			throw e;
		}
	}

	private async sendCommand(cmd: string) {
		this.check(cmd);
		this.log("cmd", cmd);
		try {
			await this.transport.send(encoder.encode(cmd));
		} catch (e) {
			// Whether the phone took the command is unknown
			this.breakSession();
			throw e;
		}
	}

	/** Sends one command and waits for OKAY; FAIL throws FastbootError. */
	async command(cmd: string, opts: CommandOptions = {}): Promise<CommandResult> {
		await this.sendCommand(cmd);
		const r = await this.readReply(cmd, opts);
		if (r.status !== "OKAY") {
			this.breakSession();
			throw new ProtocolError(`The phone asked for data after "${cmd}"`);
		}
		return { text: r.text, info: r.info };
	}

	/** A bootloader variable, or null when the phone doesn't have it (FAIL). */
	async getVar(name: string): Promise<string | null> {
		try {
			const r = await this.command(`getvar:${name}`, { timeoutMs: 10_000 });
			return r.text.trim();
		} catch (e) {
			if (e instanceof FastbootError) return null;
			throw e;
		}
	}

	/**
	 * Sends a payload into the phone's download buffer (`download:%08x`, then the bytes). The
	 * caller follows with the command that uses it (flash, update-super...).
	 */
	async download(payload: Payload, onProgress: (sent: number) => void = () => {}, signal?: AbortSignal): Promise<void> {
		if (payload.size <= 0 || payload.size > 0xffffffff) throw new ProtocolError(`Can't send ${payload.size} bytes in one download`);
		const cmd = `download:${payload.size.toString(16).padStart(8, "0")}`;
		await this.sendCommand(cmd);
		const r = await this.readReply(cmd, { timeoutMs: 30_000 });
		if (r.status !== "DATA") {
			this.breakSession();
			throw new ProtocolError(`The phone didn't accept the download (${r.status} ${r.text})`);
		}
		const want = parseInt(r.text, 16);
		if (want !== payload.size) {
			this.breakSession();
			throw new ProtocolError(`The phone wants ${want} bytes, not ${payload.size}`);
		}
		let sent = 0;
		let sending = false;
		// Read the next piece from disk while the current one goes over USB
		const pieces = readPieces(payload, this.transferSize);
		let next = pieces.next();
		try {
			for (;;) {
				const cur = await next;
				if (cur.done) break;
				next = pieces.next();
				if (signal?.aborted) throw signal.reason ?? new DOMException("Aborted", "AbortError");
				sending = true;
				await this.transport.send(cur.value);
				sending = false;
				sent += cur.value.byteLength;
				onProgress(sent);
			}
			if (sent !== payload.size) throw new ProtocolError(`Read ${sent} of ${payload.size} bytes of the image`);
		} catch (e) {
			void next.catch(() => {});
			// The phone is still waiting for the rest of the bytes. When USB failed, nothing more
			// can be sent. When this side stopped (the image couldn't be read, or the install was
			// stopped), zeros make up the rest so the phone is ready for the next command; nothing
			// writes them anywhere.
			if (sending || !(await this.finishWithZeros(cmd, payload.size - sent))) this.breakSession();
			throw e;
		}
		await this.readReply(cmd, { timeoutMs: 60_000 });
	}

	/** Ends a download's data phase with zeros; false when that failed too. */
	private async finishWithZeros(cmd: string, left: number): Promise<boolean> {
		try {
			this.log("note", `Finishing the download with ${left} empty bytes`);
			const zeros = new Uint8Array(Math.min(left, this.transferSize));
			for (; left > 0; left -= zeros.byteLength) await this.transport.send(left < zeros.byteLength ? zeros.subarray(0, left) : zeros);
			await this.readReply(cmd, { timeoutMs: 60_000 });
			return true;
		} catch (e) {
			return e instanceof FastbootError;
		}
	}

	get isBroken() {
		return this.broken;
	}
}

/** Splits a payload into transfer-sized pieces, reading Blob slices on demand. */
async function* readPieces(payload: Payload, size: number): AsyncGenerator<Uint8Array> {
	let buf: Uint8Array = new Uint8Array(0);
	const flush = function* () {
		while (buf.byteLength >= size) {
			yield buf.subarray(0, size);
			buf = buf.subarray(size);
		}
	};
	const append = (b: Uint8Array) => {
		if (buf.byteLength === 0) {
			buf = b;
			return;
		}
		const n = new Uint8Array(buf.byteLength + b.byteLength);
		n.set(buf, 0);
		n.set(b, buf.byteLength);
		buf = n;
	};
	for (const part of payload.parts) {
		if (part instanceof Blob) {
			for (let off = 0; off < part.size; off += size) {
				const end = Math.min(part.size, off + size);
				append(new Uint8Array(await part.slice(off, end).arrayBuffer()));
				yield* flush();
			}
		} else {
			append(part);
			yield* flush();
		}
	}
	if (buf.byteLength) yield buf;
}
