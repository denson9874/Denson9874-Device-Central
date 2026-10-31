// A phone in fastboot mode, across restarts: commands, variables, slots, restarting into the
// bootloader or fastbootd and finding the same phone again.

import { type CommandOptions, FastbootClient, FastbootError, type Logger, ProtocolError, type Transport } from "./client.ts";

/** An open connection to the phone. */
export interface Link {
	transport: Transport;
	serial: string;
	close(): Promise<void>;
}

/** Restarts the phone and finds it again (WebUSB in the browser, a simulator in tests). */
export interface Connector {
	/**
	 * Runs `send` (the restart command), waits for the phone to drop off USB and to come back in
	 * fastboot mode, and returns the new connection.
	 */
	restart(link: Link, send: () => Promise<void>, signal?: AbortSignal): Promise<Link>;
	/** Sends a final restart (into Android) and lets go of the phone. */
	release(link: Link, send: () => Promise<void>): Promise<void>;
}

export type Mode = "bootloader" | "fastbootd";

export class Phone {
	client: FastbootClient;
	private vars = new Map<string, string | null>();

	constructor(
		public link: Link,
		private readonly connector: Connector,
		private readonly log: Logger = () => {},
	) {
		this.client = new FastbootClient(link.transport, log);
	}

	get serial(): string {
		return this.link.serial;
	}

	command(cmd: string, opts?: CommandOptions) {
		return this.client.command(cmd, opts);
	}

	getVar(name: string): Promise<string | null> {
		return this.client.getVar(name);
	}

	/** Variables that don't change until the phone restarts, read once per session. */
	async cachedVar(name: string): Promise<string | null> {
		if (!this.vars.has(name)) this.vars.set(name, await this.getVar(name));
		return this.vars.get(name)!;
	}

	async mode(): Promise<Mode> {
		return (await this.cachedVar("is-userspace")) === "yes" ? "fastbootd" : "bootloader";
	}

	async maxDownload(): Promise<number> {
		const v = await this.cachedVar("max-download-size");
		const n = v ? (/^0x/i.test(v) ? parseInt(v, 16) : /^[0-9a-f]+$/i.test(v) && /[a-f]/i.test(v) ? parseInt(v, 16) : parseInt(v, 10)) : NaN;
		// fastboot's own default when a bootloader doesn't say
		return Number.isFinite(n) && n > 0 ? Math.min(n, 0xffffffff) : 512 * 1024 * 1024;
	}

	async slots(): Promise<{ current: string; other: string } | null> {
		const count = Number(await this.cachedVar("slot-count"));
		const current = (await this.cachedVar("current-slot"))?.replace(/^_/, "") ?? "";
		if (!(count >= 2) || !/^[a-z]$/.test(current)) return null;
		return { current, other: current === "a" ? "b" : "a" };
	}

	/**
	 * The partition's name on the phone: with the current or other slot's suffix when it has
	 * slots (do_for_partition in fastboot.cpp).
	 */
	async partitionName(partition: string, slot: "current" | "other"): Promise<string> {
		const hasSlot = await this.cachedVar(`has-slot:${partition}`);
		if (hasSlot !== "yes") {
			if (slot === "other") throw new ProtocolError(`${partition} has no slots, so there's no other slot to write`);
			return partition;
		}
		const s = await this.slots();
		if (!s) throw new ProtocolError("Couldn't tell which slot the phone is using");
		return `${partition}_${slot === "current" ? s.current : s.other}`;
	}

	private reset(link: Link) {
		this.link = link;
		this.client = new FastbootClient(link.transport, this.log);
		this.vars.clear();
	}

	/** Restarts into the bootloader or fastbootd and checks it's the same phone in the right mode. */
	async restartInto(target: Mode, signal?: AbortSignal): Promise<void> {
		const cmd = target === "fastbootd" ? "reboot-fastboot" : "reboot-bootloader";
		const serial = this.serial;
		this.log("note", `Restarting into ${target === "fastbootd" ? "fastbootd" : "the bootloader"}`);
		const link = await this.connector.restart(this.link, () => this.sendRestart(cmd), signal);
		this.reset(link);
		const sn = await this.getVar("serialno");
		if (serial && sn && sn !== serial) throw new ProtocolError(`A different phone (${sn}) answered after the restart`);
		if ((await this.mode()) !== target) {
			throw new ProtocolError(
				target === "fastbootd"
					? "The phone didn't start fastbootd. One of the images written so far may be broken; start the install again."
					: "The phone didn't return to the bootloader",
			);
		}
	}

	/** Starts Android and lets go of the phone. */
	async restartIntoAndroid(): Promise<void> {
		await this.connector.release(this.link, () => this.sendRestart("reboot"));
	}

	private async sendRestart(cmd: string) {
		try {
			await this.client.command(cmd, { timeoutMs: 10_000 });
		} catch (e) {
			// Some bootloaders restart before they answer; a refusal is a real error
			if (e instanceof FastbootError) throw e;
		}
	}
}
