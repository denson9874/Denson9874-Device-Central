// The Bloom stage's full bloom gives way to the next mode (another phone's install after Done).

import { describe, expect, it } from "vitest";
import { BloomStage } from "../src/ui/bloom.ts";

function stage() {
	// The stage's state without its canvas and SVG: setMode only touches the root and the frame loop
	const classes = new Set<string>();
	const s = Object.create(BloomStage.prototype) as BloomStage;
	Object.assign(s, {
		mode: "complete",
		rate: 0,
		root: {
			dataset: {} as Record<string, string>,
			classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c), contains: (c: string) => classes.has(c) },
		},
		kick: () => {},
		setProgress: () => {},
	});
	classes.add("is-blooming");
	return { s, classes };
}

describe("the Bloom stage", () => {
	it("drops the full bloom when it moves on to another mode", () => {
		const { s, classes } = stage();
		s.setMode("verify");
		expect(classes.has("is-blooming")).toBe(false);
	});

	it("keeps it while it stays in full bloom", () => {
		const { s, classes } = stage();
		s.setMode("complete");
		expect(classes.has("is-blooming")).toBe(true);
	});
});
