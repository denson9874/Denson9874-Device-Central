// The Worker for the browser tests: the built page as static files (with the _headers file's
// headers, so the Content-Security-Policy is the real one), and /api/* and /dl/* answered by the
// real Worker (worker/index.ts, run in Node) from a fixture folder standing in for R2, with an
// optional speed limit. Unknown paths get index.html, as the Worker's single-page-application
// assets do.

import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { register } from "node:module";
import { extname, join, normalize } from "node:path";
import { Readable } from "node:stream";

register("./worker-hooks.mjs", import.meta.url);
const { default: worker } = await import("../worker/index.ts");
const { env } = await import("../test/cloudflare-workers-stub.ts");

/**
 * R2 as the Worker uses it (head, get with an optional range) over a folder: the key
 * expressiveos/<device>/... is <dir>/<device>/..., as e2e/run.mjs lays its fixtures out.
 */
class FolderBucket {
	constructor(dir) {
		this.dir = dir;
	}

	path(key) {
		if (!key.startsWith("expressiveos/") || key.split("/").some((p) => p === ".." || p === "." || p === "")) throw new Error(`fixture R2: no key ${key}`);
		return join(this.dir, key.slice("expressiveos/".length));
	}

	async head(key) {
		const p = this.path(key);
		if (!existsSync(p) || !statSync(p).isFile()) return null;
		const st = statSync(p);
		const etag = createHash("md5").update(`${key} ${st.size} ${st.mtimeMs}`).digest("hex");
		return { key, size: st.size, etag, httpEtag: `"${etag}"`, uploaded: st.mtime, writeHttpMetadata() {} };
	}

	async get(key, options) {
		const meta = await this.head(key);
		if (!meta) return null;
		const p = this.path(key);
		const offset = options?.range?.offset ?? 0;
		const length = options?.range?.length ?? meta.size - offset;
		if (offset < 0 || length < 0 || offset + length > meta.size) throw new Error(`fixture R2: range ${offset}+${length} outside ${key} (${meta.size} bytes)`);
		let body = null;
		return {
			...meta,
			range: options?.range,
			get body() {
				body ??= length === 0 ? new ReadableStream({ start: (c) => c.close() }) : Readable.toWeb(createReadStream(p, { start: offset, end: offset + length - 1, highWaterMark: 64 * 1024 }));
				return body;
			},
			async text() {
				return readFileSync(p, "utf8");
			},
		};
	}
}

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".json": "application/json", ".wasm": "application/wasm", ".map": "application/json" };

function headersFile(dir) {
	const out = {};
	const p = join(dir, "_headers");
	if (!existsSync(p)) return out;
	let path = null;
	for (const line of readFileSync(p, "utf8").split("\n")) {
		if (!line.trim()) continue;
		if (!/^\s/.test(line)) {
			path = line.trim();
			out[path] = {};
		} else if (path) {
			const i = line.indexOf(":");
			out[path][line.slice(0, i).trim()] = line.slice(i + 1).trim();
		}
	}
	return out;
}

export function startServer({ assets, fixtures, bytesPerSecond = 0, port = 0 }) {
	const hdrs = headersFile(assets);
	const state = { bytesPerSecond, requests: [] };
	env.RELEASES = new FolderBucket(fixtures);
	const server = createServer(async (req, res) => {
		const url = new URL(req.url, "http://localhost");
		state.requests.push(`${req.method} ${url.pathname} ${req.headers.range ?? ""}`.trim());
		if (/^\/(api|dl)\//.test(url.pathname)) {
			try {
				await fromWorker(req, res, state);
			} catch (e) {
				console.error(`server: ${req.method} ${url.pathname}: ${e.stack ?? e}`);
				if (!res.headersSent) res.writeHead(500);
				res.end();
			}
			return;
		}
		let p = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, "");
		let file = join(assets, p);
		if (!file.startsWith(assets) || !existsSync(file) || statSync(file).isDirectory()) file = join(assets, "index.html");
		const headers = { "Content-Type": TYPES[extname(file)] ?? "application/octet-stream", ...hdrs["/*"] };
		res.writeHead(200, headers);
		createReadStream(file).pipe(res);
	});
	return new Promise((resolve) => {
		server.listen(port, "127.0.0.1", () => resolve({ server, state, url: `http://localhost:${server.address().port}` }));
	});
}

/** The Worker's answer to req, its body sent at state.bytesPerSecond (0: as fast as it goes). */
async function fromWorker(req, res, state) {
	const headers = new Headers();
	for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, Array.isArray(v) ? v.join(", ") : v);
	const response = await worker.fetch(new Request(new URL(req.url, `http://${req.headers.host ?? "localhost"}`), { method: req.method, headers }));
	res.writeHead(response.status, Object.fromEntries(response.headers));
	if (!response.body) {
		res.end();
		return;
	}
	const reader = response.body.getReader();
	res.on("close", () => void reader.cancel().catch(() => {}));
	for (;;) {
		const { done, value } = await reader.read().catch(() => ({ done: true }));
		if (done || res.destroyed) break;
		if (!res.write(value)) {
			await new Promise((r) => {
				const go = () => {
					res.off("drain", go).off("close", go);
					r();
				};
				res.on("drain", go).on("close", go);
			});
		}
		if (state.bytesPerSecond) await new Promise((r) => setTimeout(r, (value.byteLength / state.bytesPerSecond) * 1000));
	}
	res.end();
}
