/// <reference lib="webworker" />
// Downloads a release into the browser's private storage (the origin private file system) and
// checks its SHA-256 as the bytes arrive. A sync access handle writes in place, so whatever has
// been written survives a closed tab and the download resumes from there with a range request.
// Also hashes a zip the user picked from their own disk.

import { createCRC32, createSHA256 } from "hash-wasm";
import type { WorkerReply, WorkerRequest } from "./protocol.ts";

declare const self: DedicatedWorkerGlobalScope;

const READ = 8 * 1024 * 1024;
const FLUSH_EVERY = 64 * 1024 * 1024;
const MAX_ATTEMPTS = 12;

let abort = new AbortController();
const post = (m: WorkerReply) => self.postMessage(m);

class Failure extends Error {
	constructor(
		readonly code: Extract<WorkerReply, { type: "error" }>["code"],
		message: string,
	) {
		super(message);
	}
}

function progressPoster(phase: Extract<WorkerReply, { type: "progress" }>["phase"], total: number) {
	let last = 0;
	return (done: number, force = false) => {
		const now = performance.now();
		if (force || now - last > 100) {
			last = now;
			post({ type: "progress", phase, done, total });
		}
	};
}

const sleep = (ms: number, signal: AbortSignal) =>
	new Promise<void>((resolve, reject) => {
		const t = setTimeout(resolve, ms);
		signal.addEventListener("abort", () => {
			clearTimeout(t);
			reject(new Failure("cancelled", "Cancelled"));
		});
	});

async function download(req: Extract<WorkerRequest, { type: "download" }>) {
	const signal = abort.signal;
	const root = await navigator.storage.getDirectory();
	const dir = await root.getDirectoryHandle("releases", { create: true });
	const fh = await dir.getFileHandle(req.name, { create: true });
	let h: FileSystemSyncAccessHandle;
	try {
		h = await fh.createSyncAccessHandle();
	} catch {
		throw new Failure("busy", "This build is already downloading in another tab or window");
	}
	try {
		const hasher = await createSHA256();
		let size = h.getSize();
		if (size > req.size) {
			h.truncate(0);
			size = 0;
		}
		// What's already on disk from an earlier visit counts once its bytes are hashed again
		if (size > 0) {
			const tick = progressPoster("checking", size);
			const buf = new Uint8Array(READ);
			for (let off = 0; off < size; ) {
				if (signal.aborted) throw new Failure("cancelled", "Cancelled");
				const n = h.read(buf.subarray(0, Math.min(READ, size - off)), { at: off });
				if (n <= 0) break;
				hasher.update(buf.subarray(0, n));
				off += n;
				tick(off);
			}
		}
		const tick = progressPoster("downloading", req.size);
		tick(size, true);
		let attempt = 0;
		let lastFlush = size;
		while (size < req.size) {
			try {
				const res = await fetch(req.url, {
					headers: size > 0 ? { Range: `bytes=${size}-` } : {},
					cache: "no-store",
					signal,
				});
				if (res.status === 404 || res.status === 410) throw new Failure("http", "This build is no longer on the server. Reload the page to see the current builds.");
				if (size > 0 && res.status === 200) {
					// The server sent the whole file instead of the rest: start again from the top
					h.truncate(0);
					size = 0;
					lastFlush = 0;
					hasher.init();
				} else if (res.status === 206) {
					const m = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(res.headers.get("Content-Range") ?? "");
					if (!m || Number(m[1]) !== size || Number(m[3]) !== req.size) throw new Failure("mismatch", "The server's copy of this build isn't the one listed (its size changed)");
				} else if (res.status !== 200) {
					throw new Error(`The server answered ${res.status}`);
				}
				if (res.status === 200) {
					const len = Number(res.headers.get("Content-Length") ?? NaN);
					if (Number.isFinite(len) && len !== req.size) throw new Failure("mismatch", "The server's copy of this build isn't the one listed (its size differs)");
				}
				if (!res.body) throw new Error("Empty response");
				const reader = res.body.getReader();
				for (;;) {
					const { value, done } = await reader.read();
					if (done) break;
					if (size + value.byteLength > req.size) throw new Failure("mismatch", "The server sent more than the listed size");
					let written = 0;
					while (written < value.byteLength) {
						const n = h.write(value.subarray(written), { at: size + written });
						if (n <= 0) throw new Failure("quota", "Couldn't write to the browser's storage");
						written += n;
					}
					hasher.update(value);
					size += value.byteLength;
					if (size - lastFlush >= FLUSH_EVERY) {
						h.flush();
						lastFlush = size;
					}
					attempt = 0;
					tick(size);
				}
				h.flush();
				lastFlush = size;
				if (size < req.size) throw new Error("The connection closed early");
			} catch (e) {
				if (e instanceof DOMException && e.name === "QuotaExceededError") {
					throw new Failure("quota", "There isn't enough space for this build in the browser's storage");
				}
				if (e instanceof Failure || signal.aborted) throw e instanceof Failure ? e : new Failure("cancelled", "Cancelled");
				attempt++;
				if (attempt > MAX_ATTEMPTS) throw new Failure("network", `The download keeps failing: ${e instanceof Error ? e.message : e}`);
				post({ type: "retrying", attempt, reason: e instanceof Error ? e.message : String(e) });
				h.flush();
				await sleep(Math.min(30_000, 1000 * 2 ** Math.min(attempt, 5)), signal);
			}
		}
		tick(size, true);
		post({ type: "progress", phase: "verifying", done: 1, total: 1 });
		const digest = hasher.digest("hex");
		if (digest !== req.sha256) {
			h.truncate(0);
			h.flush();
			throw new Failure("mismatch", "The downloaded file doesn't match the build's SHA-256, so it was thrown away. Try again.");
		}
		post({ type: "done", sha256: digest });
	} finally {
		h.close();
	}
}

async function hashFile(file: File) {
	const signal = abort.signal;
	const hasher = await createSHA256();
	const tick = progressPoster("hashing", file.size);
	for (let off = 0; off < file.size; off += READ) {
		if (signal.aborted) throw new Failure("cancelled", "Cancelled");
		hasher.update(new Uint8Array(await file.slice(off, Math.min(file.size, off + READ)).arrayBuffer()));
		tick(Math.min(file.size, off + READ));
	}
	tick(file.size, true);
	post({ type: "done", sha256: hasher.digest("hex") });
}

async function crcEntries(req: Extract<WorkerRequest, { type: "crc" }>) {
	const signal = abort.signal;
	const total = req.entries.reduce((n, e) => n + e.size, 0);
	const tick = progressPoster("hashing", total);
	const bad: string[] = [];
	let done = 0;
	for (const e of req.entries) {
		const crc = await createCRC32();
		for (let off = 0; off < e.size; off += READ) {
			if (signal.aborted) throw new Failure("cancelled", "Cancelled");
			const end = Math.min(e.size, off + READ);
			crc.update(new Uint8Array(await req.file.slice(e.offset + off, e.offset + end).arrayBuffer()));
			done += end - off;
			tick(done);
		}
		if (parseInt(crc.digest("hex"), 16) !== e.crc32 >>> 0) bad.push(e.name);
	}
	tick(total, true);
	post({ type: "done", bad });
}

self.onmessage = async (ev: MessageEvent<WorkerRequest>) => {
	const req = ev.data;
	if (req.type === "cancel") {
		abort.abort();
		return;
	}
	abort = new AbortController();
	try {
		if (req.type === "download") await download(req);
		else if (req.type === "hash") await hashFile(req.file);
		else if (req.type === "crc") await crcEntries(req);
	} catch (e) {
		if (e instanceof Failure) post({ type: "error", code: e.code, message: e.message });
		else if (e instanceof DOMException && e.name === "QuotaExceededError")
			post({ type: "error", code: "quota", message: "There isn't enough space for this build in the browser's storage" });
		else post({ type: "error", code: "other", message: e instanceof Error ? e.message : String(e) });
	}
};
