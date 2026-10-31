import { describe, expect, it } from "vitest";
import { ReleasesError, fileUrl, parseManifest, rnum } from "../src/releases.ts";

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
		initBootStock: { file: `${name}-init_boot-stock.img`, size: 8_388_608, sha256: sha("b") },
		root: "kernelsu-next",
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
				release("ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial", { initBootStock: null, root: null }),
				release("ExpressiveOS-16.0-20261028-cheetah-1.0-Unofficial", { root: null }),
				release("ExpressiveOS-16.0-20261027-husky-1.0-Unofficial"),
				release("ExpressiveOS-16.0-20261025-cheetah-1.0-Unofficial", { zip: { file: "other.zip", size: 1, sha256: sha("a") } }),
			],
		};
		const { releases, skipped } = parseManifest(m, "cheetah");
		expect(releases.map((r) => r.date)).toEqual(["2026-10-29", "2026-10-26"]);
		expect(skipped.length).toBe(3);
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
	it("serves a release's files from the device's folder, a testers build's from testers/", () => {
		expect(fileUrl("cheetah", { channel: "release" }, zip)).toBe(`/dl/cheetah/${zip}`);
		expect(fileUrl("cheetah", { channel: "testers" }, zip)).toBe(`/dl/cheetah/testers/${zip}`);
		const stock = "ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-init_boot-stock.img";
		expect(fileUrl("cheetah", { channel: "testers" }, stock)).toBe(`/dl/cheetah/testers/${stock}`);
	});

	it("URL-encodes the device and the file name", () => {
		expect(fileUrl("cheetah", { channel: "release" }, "../a b/c#d?.zip")).toBe("/dl/cheetah/..%2Fa%20b%2Fc%23d%3F.zip");
		expect(fileUrl("che/tah", { channel: "testers" }, "x/y")).toBe("/dl/che%2Ftah/testers/x%2Fy");
	});
});
