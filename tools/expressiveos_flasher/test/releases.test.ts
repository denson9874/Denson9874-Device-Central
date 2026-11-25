import { afterEach, describe, expect, it, vi } from "vitest";
import { ReleasesError, fetchReleases, fileUrl, parseManifest, rnum } from "../src/releases.ts";

const sha = (c: string) => c.repeat(64);
function release(name: string, over: Record<string, unknown> = {}) {
	return {
		name,
		channel: "release",
		android: "16.0",
		version: "1.0",
		type: "Unofficial",
		date: `${name.slice(18, 22)}-${name.slice(22, 24)}-${name.slice(24, 26)}`,
		published: "2026-10-30T12:00:00Z",
		zip: { file: `${name}-fastboot.zip`, size: 5_000_000_000, sha256: sha("a") },
		bootStock: { file: `${name}-boot-stock.img`, size: 8_388_608, sha256: sha("b") },
		root: "bakasu",
		requirements: ["require board=cheetah"],
		...over,
	};
}

describe("release manifest", () => {
	it("keeps good releases, newest first, and leaves out bad ones", () => {
		const m = {
			schema: 1,
			device: "cheetah",
			updated: "2026-10-30T12:00:00Z",
			releases: [
				release("ExpressiveOS-16.0-20261026-cheetah-1.0-Unofficial"),
				release("ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial", { bootStock: null, root: null }),
				release("ExpressiveOS-16.0-20261028-cheetah-1.0-Unofficial", { root: null }),
				release("ExpressiveOS-16.0-20261027-husky-1.0-Unofficial"),
				release("ExpressiveOS-16.0-20261025-cheetah-1.0-Unofficial", { zip: { file: "other.zip", size: 1, sha256: sha("a") } }),
			],
		};
		const { releases, skipped } = parseManifest(m, "cheetah");
		expect(releases.map((r) => r.date)).toEqual(["2026-10-29", "2026-10-26"]);
		expect(skipped.length).toBe(3);
	});

	it("reads an entry written before BakaSU, with no bootStock, as a build without root", () => {
		const old: Record<string, unknown> = release("ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial", { root: null });
		delete old.bootStock;
		old.initBootStock = null;
		const { releases, skipped } = parseManifest({ schema: 1, device: "cheetah", updated: "2026-10-30T12:00:00Z", releases: [old] }, "cheetah");
		expect(skipped).toEqual([]);
		expect(releases[0].bootStock).toBeNull();
	});

	it("refuses a manifest for another phone or format", () => {
		expect(() => parseManifest({ schema: 2, device: "cheetah", releases: [] }, "cheetah")).toThrow(ReleasesError);
		expect(() => parseManifest({ schema: 1, device: "husky", releases: [] }, "cheetah")).toThrow(/husky/);
		expect(() => parseManifest(null, "cheetah")).toThrow(ReleasesError);
	});

	it("orders by date, then publish time, then -rN", () => {
		const v10 = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial";
		const v11 = "ExpressiveOS-16.0-20261029-cheetah-1.1-Unofficial";
		const m = {
			schema: 1,
			device: "cheetah",
			releases: [
				release(`${v10}-r2`, { published: "2026-10-29T11:00:00Z" }),
				release("ExpressiveOS-16.0-20261028-cheetah-1.0-Unofficial-r3", { published: "2026-10-30T23:00:00Z" }),
				release(v10, { published: "2026-10-29T09:00:00Z" }),
				// A same-day version bump starts again without -rN, and still comes first
				release(v11, { published: "2026-10-29T16:00:00Z" }),
				release(`${v10}-r3`, { published: "2026-10-29T13:00:00Z" }),
				// Published in the same second: -rN decides
				release(`${v10}-r10`, { channel: "testers", published: "2026-10-29T13:00:00Z" }),
				release(`${v10}-r9`, { channel: "testers", published: "2026-10-29T13:00:00Z" }),
			],
		};
		const { releases, skipped } = parseManifest(m, "cheetah");
		expect(skipped).toEqual([]);
		expect(releases.map((r) => `${r.channel}/${r.name.slice(18)}`)).toEqual([
			"release/20261029-cheetah-1.1-Unofficial",
			"testers/20261029-cheetah-1.0-Unofficial-r10",
			"testers/20261029-cheetah-1.0-Unofficial-r9",
			"release/20261029-cheetah-1.0-Unofficial-r3",
			"release/20261029-cheetah-1.0-Unofficial-r2",
			"release/20261029-cheetah-1.0-Unofficial",
			"release/20261028-cheetah-1.0-Unofficial-r3",
		]);
		expect([rnum(v10), rnum(`${v10}-r2`), rnum(`${v10}-r10`)]).toEqual([1, 2, 10]);
	});

	it("refuses a manifest listing a release twice in one channel", () => {
		const name = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial";
		for (const channel of ["release", "testers"]) {
			const twice = { schema: 1, device: "cheetah", releases: [release(name, { channel }), release(name, { channel, published: "2026-10-31T08:00:00Z" })] };
			expect(() => parseManifest(twice, "cheetah")).toThrow(expect.objectContaining({ name: "ReleasesError", kind: "invalid" }));
		}
		// Even when one of the two wouldn't be listed
		const broken = { schema: 1, device: "cheetah", releases: [release(name), release(name, { zip: null })] };
		expect(() => parseManifest(broken, "cheetah")).toThrow(expect.objectContaining({ kind: "invalid" }));
	});

	it("takes the same release in both channels", () => {
		const name = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial";
		const m = { schema: 1, device: "cheetah", releases: [release(name, { channel: "testers" }), release(name)] };
		const { releases, skipped } = parseManifest(m, "cheetah");
		expect(skipped).toEqual([]);
		expect(releases.map((r) => [r.name, r.channel]).sort()).toEqual([
			[name, "release"],
			[name, "testers"],
		]);
	});
});

describe("release file URLs", () => {
	const zip = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-fastboot.zip";
	it("serves a release's files from the device's v2 folder, a testers build's from testers/", () => {
		expect(fileUrl("cheetah", { channel: "release" }, zip)).toBe(`/dl/v2/cheetah/${zip}`);
		expect(fileUrl("cheetah", { channel: "testers" }, zip)).toBe(`/dl/v2/cheetah/testers/${zip}`);
		const stock = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-boot-stock.img";
		expect(fileUrl("cheetah", { channel: "testers" }, stock)).toBe(`/dl/v2/cheetah/testers/${stock}`);
	});

	it("URL-encodes the device and the file name", () => {
		expect(fileUrl("cheetah", { channel: "release" }, "../a b/c#d?.zip")).toBe("/dl/v2/cheetah/..%2Fa%20b%2Fc%23d%3F.zip");
		expect(fileUrl("che/tah", { channel: "testers" }, "x/y")).toBe("/dl/v2/che%2Ftah/testers/x%2Fy");
	});

	it("serves 1.x fallback releases from /dl/<device>/ without the v2/ prefix", () => {
		expect(fileUrl("yogi", { channel: "release", legacyV1: true }, zip)).toBe(`/dl/yogi/${zip}`);
		expect(fileUrl("yogi", { channel: "testers", legacyV1: true }, zip)).toBe(`/dl/yogi/testers/${zip}`);
	});
});

describe("fetchReleases v2-first with 1.x fallback", () => {
	afterEach(() => vi.unstubAllGlobals());

	it("prefers /api/releases/v2/<device> when present without querying v1", async () => {
		const calls: string[] = [];
		const v2Name = "ExpressiveOS-17.0-20261201-kodiak-2.0-Official";
		vi.stubGlobal("fetch", async (url: string) => {
			calls.push(url);
			return Response.json({ schema: 1, device: "kodiak", releases: [release(v2Name, { android: "17.0", version: "2.0", type: "Official", requirements: ["require board=kodiak"] })] });
		});
		const got = await fetchReleases("kodiak");
		expect(calls).toEqual(["/api/releases/v2/kodiak"]);
		expect(got).toHaveLength(1);
		expect(got[0].legacyV1).toBeUndefined();
		expect(fileUrl("kodiak", got[0], got[0].zip.file)).toBe(`/dl/v2/kodiak/${v2Name}-fastboot.zip`);
	});

	it("falls back to /api/releases/<device> when v2 returns 404 so 1.3 stays live before v2 rollout", async () => {
		const calls: string[] = [];
		const v1Name = "ExpressiveOS-16.0-20261115-yogi-1.3-Official";
		vi.stubGlobal("fetch", async (url: string) => {
			calls.push(url);
			if (url === "/api/releases/v2/yogi") return new Response(null, { status: 404 });
			if (url === "/api/releases/yogi") {
				return Response.json({
					schema: 1,
					device: "yogi",
					releases: [release(v1Name, { version: "1.3", type: "Official", requirements: ["require board=yogi"] })],
				});
			}
			return new Response(null, { status: 404 });
		});
		const got = await fetchReleases("yogi");
		expect(calls).toEqual(["/api/releases/v2/yogi", "/api/releases/yogi"]);
		expect(got).toHaveLength(1);
		expect(got[0].legacyV1).toBe(true);
		expect(fileUrl("yogi", got[0], got[0].zip.file)).toBe(`/dl/yogi/${v1Name}-fastboot.zip`);
	});

	it("throws kind=none when both v2 and v1 return 404, and does not mask v2 5xx errors", async () => {
		vi.stubGlobal("fetch", async () => new Response(null, { status: 404 }));
		await expect(fetchReleases("cubs")).rejects.toMatchObject({ name: "ReleasesError", kind: "none" });

		const calls500: string[] = [];
		vi.stubGlobal("fetch", async (url: string) => {
			calls500.push(url);
			return new Response("boom", { status: 503 });
		});
		await expect(fetchReleases("cubs")).rejects.toMatchObject({ name: "ReleasesError", kind: "network" });
		expect(calls500).toEqual(["/api/releases/v2/cubs"]);
	});
});
