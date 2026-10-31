// worker/index.ts's fetch handler on a fake R2 bucket: the keys each path reads, and the answers.

import { beforeEach, describe, expect, it } from "vitest";
import { type Release, fileUrl, parseManifest } from "../src/releases.ts";
import { DEVICES } from "../worker/http.ts";
import worker from "../worker/index.ts";
import { env } from "./cloudflare-workers-stub.ts";
import { bytes } from "./helpers.ts";

type Call = ["head", string] | ["get", string] | ["get", string, { offset: number; length: number }];

interface Stored {
	size: number;
	read(offset: number, length: number): Uint8Array<ArrayBuffer>;
	etag: string;
	uploaded: Date;
	contentType?: string;
}

const UPLOADED = new Date("2026-10-30T12:00:00Z");

/**
 * An R2 bucket with exactly what the Worker calls: head(key), get(key) and
 * get(key, { range: { offset, length } }). Anything else it's asked throws, and so does a range
 * that isn't inside the object: the Worker works its ranges out from head()'s size.
 */
class FakeBucket implements R2Bucket {
	readonly calls: Call[] = [];
	private readonly objects = new Map<string, Stored>();

	put(key: string, data: Uint8Array<ArrayBuffer> | string, contentType?: string): void {
		const b = typeof data === "string" ? new TextEncoder().encode(data) : data;
		this.add(key, { size: b.byteLength, read: (o, n) => b.slice(o, o + n), contentType });
	}

	/**
	 * A release-sized object whose bytes are made up as they're read: byte i is i % 251. Reading more
	 * than a MiB of it at once throws, so a Worker that reads the whole file fails instead of hanging.
	 */
	putLarge(key: string, size: number): void {
		this.add(key, {
			size,
			read: (o, n) => {
				if (n > 2 ** 20) throw new Error(`fake R2: ${n} bytes of ${key} at once`);
				return Uint8Array.from({ length: n }, (_, i) => (o + i) % 251);
			},
		});
	}

	private add(key: string, s: Omit<Stored, "etag" | "uploaded">): void {
		this.objects.set(key, { ...s, etag: (this.objects.size + 1).toString(16).padStart(32, "0"), uploaded: UPLOADED });
	}

	async head(key: string): Promise<R2Object | null> {
		this.calls.push(["head", key]);
		const s = this.objects.get(key);
		return s ? meta(key, s) : null;
	}

	async get(key: string, options?: R2GetOptions): Promise<R2ObjectBody | null> {
		const { range, ...rest }: R2GetOptions = options ?? {};
		if (Object.keys(rest).length) throw new Error(`fake R2: get ${key} with ${Object.keys(rest).join(", ")}`);
		let slice: { offset: number; length: number } | undefined;
		if (range !== undefined) {
			const r = range as Record<string, unknown>;
			if (range instanceof Headers || Object.keys(r).sort().join() !== "length,offset") throw new Error(`fake R2: get ${key} with range ${JSON.stringify(range)}`);
			slice = { offset: r.offset as number, length: r.length as number };
			this.calls.push(["get", key, slice]);
		} else {
			this.calls.push(["get", key]);
		}
		const s = this.objects.get(key);
		if (!s) return null;
		const { offset, length } = slice ?? { offset: 0, length: s.size };
		if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 1 || offset + length > s.size) {
			throw new Error(`fake R2: get ${key} past its ${s.size} bytes: ${offset}+${length}`);
		}
		const data = () => s.read(offset, length);
		return {
			...meta(key, s, slice),
			get body() {
				return new Blob([data()]).stream();
			},
			text: async () => new TextDecoder().decode(data()),
		};
	}
}

function meta(key: string, s: Stored, range?: R2Range): R2Object {
	return {
		key,
		size: s.size,
		etag: s.etag,
		httpEtag: `"${s.etag}"`,
		uploaded: s.uploaded,
		range,
		writeHttpMetadata: (h) => {
			if (s.contentType) h.set("Content-Type", s.contentType);
		},
	};
}

let bucket: FakeBucket;
beforeEach(() => {
	bucket = new FakeBucket();
	env.RELEASES = bucket;
});

const call = (path: string, init?: RequestInit) => worker.fetch(new Request(`https://expressiveos-flash.example.workers.dev${path}`, init));
const body = async (res: Response) => new Uint8Array(await res.arrayBuffer());

const BASE = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial";
const ZIP = `${BASE}-fastboot.zip`;
const STOCK = `${BASE}-init_boot-stock.img`;
const DIR = "expressiveos/cheetah/flasher";

describe("Worker: /api/releases/<device>", () => {
	const KEY = "expressiveos/cheetah/flasher.json";
	const MANIFEST = JSON.stringify({ schema: 1, device: "cheetah", updated: "2026-10-30T12:00:00Z", releases: [] });

	it("serves the device's flasher.json", async () => {
		bucket.put(KEY, MANIFEST, "application/json");
		const res = await call("/api/releases/cheetah");
		expect(res.status).toBe(200);
		expect(await res.text()).toBe(MANIFEST);
		expect(res.headers.get("Content-Type")).toBe("application/json; charset=utf-8");
		expect(res.headers.get("Cache-Control")).toBe("public, max-age=60");
		expect(res.headers.get("ETag")).toBe(`"${"1".padStart(32, "0")}"`);
		expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
		expect(bucket.calls).toEqual([["get", KEY]]);
	});

	it("answers HEAD with the same headers", async () => {
		bucket.put(KEY, MANIFEST);
		// The body it hands back is dropped by the runtime, as for any HEAD
		const res = await call("/api/releases/cheetah", { method: "HEAD" });
		expect(res.status).toBe(200);
		expect(res.headers.get("Content-Type")).toBe("application/json; charset=utf-8");
		expect(res.headers.get("ETag")).toMatch(/^"[0-9a-f]{32}"$/);
		expect(bucket.calls).toEqual([["get", KEY]]);
	});

	it("reads each device's own manifest", async () => {
		for (const dev of DEVICES) bucket.put(`expressiveos/${dev}/flasher.json`, JSON.stringify({ device: dev }));
		for (const dev of DEVICES) expect(await (await call(`/api/releases/${dev}`)).json()).toEqual({ device: dev });
		expect(bucket.calls).toEqual(DEVICES.map((dev) => ["get", `expressiveos/${dev}/flasher.json`]));
	});

	it("says when a device has no releases", async () => {
		for (const method of ["GET", "HEAD"]) {
			bucket.calls.length = 0;
			const res = await call("/api/releases/cheetah", { method });
			expect(res.status).toBe(404);
			expect(res.headers.get("Cache-Control")).toBe("no-store");
			if (method === "GET") expect(await res.json()).toEqual({ error: "no-releases", device: "cheetah" });
			expect(bucket.calls).toEqual([["get", KEY]]);
		}
	});

	it("knows only the six phones", async () => {
		bucket.put("expressiveos/pixel/flasher.json", "{}");
		for (const method of ["GET", "HEAD"]) {
			const res = await call("/api/releases/pixel", { method });
			expect(res.status).toBe(404);
			if (method === "GET") expect(await res.json()).toEqual({ error: "unknown-device" });
		}
		for (const path of ["/api/releases/Cheetah", "/api/releases/cheetah/", "/api/releases/cheetah/testers", "/api/releases/", "/api/releases/..%2Fcheetah"]) {
			expect((await call(path)).status, path).toBe(404);
		}
		expect(bucket.calls).toEqual([]);
	});
});

describe("Worker: /dl/<device>/<file>", () => {
	const data = bytes(1000, 7);

	it("serves a release's file from the device's flasher folder", async () => {
		bucket.put(`${DIR}/${ZIP}`, data);
		const res = await call(`/dl/cheetah/${ZIP}`);
		expect(res.status).toBe(200);
		expect(await body(res)).toEqual(data);
		expect(Object.fromEntries(res.headers)).toMatchObject({
			"content-type": "application/zip",
			"content-length": "1000",
			"content-disposition": `attachment; filename="${ZIP}"`,
			"accept-ranges": "bytes",
			etag: `"${"1".padStart(32, "0")}"`,
			"last-modified": "Fri, 30 Oct 2026 12:00:00 GMT",
			"cache-control": "public, max-age=31536000, immutable",
			"x-content-type-options": "nosniff",
			"cross-origin-resource-policy": "same-origin",
		});
		expect(res.headers.has("Content-Range")).toBe(false);
		expect(bucket.calls).toEqual([
			["head", `${DIR}/${ZIP}`],
			["get", `${DIR}/${ZIP}`, { offset: 0, length: 1000 }],
		]);
	});

	it("serves a testers build's file from the testers folder", async () => {
		const testers = bytes(1000, 8);
		// The same name in both channels: each its own file
		bucket.put(`${DIR}/${ZIP}`, data);
		bucket.put(`${DIR}/testers/${ZIP}`, testers);
		expect(await body(await call(`/dl/cheetah/testers/${ZIP}`))).toEqual(testers);
		expect(await body(await call(`/dl/cheetah/${ZIP}`))).toEqual(data);
		expect(bucket.calls).toEqual([
			["head", `${DIR}/testers/${ZIP}`],
			["get", `${DIR}/testers/${ZIP}`, { offset: 0, length: 1000 }],
			["head", `${DIR}/${ZIP}`],
			["get", `${DIR}/${ZIP}`, { offset: 0, length: 1000 }],
		]);
	});

	it("serves the stock init_boot and checksums with their own types", async () => {
		const files: Array<[string, string]> = [
			[STOCK, "application/octet-stream"],
			[`${STOCK}.sha256`, "text/plain; charset=utf-8"],
			[`${ZIP}.sha256`, "text/plain; charset=utf-8"],
		];
		for (const [name, type] of files) {
			bucket.put(`${DIR}/testers/${name}`, "x");
			const res = await call(`/dl/cheetah/testers/${name}`);
			expect([res.status, res.headers.get("Content-Type")], name).toEqual([200, type]);
		}
		expect(bucket.calls.filter((c) => c[0] === "head").map((c) => c[1])).toEqual(files.map(([n]) => `${DIR}/testers/${n}`));
	});

	it("reads each device's own folder", async () => {
		const name = "ExpressiveOS-17.0-20261101-yogi-2.0-OFFICIAL-r2-fastboot.zip";
		bucket.put(`expressiveos/yogi/flasher/${name}`, "release");
		bucket.put(`expressiveos/yogi/flasher/testers/${name}`, "testers");
		expect(await (await call(`/dl/yogi/${name}`)).text()).toBe("release");
		expect(await (await call(`/dl/yogi/testers/${name}`)).text()).toBe("testers");
		expect(bucket.calls.map((c) => c[1])).toEqual([
			`expressiveos/yogi/flasher/${name}`,
			`expressiveos/yogi/flasher/${name}`,
			`expressiveos/yogi/flasher/testers/${name}`,
			`expressiveos/yogi/flasher/testers/${name}`,
		]);
	});

	it("answers HEAD from R2's head alone", async () => {
		bucket.put(`${DIR}/testers/${ZIP}`, data);
		const res = await call(`/dl/cheetah/testers/${ZIP}`, { method: "HEAD" });
		expect(res.status).toBe(200);
		expect(res.headers.get("Content-Length")).toBe("1000");
		expect(res.headers.get("Accept-Ranges")).toBe("bytes");
		expect(res.body).toBeNull();
		expect(bucket.calls).toEqual([["head", `${DIR}/testers/${ZIP}`]]);
	});

	it("says when the file isn't there", async () => {
		bucket.put(`${DIR}/${ZIP}`, data);
		for (const method of ["GET", "HEAD"]) {
			bucket.calls.length = 0;
			const res = await call(`/dl/cheetah/testers/${ZIP}`, { method });
			expect(res.status).toBe(404);
			expect(res.headers.get("Cache-Control")).toBe("no-store");
			expect(bucket.calls).toEqual([["head", `${DIR}/testers/${ZIP}`]]);
		}
	});

	it("serves a byte range", async () => {
		bucket.put(`${DIR}/testers/${ZIP}`, data);
		const res = await call(`/dl/cheetah/testers/${ZIP}`, { headers: { Range: "bytes=100-199" } });
		expect(res.status).toBe(206);
		expect(res.headers.get("Content-Range")).toBe("bytes 100-199/1000");
		expect(res.headers.get("Content-Length")).toBe("100");
		expect(await body(res)).toEqual(data.slice(100, 200));
		expect(bucket.calls).toEqual([
			["head", `${DIR}/testers/${ZIP}`],
			["get", `${DIR}/testers/${ZIP}`, { offset: 100, length: 100 }],
		]);

		// HEAD with a range: the same headers, nothing read
		bucket.calls.length = 0;
		const head = await call(`/dl/cheetah/testers/${ZIP}`, { method: "HEAD", headers: { Range: "bytes=-10" } });
		expect([head.status, head.headers.get("Content-Range"), head.headers.get("Content-Length")]).toEqual([206, "bytes 990-999/1000", "10"]);
		expect(bucket.calls).toEqual([["head", `${DIR}/testers/${ZIP}`]]);
	});

	it("resumes a release-sized download and reads its end", async () => {
		const size = 5_368_709_120; // 5 GiB: past what 32 bits hold
		bucket.putLarge(`${DIR}/${ZIP}`, size);
		const head = await call(`/dl/cheetah/${ZIP}`, { method: "HEAD" });
		expect(head.headers.get("Content-Length")).toBe(String(size));

		// As the page asks for the rest of a download (download.worker.ts)
		const rest = await call(`/dl/cheetah/${ZIP}`, { headers: { Range: `bytes=${size - 120}-` } });
		expect(rest.status).toBe(206);
		expect(rest.headers.get("Content-Range")).toBe(`bytes ${size - 120}-${size - 1}/${size}`);
		expect(rest.headers.get("Content-Length")).toBe("120");
		expect(await body(rest)).toEqual(Uint8Array.from({ length: 120 }, (_, i) => (size - 120 + i) % 251));

		// A suffix (the zip's end of central directory)
		const end = await call(`/dl/cheetah/${ZIP}`, { headers: { Range: "bytes=-22" } });
		expect([end.status, end.headers.get("Content-Range")]).toEqual([206, `bytes ${size - 22}-${size - 1}/${size}`]);
		expect((await body(end)).byteLength).toBe(22);
		expect(bucket.calls.filter((c) => c[0] === "get")).toEqual([
			["get", `${DIR}/${ZIP}`, { offset: size - 120, length: 120 }],
			["get", `${DIR}/${ZIP}`, { offset: size - 22, length: 22 }],
		]);
	});

	it("refuses a range past the end", async () => {
		bucket.put(`${DIR}/testers/${ZIP}`, data);
		for (const range of ["bytes=1000-", "bytes=5000-6000", "bytes=-0"]) {
			bucket.calls.length = 0;
			const res = await call(`/dl/cheetah/testers/${ZIP}`, { headers: { Range: range } });
			expect(res.status, range).toBe(416);
			expect(res.headers.get("Content-Range")).toBe("bytes */1000");
			expect(bucket.calls).toEqual([["head", `${DIR}/testers/${ZIP}`]]);
		}
	});

	it("sends the whole file for a range it doesn't serve, or one of another copy", async () => {
		bucket.put(`${DIR}/${ZIP}`, data);
		const cases: Array<Record<string, string>> = [
			{ Range: "bytes=0-1,5-6" },
			{ Range: "items=0-9" },
			{ Range: "bytes=20-10" },
			{ Range: "bytes=10-19", "If-Range": '"another"' },
			{ Range: "bytes=10-19", "If-Range": "Fri, 30 Oct 2026 12:00:00 GMT" },
		];
		for (const headers of cases) {
			const res = await call(`/dl/cheetah/${ZIP}`, { headers });
			expect(res.status, JSON.stringify(headers)).toBe(200);
			expect(res.headers.has("Content-Range")).toBe(false);
			expect((await body(res)).byteLength).toBe(1000);
		}
		const same = await call(`/dl/cheetah/${ZIP}`, { headers: { Range: "bytes=10-19", "If-Range": `"${"1".padStart(32, "0")}"` } });
		expect([same.status, same.headers.get("Content-Range")]).toEqual([206, "bytes 10-19/1000"]);
	});

	it("serves nothing but release files, without asking R2", async () => {
		// What a looser check would reach
		bucket.put("expressiveos/cheetah/flasher.json", "{}");
		bucket.put("expressiveos/husky/flasher.json", "{}");
		const husky = "ExpressiveOS-16.0-20261029-husky-1.0-Unofficial-fastboot.zip";
		const paths = [
			// Traversal and its encodings: the URL parser resolves dot segments ("..", "%2e%2e") before
			// the Worker sees the path, and %2F isn't a separator, so these are names or other paths
			"/dl/cheetah/../flasher.json",
			"/dl/cheetah/testers/../../flasher.json",
			"/dl/cheetah/..%2Fflasher.json",
			"/dl/cheetah/..%2F..%2Fhusky%2Fflasher.json",
			"/dl/cheetah/testers%2F..%2F..%2Fflasher.json",
			"/dl/cheetah/%2e%2e/flasher.json",
			"/dl/cheetah/%2E%2E%2Fflasher.json",
			"/dl/cheetah/testers/%2e%2e%2f%2e%2e%2fflasher.json",
			"/dl/cheetah/%252e%252e%252fflasher.json",
			`/dl/cheetah/..%5C${ZIP}`,
			`/dl/cheetah/${encodeURIComponent(`../${ZIP}`)}`,
			`/dl/cheetah/%45${ZIP.slice(1)}`, // an encoded name, even of a real file: names aren't decoded
			// Not a fastboot zip, stock init_boot or their checksums
			"/dl/cheetah/flasher.json",
			"/dl/cheetah/testers/flasher.json",
			`/dl/cheetah/${BASE}-target_files.zip`,
			`/dl/cheetah/testers/${BASE}-target_files.zip`,
			`/dl/cheetah/${BASE}-img.zip`,
			`/dl/cheetah/${BASE}.zip`,
			`/dl/cheetah/${BASE}-init_boot.img`,
			`/dl/cheetah/${ZIP}.sha256.sig`,
			// Another device's file under this one
			`/dl/cheetah/${husky}`,
			`/dl/cheetah/testers/${husky}`,
			// A phone that isn't one of the six
			"/dl/pixel/ExpressiveOS-16.0-20261029-pixel-1.0-Unofficial-fastboot.zip",
			`/dl/Cheetah/${ZIP}`,
			// Folders other than testers/
			`/dl/cheetah/testers/testers/${ZIP}`,
			`/dl/cheetah/other/${ZIP}`,
			`/dl/cheetah/flasher/${ZIP}`,
			`/dl/cheetah/Testers/${ZIP}`,
			`/dl/cheetah/testers/${ZIP}/`,
			`/dl/cheetah/${ZIP}/`,
			"/dl/cheetah/testers/",
			"/dl/cheetah/testers",
			"/dl/cheetah",
			`/dl//${ZIP}`,
			`/dl/${ZIP}`,
		];
		for (const path of paths) {
			for (const method of ["GET", "HEAD"]) {
				const res = await call(path, { method });
				expect(res.status, `${method} ${path}`).toBe(404);
			}
		}
		expect(bucket.calls).toEqual([]);
	});

	it("leaves dot segments to the URL parser: they only name another path it serves", async () => {
		bucket.put(`${DIR}/${ZIP}`, data);
		expect((await call(`/dl/cheetah/testers/%2e%2e/${ZIP}`)).status).toBe(200);
		expect(bucket.calls[0]).toEqual(["head", `${DIR}/${ZIP}`]);
	});
});

describe("Worker: other requests", () => {
	it("refuses methods other than GET and HEAD", async () => {
		bucket.put("expressiveos/cheetah/flasher.json", "{}");
		bucket.put(`${DIR}/${ZIP}`, "x");
		for (const method of ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"]) {
			for (const path of ["/api/releases/cheetah", `/dl/cheetah/${ZIP}`, `/dl/cheetah/testers/${ZIP}`, "/elsewhere"]) {
				const res = await call(path, { method, body: method === "POST" || method === "PUT" ? "x" : undefined });
				expect(res.status, `${method} ${path}`).toBe(405);
				expect(res.headers.get("Allow")).toBe("GET, HEAD");
			}
		}
		expect(bucket.calls).toEqual([]);
	});

	it("answers anything else with a 404", async () => {
		for (const path of ["/", "/api/releases", "/api/other/cheetah", "/dl", "/expressiveos/cheetah/flasher.json"]) {
			const res = await call(path);
			expect(res.status, path).toBe(404);
			expect(await res.json()).toEqual({ error: "not-found" });
		}
		expect(bucket.calls).toEqual([]);
	});
});

describe("Worker and page together", () => {
	it("downloads each listed build from where its channel keeps it", async () => {
		const sha = (c: string) => c.repeat(64);
		const entry = (channel: Release["channel"], published: string): Release => ({
			name: BASE,
			channel,
			android: "16.0",
			version: "1.0",
			type: "Unofficial",
			date: "2026-10-29",
			published,
			zip: { file: ZIP, size: 1000, sha256: sha("a") },
			initBootStock: { file: STOCK, size: 16, sha256: sha("b") },
			root: "kernelsu-next",
			requirements: ["require board=cheetah"],
		});
		const manifest = { schema: 1, device: "cheetah", releases: [entry("testers", "2026-10-29T09:00:00Z"), entry("release", "2026-10-30T09:00:00Z")] };
		bucket.put("expressiveos/cheetah/flasher.json", JSON.stringify(manifest));
		const content: Record<string, Uint8Array<ArrayBuffer>> = {
			[`${DIR}/${ZIP}`]: bytes(1000, 1),
			[`${DIR}/${STOCK}`]: bytes(16, 2),
			[`${DIR}/testers/${ZIP}`]: bytes(1000, 3),
			[`${DIR}/testers/${STOCK}`]: bytes(16, 4),
		};
		for (const [key, b] of Object.entries(content)) bucket.put(key, b);

		const { releases } = parseManifest(await (await call("/api/releases/cheetah")).json(), "cheetah");
		expect(releases.map((r) => r.channel)).toEqual(["release", "testers"]);
		for (const r of releases) {
			const folder = r.channel === "testers" ? `${DIR}/testers` : DIR;
			for (const f of [r.zip, r.initBootStock!]) {
				const res = await call(fileUrl("cheetah", r, f.file));
				expect(res.status).toBe(200);
				expect(await body(res)).toEqual(content[`${folder}/${f.file}`]);
			}
		}
		expect(bucket.calls.filter((c) => c[0] === "head").map((c) => c[1])).toEqual([
			`${DIR}/${ZIP}`,
			`${DIR}/${STOCK}`,
			`${DIR}/testers/${ZIP}`,
			`${DIR}/testers/${STOCK}`,
		]);
	});
});
