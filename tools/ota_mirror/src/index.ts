import { env } from "cloudflare:workers";

// Serves the OTA packages in the denson9874-ota R2 bucket to the Updaters: GET and HEAD of an exact key, with
// single byte ranges so interrupted downloads resume. Nothing else, so the bucket can't be listed.
export default {
	async fetch(request) {
		if (request.method !== "GET" && request.method !== "HEAD") {
			return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
		}
		const key = new URL(request.url).pathname.slice(1);
		const head = key ? await env.OTA.head(key) : null;
		if (!head) return new Response("Not Found", { status: 404 });

		const headers = new Headers();
		head.writeHttpMetadata(headers);
		headers.set("ETag", head.httpEtag);
		headers.set("Accept-Ranges", "bytes");
		let start = 0;
		let end = head.size - 1;
		let status = 200;
		const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("Range") ?? "");
		if (range && (range[1] || range[2])) {
			if (range[1]) {
				start = Number(range[1]);
				if (range[2]) end = Math.min(Number(range[2]), end);
			} else {
				start = Math.max(head.size - Number(range[2]), 0);
			}
			if (start > end) {
				return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${head.size}` } });
			}
			status = 206;
			headers.set("Content-Range", `bytes ${start}-${end}/${head.size}`);
		}
		headers.set("Content-Length", String(end - start + 1));
		if (request.method === "HEAD") return new Response(null, { status, headers });

		const object = await env.OTA.get(key, { range: { offset: start, length: end - start + 1 } });
		if (!object) return new Response("Not Found", { status: 404 });
		return new Response(object.body, { status, headers });
	},
} satisfies ExportedHandler;
