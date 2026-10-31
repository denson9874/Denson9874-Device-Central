// The flasher's Worker. The page itself is static (the Vite build, served as assets); this answers
// the two paths the page reads from the R2 bucket, and nothing else of the bucket is reachable:
//   GET /api/releases/<device>    expressiveos/<device>/flasher.json, the device's manifest
//   GET /dl/<device>/<file>       expressiveos/<device>/flasher/<file>: a release's fastboot zip
//                                 or stock init_boot (or its .sha256), with single byte ranges
// Release files are named by flasher_publish.py and never rewritten, so they're cached for good.

import { env } from "cloudflare:workers";
import { DEVICES, parseRange, releaseFileRe } from "./http.ts";

const SECURITY_HEADERS: Record<string, string> = {
	"X-Content-Type-Options": "nosniff",
	"Referrer-Policy": "no-referrer",
	"Cross-Origin-Resource-Policy": "same-origin",
};

function reply(status: number, body: string | null, headers: Record<string, string> = {}): Response {
	return new Response(body, { status, headers: { ...SECURITY_HEADERS, "Cache-Control": "no-store", ...headers } });
}

const json = (status: number, value: unknown) => reply(status, JSON.stringify(value), { "Content-Type": "application/json; charset=utf-8" });

async function manifest(device: string): Promise<Response> {
	const obj = await env.RELEASES.get(`expressiveos/${device}/flasher.json`);
	if (!obj) return json(404, { error: "no-releases", device });
	return reply(200, await obj.text(), {
		"Content-Type": "application/json; charset=utf-8",
		// A new build shows up within a minute
		"Cache-Control": "public, max-age=60",
		ETag: obj.httpEtag,
	});
}

async function file(request: Request, device: string, name: string): Promise<Response> {
	const key = `expressiveos/${device}/flasher/${name}`;
	const head = await env.RELEASES.head(key);
	if (!head) return reply(404, "Not Found", { "Content-Type": "text/plain; charset=utf-8" });

	const headers: Record<string, string> = {
		"Content-Type": name.endsWith(".zip") ? "application/zip" : name.endsWith(".sha256") ? "text/plain; charset=utf-8" : "application/octet-stream",
		"Content-Disposition": `attachment; filename="${name}"`,
		"Accept-Ranges": "bytes",
		ETag: head.httpEtag,
		"Last-Modified": head.uploaded.toUTCString(),
		"Cache-Control": "public, max-age=31536000, immutable",
	};
	// If-Range: a range of the same file only (R2 keeps the name, so this is belt and braces)
	const ifRange = request.headers.get("If-Range");
	const rangeHeader = ifRange && ifRange !== head.httpEtag ? null : request.headers.get("Range");
	const range = parseRange(rangeHeader, head.size);
	if (range === "unsatisfiable") return reply(416, null, { "Content-Range": `bytes */${head.size}` });
	const start = range?.start ?? 0;
	const end = range?.end ?? head.size - 1;
	const status = range ? 206 : 200;
	if (range) headers["Content-Range"] = `bytes ${start}-${end}/${head.size}`;
	headers["Content-Length"] = String(Math.max(0, end - start + 1));
	if (request.method === "HEAD" || head.size === 0) return reply(status, null, headers);

	const obj = await env.RELEASES.get(key, { range: { offset: start, length: end - start + 1 } });
	if (!obj) return reply(404, "Not Found", { "Content-Type": "text/plain; charset=utf-8" });
	return new Response(obj.body, { status, headers: { ...SECURITY_HEADERS, ...headers } });
}

export default {
	async fetch(request) {
		const url = new URL(request.url);
		if (request.method !== "GET" && request.method !== "HEAD") {
			return reply(405, "Method Not Allowed", { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" });
		}
		const api = /^\/api\/releases\/([a-z]+)$/.exec(url.pathname);
		if (api) {
			if (!(DEVICES as readonly string[]).includes(api[1])) return json(404, { error: "unknown-device" });
			return manifest(api[1]);
		}
		const dl = /^\/dl\/([a-z]+)\/([^/]+)$/.exec(url.pathname);
		if (dl) {
			const [, device, name] = dl;
			if (!(DEVICES as readonly string[]).includes(device) || !releaseFileRe(device).test(name)) {
				return reply(404, "Not Found", { "Content-Type": "text/plain; charset=utf-8" });
			}
			return file(request, device, name);
		}
		return json(404, { error: "not-found" });
	},
} satisfies ExportedHandler;
