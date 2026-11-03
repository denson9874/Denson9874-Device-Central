// Runs an install plan on a phone, step by step, reporting progress.

import { FastbootError } from "../fastboot/client.ts";
import type { Phone } from "../fastboot/device.ts";
import { RESPARSE_LIMIT, flashPayloads, imageInfo, moveAvbFooter } from "../fastboot/images.ts";
import { splitSparse } from "../fastboot/sparse.ts";
import { type SuperImage, SuperLayoutError, buildSuperImage } from "../fastboot/super-image.ts";
import type { FlashSuperStep, ImageRef, Step } from "./plan.ts";

export interface ImageSource {
	image(ref: ImageRef): Promise<Blob>;
	superEmpty(): Promise<Blob>;
	/** Size of an image, for progress weights, without reading it. */
	size(ref: ImageRef): number;
}

export interface RunEvents {
	step(index: number, state: "running" | "done" | "skipped", note?: string): void;
	/** Progress inside the running step, 0..1. */
	progress(index: number, fraction: number): void;
	note(text: string): void;
}

export class InstallError extends Error {
	constructor(
		readonly stepIndex: number,
		readonly step: Step,
		readonly cause: unknown,
	) {
		super(cause instanceof Error ? cause.message : String(cause));
		this.name = "InstallError";
	}
}

/** The phone refused to erase a partition a clean install has to erase. */
export class EraseError extends Error {
	constructor(
		readonly partition: string,
		readonly reply: string,
	) {
		super(
			`The phone couldn't erase ${partition} (${reply || "no reason given"}). A clean install has to erase it, or ExpressiveOS may not start. ` +
				"Try the install again. If it fails the same way, flash the latest factory image with Google's Android Flash Tool, then install ExpressiveOS again.",
		);
		this.name = "EraseError";
	}
}

/** Relative cost of each step, so overall progress moves at an even pace. */
export function stepWeights(steps: Step[], images: ImageSource): number[] {
	const MB = 1024 * 1024;
	return steps.map((s) => {
		switch (s.kind) {
			case "flash":
				return Math.max(images.size(s.image), MB);
			case "reboot":
				return s.target === "fastbootd" ? 400 * MB : 120 * MB;
			case "erase":
				return 40 * MB;
			case "update-super":
				return 20 * MB;
			case "flash-super":
				return s.partitions.reduce((n, p) => n + Math.max(images.size({ kind: "zip", name: p.image }), MB), 0);
			default:
				return 2 * MB;
		}
	});
}

export function parseSize(v: string | null): number {
	if (!v) return 0;
	const s = v.trim();
	const n = /^0x/i.test(s) ? parseInt(s, 16) : parseInt(s, 10);
	return Number.isFinite(n) ? n : 0;
}

/**
 * The sparse image of super for a flash-super step: the phone's own super partition, laid out
 * with the step's images in the current slot (FlashTask::GetPartitionAndSlot names them so).
 * Throws SuperLayoutError when super can't be written from the bootloader.
 */
export async function superImageFor(phone: Phone, s: FlashSuperStep, images: ImageSource): Promise<SuperImage> {
	if ((await phone.mode()) !== "bootloader") throw new SuperLayoutError("the phone isn't in the bootloader");
	const slots = await phone.slots();
	if (!slots) throw new SuperLayoutError("the phone has no A/B slots");
	const name = (await phone.getVar("super-partition-name")) || "super";
	const size = parseSize(await phone.getVar(`partition-size:${name}`));
	const parts: Array<{ name: string; blob: Blob }> = [];
	for (const p of s.partitions) parts.push({ name: `${p.partition}_${slots.current}`, blob: await images.image({ kind: "zip", name: p.image }) });
	const empty = new Uint8Array(await (await images.superEmpty()).arrayBuffer());
	return buildSuperImage(empty, parts, name, size);
}

export async function runPlan(phone: Phone, steps: Step[], images: ImageSource, ev: RunEvents, signal?: AbortSignal): Promise<void> {
	const ensure = async (mode: "bootloader" | "fastbootd") => {
		if ((await phone.mode()) !== mode) await phone.restartInto(mode, signal);
	};

	for (let i = 0; i < steps.length; i++) {
		if (signal?.aborted) throw signal.reason ?? new DOMException("Aborted", "AbortError");
		const s = steps[i];
		ev.step(i, "running");
		try {
			switch (s.kind) {
				case "set-active": {
					const slots = await phone.slots();
					if (!slots) {
						ev.step(i, "skipped", "no A/B slots");
						continue;
					}
					// Marks the slot bootable again if an earlier boot attempt gave up on it
					await phone.command(`set_active:${slots.current}`);
					break;
				}
				case "cancel-snapshot": {
					const st = await phone.getVar("snapshot-update-status");
					if (!st || st === "none") {
						ev.step(i, "skipped", "nothing pending");
						continue;
					}
					await phone.command("snapshot-update:cancel", { timeoutMs: 60_000 });
					break;
				}
				case "reboot":
					// As RebootTask in AOSP's task.cpp: already in fastbootd, nothing to do
					if (s.target === "fastbootd" && (await phone.mode()) === "fastbootd") {
						ev.step(i, "skipped", "already in fastbootd");
						continue;
					}
					await phone.restartInto(s.target, signal);
					break;
				case "update-super": {
					await ensure("fastbootd");
					const name = (await phone.getVar("super-partition-name")) || "super";
					const blob = await images.superEmpty();
					await phone.client.download({ size: blob.size, parts: [blob] }, (n) => ev.progress(i, n / blob.size), signal);
					await phone.command(`update-super:${name}${s.wipe ? ":wipe" : ""}`, { timeoutMs: 120_000 });
					break;
				}
				case "resize-to-zero": {
					await ensure("fastbootd");
					for (const p of s.partitions) {
						const name = await phone.partitionName(p, "current");
						if ((await phone.getVar(`is-logical:${name}`)) === "yes") await phone.command(`resize-logical-partition:${name}:0`);
					}
					break;
				}
				case "flash": {
					if (s.logical) await ensure("fastbootd");
					if (s.slot === "other" && !(await phone.slots())) {
						ev.step(i, "skipped", "no other slot");
						continue;
					}
					const name = await phone.partitionName(s.partition, s.slot);
					let blob = await images.image(s.image);
					const info = await imageInfo(blob);
					const logical = (await phone.mode()) === "fastbootd" && (await phone.getVar(`is-logical:${name}`)) === "yes";
					if (s.logical && !logical && (await phone.mode()) === "fastbootd") {
						throw new Error(`super_empty.img lists ${s.partition}, but the phone has no logical ${name} after laying out the dynamic partitions`);
					}
					if (logical) {
						await phone.command(`resize-logical-partition:${name}:${info.imageSize}`, { timeoutMs: 60_000 });
					} else if (!info.sparse) {
						blob = await moveAvbFooter(blob, parseSize(await phone.getVar(`partition-size:${name}`)));
					}
					const { pieces } = await flashPayloads(blob, await phone.maxDownload());
					const total = pieces.reduce((n, p) => n + p.size, 0);
					let done = 0;
					for (const [k, piece] of pieces.entries()) {
						if (pieces.length > 1) ev.note(`${name}: piece ${k + 1} of ${pieces.length}`);
						await phone.client.download(piece, (n) => ev.progress(i, (done + n) / total), signal);
						await phone.command(`flash:${name}`, { timeoutMs: 10 * 60_000 });
						done += piece.size;
					}
					break;
				}
				case "erase": {
					const type = await phone.getVar(`partition-type:${s.partition}`);
					if (type === null || type === "") {
						ev.step(i, "skipped", `no ${s.partition} partition`);
						continue;
					}
					try {
						await phone.command(`erase:${s.partition}`, { timeoutMs: 5 * 60_000 });
					} catch (e) {
						// fastboot stops here too (Epilog in fastboot.cpp). Android formats userdata and
						// metadata at the first start only when they're blank: a metadata partition left as
						// it was keeps the old system's encryption key, which ExpressiveOS can't use, so the
						// phone would start into recovery's "Cannot load Android system" instead
						if (!(e instanceof FastbootError)) throw e;
						throw new EraseError(s.partition, e.reply);
					}
					break;
				}
				case "flash-super": {
					const image = await superImageFor(phone, s, images);
					const pieces = splitSparse(image.header, image.chunks, Math.min(await phone.maxDownload(), RESPARSE_LIMIT));
					const total = pieces.reduce((n, p) => n + p.size, 0);
					let done = 0;
					for (const [k, piece] of pieces.entries()) {
						if (pieces.length > 1) ev.note(`${image.name}: piece ${k + 1} of ${pieces.length}`);
						await phone.client.download(piece, (n) => ev.progress(i, (done + n) / total), signal);
						await phone.command(`flash:${image.name}`, { timeoutMs: 10 * 60_000 });
						done += piece.size;
					}
					break;
				}
				case "start-android":
					await phone.restartIntoAndroid();
					break;
			}
		} catch (e) {
			throw new InstallError(i, s, e);
		}
		ev.progress(i, 1);
		ev.step(i, "done");
	}
}
