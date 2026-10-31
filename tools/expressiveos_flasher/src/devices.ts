// The phones ExpressiveOS is built for. The codename is the bootloader's "product" and the
// android-info.txt board; the releases of each come from /api/releases/<codename>.

export interface DeviceInfo {
	codename: string;
	model: string;
	/** Launch year, for sorting the list. */
	year: number;
}

export const DEVICES: DeviceInfo[] = [
	{ codename: "cheetah", model: "Pixel 7 Pro", year: 2022 },
	{ codename: "husky", model: "Pixel 8 Pro", year: 2023 },
	{ codename: "cubs", model: "Pixel 11", year: 2026 },
	{ codename: "grizzly", model: "Pixel 11 Pro", year: 2026 },
	{ codename: "kodiak", model: "Pixel 11 Pro XL", year: 2026 },
	{ codename: "yogi", model: "Pixel 11 Pro Fold", year: 2026 },
];

export function deviceByCodename(codename: string | null | undefined): DeviceInfo | undefined {
	return DEVICES.find((d) => d.codename === codename);
}
