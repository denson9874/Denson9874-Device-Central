// The download worker with a part of the build already in the browser: a Pause while that part
// is checked again gets through, and an answer that isn't the build never costs that part.

import { createHash } from "node:crypto";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { WorkerReply, WorkerRequest } from "../src/store/protocol.ts";
import { type FakeDirectory, fakeNavigator } from "./fake-storage.ts";
import { bytes } from "./helpers.ts";

const NAME = `${"c".repeat(64)}.zip`;
const MiB = 1024 * 1024;

const replies: WorkerReply[] = [];
const self = {
	postMessage: (m: WorkerReply) => replies.push(m),
	onmessage: null as null | ((ev: { data: WorkerRequest }) => Promise<void>),
};
const send = (req: WorkerRequest) => self.onmessage!({ data: req });
const last = () => replies[replies.length - 1];

let env: ReturnType<typeof fakeNavigator>;
let dir: FakeDirectory;

beforeAll(async () => {
	vi.stubGlobal("self", self);
	await import("../src/store/download.worker.ts");
});

afterAll(() => {
	vi.unstubAllGlobals();
});

beforeEach(async () => {
	replies.length = 0;
	env = fakeNavigator();
	dir = await env.releases();
	vi.stubGlobal("navigator", env.navigator);
});

describe("an answer that isn't the build", () => {
	const full = bytes(2 * MiB, 3);
	const sha256 = createHash("sha256").update(full).digest("hex");
	const partial = full.slice(0, MiB);
	const req = { type: "download", url: "https://example.test/b.zip", name: NAME, size: full.byteLength, sha256 } as const;

	it("leaves the part already downloaded alone when a page comes back instead", async () => {
		const file = dir.put(NAME, partial.slice(), false);
		// A proxy's block page, answered to the range request with a 200
		vi.stubGlobal("fetch", async () => new Response("<html>Blocked</html>", { status: 200, headers: { "Content-Type": "text/html", "Content-Length": "20" } }));
		await send(req);
		expect(last()).toMatchObject({ type: "error", code: "http" });
		expect(file.truncations).toEqual([]);
		expect(Buffer.compare(Buffer.from(file.data), Buffer.from(partial))).toBe(0);
	});

	it("leaves it alone when a 200 doesn't say how long it is", async () => {
		const file = dir.put(NAME, partial.slice(), false);
		let calls = 0;
		vi.stubGlobal("fetch", async () =>
			++calls === 1
				? new Response(new Blob([bytes(1000, 9)]).stream(), { status: 200, headers: { "Content-Type": "application/octet-stream" } })
				: new Response(null, { status: 404 }),
		);
		await send(req);
		expect(last()).toMatchObject({ type: "error" });
		expect(file.truncations).toEqual([]);
		expect(Buffer.compare(Buffer.from(file.data), Buffer.from(partial))).toBe(0);
	});

	it("still starts again from the top when the server sends the whole build", async () => {
		const file = dir.put(NAME, partial.slice(), false);
		vi.stubGlobal("fetch", async () => new Response(full.slice(), { status: 200, headers: { "Content-Type": "application/zip", "Content-Length": String(full.byteLength) } }));
		await send(req);
		expect(last()).toEqual({ type: "done", sha256 });
		expect(file.truncations).toEqual([0]);
		expect(Buffer.compare(Buffer.from(file.data), Buffer.from(full))).toBe(0);
	});
});

describe("pausing while the earlier part is checked again", () => {
	it("stops the check part way through", async () => {
		const chunks = 10; // the worker reads 8 MiB at a time
		const file = dir.put(NAME, new Uint8Array(chunks * 8 * MiB), false);
		let reads = 0;
		file.onRead = () => {
			reads++;
			// A disk read takes a while, and the worker reads synchronously
			const until = performance.now() + 25;
			while (performance.now() < until);
			// Pause is pressed once the check is under way: the message waits for the worker's turn
			if (reads === 1) setTimeout(() => void send({ type: "cancel" }), 0);
		};
		const fetches: string[] = [];
		vi.stubGlobal("fetch", (url: string, init: RequestInit) => {
			fetches.push(url);
			return new Promise((_, reject) => init.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError"))));
		});
		await send({ type: "download", url: "https://example.test/c.zip", name: NAME, size: chunks * 8 * MiB + 1, sha256: "0".repeat(64) });
		expect(last()).toMatchObject({ type: "error", code: "cancelled" });
		expect(reads).toBeLessThan(chunks);
		expect(fetches).toEqual([]);
	});
});
