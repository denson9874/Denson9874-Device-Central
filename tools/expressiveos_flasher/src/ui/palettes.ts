// Each phone grows its own flower: four petal colours (light to deep, in the brand mark's
// violet, blue, green, coral positions) that the 3D flower and the aura take on once the phone
// is chosen. Before that, and for a phone without one, it's ExpressiveOS's own four colours.

import { PETALS } from "./petals.ts";

export interface PetalTone {
	light: string;
	mid: string;
	deep: string;
}

export interface Palette {
	/** Shown nowhere yet: the palette's name, for the code and the tests. */
	name: string;
	petals: [PetalTone, PetalTone, PetalTone, PetalTone];
}

const tone = (light: string, mid: string, deep: string): PetalTone => ({ light, mid, deep });

export const BRAND_PALETTE: Palette = {
	name: "ExpressiveOS",
	petals: PETALS.map((p) => tone(p.light, p.mid, p.deep)) as Palette["petals"],
};

export const DEVICE_PALETTES: Record<string, Palette> = {
	// Pixel 7 Pro: sage, honey, cream and moss
	cheetah: {
		name: "Hazel Meadow",
		petals: [tone("#EEF2D2", "#B9C77E", "#6E7F35"), tone("#F8E8BE", "#DDB45E", "#9A7426"), tone("#F7F3E6", "#D5CBA9", "#8E8566"), tone("#D2E3BF", "#86A86F", "#46663A")],
	},
	// Pixel 8 Pro: bay blue, mint, porcelain and sky
	husky: {
		name: "Bay Breeze",
		petals: [tone("#D3E6FF", "#82B2F5", "#3E6FC4"), tone("#DAF7EB", "#8FE0C2", "#3FA889"), tone("#FCF5EC", "#EBDCC6", "#B79F7E"), tone("#E0EDFF", "#A9C8F4", "#5E86C9")],
	},
	// Pixel 11: teal, aqua, seafoam and indigo
	cubs: {
		name: "Lagoon",
		petals: [tone("#CBF4F1", "#5ED3CB", "#16918C"), tone("#D6F2FF", "#6BC6F2", "#1F7EB8"), tone("#E3FBEC", "#93E7B7", "#3BAE79"), tone("#D9DBFF", "#8C92F0", "#4148B8")],
	},
	// Pixel 11 Pro: coral, amber, rose and gold
	grizzly: {
		name: "Ember",
		petals: [tone("#FFDCD2", "#FF8A6E", "#D2452D"), tone("#FFE9CB", "#FFB66B", "#D17A1E"), tone("#FFD9E6", "#F57FA7", "#C23A6B"), tone("#FFF2C4", "#F5CF5B", "#B98E14")],
	},
	// Pixel 11 Pro XL: magenta, violet, electric blue and mint
	kodiak: {
		name: "Aurora",
		petals: [tone("#FBD3F6", "#E86AD6", "#A51E92"), tone("#E5D6FF", "#A77BFA", "#6232C9"), tone("#D2E5FF", "#5E9BFF", "#1F55D6"), tone("#D6FBEC", "#5FE2B0", "#1E9E73")],
	},
	// Pixel 11 Pro Fold: lavender, dusk rose, indigo and silver
	yogi: {
		name: "Twilight",
		petals: [tone("#EEE6FF", "#BBA4F2", "#7558C2"), tone("#FFE3EC", "#E7A0B8", "#B0587A"), tone("#DCDFF8", "#7C83C9", "#3C428C"), tone("#F3F4F8", "#C7CAD8", "#858AA3")],
	},
};

export function paletteFor(codename: string | null | undefined): Palette {
	return (codename && DEVICE_PALETTES[codename]) || BRAND_PALETTE;
}
