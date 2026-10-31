// A stand-in for the Worker in the browser tests: the built page as static files (with the
// _headers file's headers, so the Content-Security-Policy is the real one), and /api/releases and
// /dl from a fixture folder, with single byte ranges and an optional speed limit.

import { createReadStream, existsSync, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";

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
	const server = createServer((req, res) => {
		const url = new URL(req.url, "http://x");
		state.requests.push(`${req.method} ${url.pathname} ${req.headers.range ?? ""}`.trim());
		const api = /^\/api\/releases\/([a-z]+)$/.exec(url.pathname);
		if (api) {
			const f = join(fixtures, api[1], "flasher.json");
			if (!existsSync(f)) {
				res.writeHead(404, { "Content-Type": "application/json" }).end('{"error":"no-releases"}');
				return;
			}
			res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" }).end(readFileSync(f));
			return;
		}
		const dl = /^\/dl\/([a-z]+)\/([^/]+)$/.exec(url.pathname);
		if (dl) {
			const f = join(fixtures, dl[1], "flasher", decodeURIComponent(dl[2]));
			if (!existsSync(f)) {
				res.writeHead(404).end("Not Found");
				return;
			}
			const size = statSync(f).size;
			let start = 0;
			let end = size - 1;
			let status = 200;
			const m = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range ?? "");
			const h = { "Accept-Ranges": "bytes", "Content-Type": "application/octet-stream" };
			if (m) {
				start = Number(m[1]);
				if (m[2]) end = Math.min(Number(m[2]), end);
				if (start > end) {
					res.writeHead(416, { "Content-Range": `bytes */${size}` }).end();
					return;
				}
				status = 206;
				h["Content-Range"] = `bytes ${start}-${end}/${size}`;
			}
			h["Content-Length"] = String(end - start + 1);
			res.writeHead(status, h);
			const stream = createReadStream(f, { start, end, highWaterMark: 64 * 1024 });
			if (!state.bytesPerSecond) {
				stream.pipe(res);
				return;
			}
			stream.on("data", (chunk) => {
				stream.pause();
				res.write(chunk);
				setTimeout(() => stream.resume(), (chunk.length / state.bytesPerSecond) * 1000);
			});
			stream.on("end", () => res.end());
			req.on("close", () => stream.destroy());
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
