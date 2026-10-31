// The Worker's request checks, apart from the Workers runtime so the tests can run them.

export const DEVICES = ["cheetah", "husky", "kodiak", "grizzly", "cubs", "yogi"] as const;

/** A file of one of the device's releases, as flasher_publish.py names them. */
export function releaseFileRe(device: string): RegExp {
	return new RegExp(`^ExpressiveOS-\\d+\\.\\d+-\\d{8}-${device}-[0-9][0-9.]*-[A-Za-z]+(?:-r\\d+)?(?:-fastboot\\.zip|-init_boot-stock\\.img)(?:\\.sha256)?$`);
}

/** A single byte range ("bytes=a-b", "bytes=a-" or "bytes=-n"), or null for the whole file. */
export function parseRange(header: string | null, size: number): { start: number; end: number } | "unsatisfiable" | null {
	const m = /^bytes=(\d*)-(\d*)$/.exec(header?.trim() ?? "");
	if (!m || (!m[1] && !m[2])) return null; // none, several ranges or not bytes: the whole file
	let start: number;
	let end = size - 1;
	if (m[1]) {
		start = Number(m[1]);
		if (m[2]) end = Math.min(Number(m[2]), end);
		if (m[2] && Number(m[2]) < start) return null; // invalid, so ignored (RFC 9110 14.1.1)
	} else {
		start = Math.max(size - Number(m[2]), 0);
	}
	if (!Number.isSafeInteger(start) || start > end) return "unsatisfiable";
	return { start, end };
}
