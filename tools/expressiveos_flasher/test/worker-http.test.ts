import { describe, expect, it } from "vitest";
import { parseRange, releaseFileRe } from "../worker/http.ts";

describe("Worker range requests", () => {
	it("reads single byte ranges", () => {
		expect(parseRange(null, 100)).toBeNull();
		expect(parseRange("bytes=0-", 100)).toEqual({ start: 0, end: 99 });
		expect(parseRange("bytes=10-19", 100)).toEqual({ start: 10, end: 19 });
		expect(parseRange("bytes=90-200", 100)).toEqual({ start: 90, end: 99 });
		expect(parseRange("bytes=-10", 100)).toEqual({ start: 90, end: 99 });
		expect(parseRange("bytes=-500", 100)).toEqual({ start: 0, end: 99 });
	});

	it("ignores what it can't serve as one range", () => {
		expect(parseRange("bytes=0-1,5-6", 100)).toBeNull();
		expect(parseRange("items=0-1", 100)).toBeNull();
		expect(parseRange("bytes=-", 100)).toBeNull();
		expect(parseRange("bytes=20-10", 100)).toBeNull();
	});

	it("says when a range is past the end", () => {
		expect(parseRange("bytes=100-", 100)).toBe("unsatisfiable");
		expect(parseRange("bytes=-0", 100)).toBe("unsatisfiable");
	});
});

describe("Worker file names", () => {
	const re = releaseFileRe("cheetah");
	it("serves a release's zip, stock init_boot and their checksums", () => {
		for (const n of [
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-fastboot.zip",
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-r2-fastboot.zip",
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-init_boot-stock.img",
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-fastboot.zip.sha256",
		])
			expect(re.test(n)).toBe(true);
	});

	it("never serves anything else", () => {
		for (const n of [
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-target_files.zip",
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial.zip",
			"ExpressiveOS-16.0-20261029-husky-1.0-Unofficial-fastboot.zip",
			"../flasher.json",
			"flasher.json",
			"ExpressiveOS-16.0-20261029-cheetah-1.0-Unofficial-fastboot.zip/../x",
		])
			expect(re.test(n)).toBe(false);
	});
});
