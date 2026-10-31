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

const cancelled = () => new StoreError("cancelled", "Cancelled");

function run(req: WorkerRequest, onProgress: (p: Progress) => void, signal?: AbortSignal, onRetry?: (attempt: number, reason: string) => void): Promise<Extract<WorkerReply, { type: "done" }>> {
	// A Pause or Cancel pressed before the worker exists would never reach it
	if (signal?.aborted) return Promise.reject(cancelled());
	const worker = new Worker(new URL("./download.worker.ts", import.meta.url), { type: "module" });
	return new Promise((resolve, reject) => {
		const cancel = () => worker.postMessage({ type: "cancel" } satisfies WorkerRequest);
		const end = () => {
			signal?.removeEventListener("abort", cancel);
			setTimeout(() => worker.terminate(), 50);
		};
		signal?.addEventListener("abort", cancel);
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
// A tab using a stored file holds this Web Lock on it, shared; removing it takes it exclusively
const lockName = (name: string) => `eos-flasher:${name}`;

/** Lets go of a stored file; the promise settles once other tabs could remove it. */
export type LetGo = () => Promise<void>;

/** A stored file this tab uses: other tabs can't remove it until release() is called. */
export interface Held {
	file: File;
	release: LetGo;
}

/**
 * Marks a stored file as in use by this tab, until the returned function is called. Tabs share
 * the same storage, and an install or a download reads the file for many minutes.
 */
export function holdStored(name: string): Promise<LetGo> {
	const locks = navigator.locks;
	if (!locks) return Promise.resolve(async () => {});
	return new Promise((resolve) => {
		let letGo = () => {};
		let done: Promise<unknown> = Promise.resolve();
		// request() settles once the lock is let go of, which is when another tab may take it
		const release: LetGo = () => {
			letGo();
			return done.then(
				() => {},
				() => {},
			);
		};
		try {
			done = locks.request(lockName(name), { mode: "shared" }, () =>
				new Promise<void>((r) => {
					letGo = r;
					resolve(release);
				}),
			);
		} catch (e) {
			done = Promise.reject(e);
		}
		// Without the lock the file is still usable, only not kept from other tabs
		done.catch(() => resolve(async () => {}));
	});
}

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
): Promise<Held> {
	const release = await holdStored(name);
	try {
		// Asks the browser not to clear this site's storage when the disk gets full (it decides itself)
		await navigator.storage.persist?.().catch(() => false);
		const d = await dir();
		if (signal?.aborted) throw cancelled();
		await d.removeEntry(okName(name)).catch(() => {});
		await run({ type: "download", url, name, size, sha256 }, onProgress, signal, onRetry);
		await d.getFileHandle(okName(name), { create: true });
		const f = await storedFile(name, size);
		if (!f) throw new StoreError("other", "The download finished but can't be read back");
		return { file: f, release };
	} catch (e) {
		await release();
		throw e;
	}
}

/** A finished, checked download, held for this tab (holdStored), or null. */
export async function openStored(name: string, size: number): Promise<Held | null> {
	const release = await holdStored(name);
	const file = await storedFile(name, size);
	if (file) return { file, release };
	await release();
	return null;
}

export async function hashFile(file: File, onProgress: (p: Progress) => void, signal?: AbortSignal): Promise<string> {
	const r = await run({ type: "hash", file }, onProgress, signal);
	return r.sha256!;
}

export async function crcCheck(file: File, entries: Array<{ name: string; offset: number; size: number; crc32: number }>, onProgress: (p: Progress) => void, signal?: AbortSignal): Promise<string[]> {
	const r = await run({ type: "crc", file, entries }, onProgress, signal);
	return r.bad ?? [];
}

/**
 * Removes a stored file, unless a tab is using it (holdStored), and says whether it did. A tab
 * removing its own file lets go of it first.
 */
export async function removeStored(name: string): Promise<boolean> {
	const remove = async () => {
		const d = await dir();
		try {
			await d.removeEntry(name);
		} catch (e) {
			if (!(e instanceof DOMException)) throw e;
			// Open for writing somewhere (a download running in a page without the lock)
			if (e.name === "NoModificationAllowedError" || e.name === "InvalidModificationError") return false;
			if (e.name !== "NotFoundError") throw e;
		}
		await d.removeEntry(okName(name)).catch(() => {});
		return true;
	};
	const locks = navigator.locks;
	if (!locks) return remove();
	return locks.request(lockName(name), { mode: "exclusive", ifAvailable: true }, (lock) => (lock ? remove() : false));
}

export interface StoredEntry {
	name: string;
	size: number;
	complete: boolean;
	/** A tab is using it (an install or a download), so it can't be removed now. */
	inUse: boolean;
}

/** Everything kept in the browser, with sizes. */
export async function listStored(): Promise<StoredEntry[]> {
	const out: StoredEntry[] = [];
	try {
		const state = await navigator.locks?.query().catch(() => null);
		const used = new Set([...(state?.held ?? []), ...(state?.pending ?? [])].map((l) => l.name));
		const d = await dir();
		const names: string[] = [];
		for await (const [n] of (d as unknown as { entries(): AsyncIterable<[string, FileSystemHandle]> }).entries()) names.push(n);
		for (const n of names) {
			if (n.endsWith(".ok") || n.endsWith(".crswap")) continue;
			const f = await (await d.getFileHandle(n)).getFile();
			out.push({ name: n, size: f.size, complete: names.includes(okName(n)), inUse: used.has(lockName(n)) });
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
