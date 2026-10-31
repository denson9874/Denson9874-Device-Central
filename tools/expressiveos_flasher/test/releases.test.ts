import { describe, expect, it } from "vitest";
import { ReleasesError, parseManifest } from "../src/releases.ts";

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
});
