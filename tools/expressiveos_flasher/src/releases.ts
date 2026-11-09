// A phone's releases: the flasher.json manifest flasher_publish.py writes to R2, served by the
// Worker at /api/releases/<device>. Checked here the way the publish script checks it.

export interface ReleaseFile {
	file: string;
	size: number;
	sha256: string;
}

export interface Release {
	name: string;
	channel: "release" | "testers";
	android: string;
	version: string;
	type: string;
	/** Build date, YYYY-MM-DD. */
	date: string;
	published: string;
	zip: ReleaseFile;
	/** The stock init_boot of a KernelSU Next build, for installing it without root. */
	initBootStock: ReleaseFile | null;
	root: "kernelsu-next" | null;
	/** android-info.txt's lines. */
	requirements: string[];
	/**
	 * The stock firmware the build was made on. Optional, and flasher_publish.py doesn't write it
	 * yet; when present, the page warns if the phone's bootloader differs.
	 */
	firmware?: { bootloader?: string; baseband?: string };
}

export class ReleasesError extends Error {
	constructor(
		message: string,
		readonly kind: "none" | "network" | "invalid",
	) {
		super(message);
		this.name = "ReleasesError";
	}
}

const SHA256_RE = /^[0-9a-f]{64}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const nameRe = (device: string) => new RegExp(`^ExpressiveOS-\\d+\\.\\d+-\\d{8}-${device}-[0-9][0-9.]*-[A-Za-z]+(?:-r\\d+)?$`);

function fileOk(f: unknown, want: string): f is ReleaseFile {
	if (!f || typeof f !== "object") return false;
	const r = f as Record<string, unknown>;
	return r.file === want && Number.isSafeInteger(r.size) && (r.size as number) > 0 && typeof r.sha256 === "string" && SHA256_RE.test(r.sha256);
}

/** Why an entry isn't a usable release of the device, or null. */
export function releaseError(e: unknown, device: string): string | null {
	if (!e || typeof e !== "object") return "not an object";
	const r = e as Record<string, unknown>;
	if (typeof r.name !== "string" || !nameRe(device).test(r.name)) return `name ${String(r.name).slice(0, 80)}`;
	if (r.channel !== "release" && r.channel !== "testers") return `${r.name}: channel`;
	for (const k of ["android", "version", "type"]) if (typeof r[k] !== "string") return `${r.name}: ${k}`;
	if (typeof r.date !== "string" || !DATE_RE.test(r.date)) return `${r.name}: date`;
	if (typeof r.published !== "string" || !TIME_RE.test(r.published)) return `${r.name}: published`;
	if (!fileOk(r.zip, `${r.name}-fastboot.zip`)) return `${r.name}: zip`;
	if (r.initBootStock !== null && !fileOk(r.initBootStock, `${r.name}-init_boot-stock.img`)) return `${r.name}: initBootStock`;
	if (r.root !== (r.initBootStock === null ? null : "kernelsu-next")) return `${r.name}: root`;
	if (!Array.isArray(r.requirements) || !r.requirements.every((x) => typeof x === "string")) return `${r.name}: requirements`;
	if (r.firmware !== undefined) {
		const f = r.firmware as Record<string, unknown> | null;
		if (!f || typeof f !== "object") return `${r.name}: firmware`;
		for (const k of ["bootloader", "baseband"]) if (f[k] !== undefined && typeof f[k] !== "string") return `${r.name}: firmware.${k}`;
	}
	return null;
}

/** A release name's -rN (a second release of the day is -r2...), 1 without one. */
export function rnum(name: string): number {
	const m = /-r(\d+)$/.exec(name);
	return m ? Number(m[1]) : 1;
}

/**
 * The manifest's usable releases, newest first. Entries that don't check out are left out, but a
 * manifest listing one (name, channel) twice isn't valid: the page tells builds apart by the two.
 */
export function parseManifest(value: unknown, device: string): { releases: Release[]; skipped: string[] } {
	if (!value || typeof value !== "object") throw new ReleasesError("The build list isn't valid", "invalid");
	const m = value as Record<string, unknown>;
	if (m.schema !== 1) throw new ReleasesError("The build list is in a newer format than this page knows; reload the page", "invalid");
	if (m.device !== device) throw new ReleasesError(`The build list is for ${String(m.device)}, not ${device}`, "invalid");
	if (!Array.isArray(m.releases)) throw new ReleasesError("The build list isn't valid", "invalid");
	const releases: Release[] = [];
	const skipped: string[] = [];
	const seen = new Set<string>();
	for (const e of m.releases) {
		// Counted whether or not the entry checks out: the same name can be in both channels, once each
		if (e && typeof e === "object" && typeof e.name === "string" && typeof e.channel === "string") {
			const key = JSON.stringify([e.name, e.channel]);
			if (seen.has(key)) throw new ReleasesError("The build list isn't valid", "invalid");
			seen.add(key);
		}
		const why = releaseError(e, device);
		if (why) skipped.push(why);
		else releases.push(e as Release);
	}
	// Newest first, as flasher_publish.py orders them: date, then publish time, then -rN. A -rN counts
	// only the zips of one name on one day, so a same-day 1.1 after 1.0-r3 has none of its own.
	releases.sort((a, b) => b.date.localeCompare(a.date) || b.published.localeCompare(a.published) || rnum(b.name) - rnum(a.name));
	return { releases, skipped };
}

export async function fetchReleases(device: string, signal?: AbortSignal): Promise<Release[]> {
	let res: Response;
	try {
		res = await fetch(`/api/releases/${encodeURIComponent(device)}`, { signal, headers: { Accept: "application/json" } });
	} catch (e) {
		if (signal?.aborted) throw e;
		throw new ReleasesError("Couldn't reach the build list. Check your connection and try again.", "network");
	}
	if (res.status === 404) throw new ReleasesError("There are no ExpressiveOS builds for this phone yet.", "none");
	if (!res.ok) throw new ReleasesError(`The build list didn't load (HTTP ${res.status}). Try again in a minute.`, "network");
	let value: unknown;
	try {
		value = await res.json();
	} catch {
		throw new ReleasesError("The build list isn't valid", "invalid");
	}
	const { releases, skipped } = parseManifest(value, device);
	if (skipped.length) console.warn("Builds left out of the list:", skipped);
	return releases;
}

/** Where the Worker serves a release's file: the testers channel has its own folder. */
export const fileUrl = (device: string, release: Pick<Release, "channel">, file: string) =>
	`/dl/${encodeURIComponent(device)}/${release.channel === "testers" ? "testers/" : ""}${encodeURIComponent(file)}`;

export function formatBytes(n: number): string {
	if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(n >= 10 * 1024 ** 3 ? 0 : 1)} GB`;
	if (n >= 1024 ** 2) return `${Math.round(n / 1024 ** 2)} MB`;
	if (n >= 1024) return `${Math.round(n / 1024)} KB`;
	return `${n} bytes`;
}
