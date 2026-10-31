// The page's side of the download worker, and the downloaded builds kept in the browser.

import type { WorkerPhase, WorkerReply, WorkerRequest } from "./protocol.ts";

export class StoreError extends Error {
	constructor(
		readonly code: Extract<WorkerReply, { type: "error" }>["code"],
		message: string,
	) {
		super(message);
		this.name = "StoreError";
	}
}

export interface Progress {
	phase: WorkerPhase;
	done: number;
	total: number;
}

function run(req: WorkerRequest, onProgress: (p: Progress) => void, signal?: AbortSignal, onRetry?: (attempt: number, reason: string) => void): Promise<Extract<WorkerReply, { type: "done" }>> {
	const worker = new Worker(new URL("./download.worker.ts", import.meta.url), { type: "module" });
	return new Promise((resolve, reject) => {
		const end = () => setTimeout(() => worker.terminate(), 50);
		signal?.addEventListener("abort", () => worker.postMessage({ type: "cancel" } satisfies WorkerRequest));
		worker.onmessage = (ev: MessageEvent<WorkerReply>) => {
			const m = ev.data;
			if (m.type === "progress") onProgress(m);
			else if (m.type === "retrying") onRetry?.(m.attempt, m.reason);
			else if (m.type === "done") {
				end();
				resolve(m);
			} else if (m.type === "error") {
				end();
				reject(new StoreError(m.code, m.message));
			}
		};
		worker.onerror = (ev) => {
			end();
			reject(new StoreError("other", ev.message || "The download worker stopped"));
		};
		worker.postMessage(req);
	});
}

/** A release file's place in the browser: named by its SHA-256, so a name means one content. */
export const storeName = (sha256: string, ext: string) => `${sha256}.${ext}`;
const okName = (name: string) => `${name}.ok`;

async function dir(): Promise<FileSystemDirectoryHandle> {
	const root = await navigator.storage.getDirectory();
	return root.getDirectoryHandle("releases", { create: true });
}

export function storageSupported(): boolean {
	return typeof navigator !== "undefined" && !!navigator.storage?.getDirectory && typeof Worker !== "undefined";
}

/** A finished, checked download, or null. */
export async function storedFile(name: string, size: number): Promise<File | null> {
	try {
		const d = await dir();
		await d.getFileHandle(okName(name));
		const f = await (await d.getFileHandle(name)).getFile();
		return f.size === size ? f : null;
	} catch {
		return null;
	}
}

/** Bytes of a download that's partly done (0 when none). */
export async function partialSize(name: string): Promise<number> {
	try {
		return (await (await (await dir()).getFileHandle(name)).getFile()).size;
	} catch {
		return 0;
	}
}

export async function downloadRelease(
	url: string,
	name: string,
	size: number,
	sha256: string,
	onProgress: (p: Progress) => void,
	signal?: AbortSignal,
	onRetry?: (attempt: number, reason: string) => void,
): Promise<File> {
	// Asks the browser not to clear this site's storage when the disk gets full (it decides itself)
	await navigator.storage.persist?.().catch(() => false);
	const d = await dir();
	await d.removeEntry(okName(name)).catch(() => {});
	await run({ type: "download", url, name, size, sha256 }, onProgress, signal, onRetry);
	await d.getFileHandle(okName(name), { create: true });
	const f = await storedFile(name, size);
	if (!f) throw new StoreError("other", "The download finished but can't be read back");
	return f;
}

export async function hashFile(file: File, onProgress: (p: Progress) => void, signal?: AbortSignal): Promise<string> {
	const r = await run({ type: "hash", file }, onProgress, signal);
	return r.sha256!;
}

export async function crcCheck(file: File, entries: Array<{ name: string; offset: number; size: number; crc32: number }>, onProgress: (p: Progress) => void, signal?: AbortSignal): Promise<string[]> {
	const r = await run({ type: "crc", file, entries }, onProgress, signal);
	return r.bad ?? [];
}

export async function removeStored(name: string): Promise<void> {
	const d = await dir();
	await d.removeEntry(okName(name)).catch(() => {});
	await d.removeEntry(name).catch(() => {});
}

/** Everything kept in the browser, with sizes. */
export async function listStored(): Promise<Array<{ name: string; size: number; complete: boolean }>> {
	const out: Array<{ name: string; size: number; complete: boolean }> = [];
	try {
		const d = await dir();
		const names: string[] = [];
		for await (const [n] of (d as unknown as { entries(): AsyncIterable<[string, FileSystemHandle]> }).entries()) names.push(n);
		for (const n of names) {
			if (n.endsWith(".ok") || n.endsWith(".crswap")) continue;
			const f = await (await d.getFileHandle(n)).getFile();
			out.push({ name: n, size: f.size, complete: names.includes(okName(n)) });
		}
	} catch {
		/* no storage */
	}
	return out;
}

/** Fetches a small file (the stock init_boot) into memory and checks its SHA-256. */
export async function fetchVerified(url: string, size: number, sha256: string, signal?: AbortSignal): Promise<Blob> {
	const res = await fetch(url, { cache: "no-store", signal });
	if (!res.ok) throw new StoreError("http", `Couldn't download ${url.split("/").pop()} (${res.status})`);
	const buf = await res.arrayBuffer();
	if (buf.byteLength !== size) throw new StoreError("mismatch", `${url.split("/").pop()} isn't the listed size`);
	const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", buf))].map((b) => b.toString(16).padStart(2, "0")).join("");
	if (digest !== sha256) throw new StoreError("mismatch", `${url.split("/").pop()} doesn't match its SHA-256`);
	return new Blob([buf]);
}

export async function sha256Of(blob: Blob): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
