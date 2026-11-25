// The flasher's Worker. The page itself is static (the Vite build, served as assets); this answers
// the paths the page reads from the R2 bucket (both 1.x expressiveos/<device>/ and 2.0
// expressiveos/v2/<device>/ so 1.3 fastboot zips stay live), and nothing else of the bucket is reachable:
//   GET /api/releases/[v2/]<device>          expressiveos/[v2/]<device>/flasher.json, the device's manifest
//   GET /dl/[v2/]<device>/<file>             expressiveos/[v2/]<device>/flasher/<file>: a release's fastboot zip
//                                            or stock boot (or its .sha256), with single byte ranges
//   GET /dl/[v2/]<device>/testers/<file>     the same from expressiveos/[v2/]<device>/flasher/testers/, the
//                                            testers channel's own folder (its names can repeat a release's)
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

async function manifest(device: string, v2: boolean): Promise<Response> {
	const obj = await env.RELEASES.get(`expressiveos/${v2 ? "v2/" : ""}${device}/flasher.json`);
	if (!obj) return json(404, { error: "no-releases", device });
	return reply(200, await obj.text(), {
		"Content-Type": "application/json; charset=utf-8",
		// A new build shows up within a minute
		"Cache-Control": "public, max-age=60",
		ETag: obj.httpEtag,
	});
}

async function file(request: Request, device: string, v2: boolean, testers: boolean, name: string): Promise<Response> {
	const key = `expressiveos/${v2 ? "v2/" : ""}${device}/flasher/${testers ? "testers/" : ""}${name}`;
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
		const api = /^\/api\/releases\/(v2\/)?([a-z]+)$/.exec(url.pathname);
		if (api) {
			const [, v2, device] = api;
			if (!(DEVICES as readonly string[]).includes(device)) return json(404, { error: "unknown-device" });
			return manifest(device, !!v2);
		}
		const dl = /^\/dl\/(v2\/)?([a-z]+)\/(testers\/)?([^/]+)$/.exec(url.pathname);
		if (dl) {
			const [, v2, device, testers, name] = dl;
			if (!(DEVICES as readonly string[]).includes(device) || !releaseFileRe(device).test(name)) {
				return reply(404, "Not Found", { "Content-Type": "text/plain; charset=utf-8" });
			}
			return file(request, device, !!v2, !!testers, name);
		}
		return json(404, { error: "not-found" });
	},
} satisfies ExportedHandler;
