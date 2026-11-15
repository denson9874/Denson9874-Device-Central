// The welcome page: the first thing a visit shows, over the aura. Its centrepiece is the Bloom
// stage itself, lent by the steps' column (#stage) for as long as the welcome is up, so the
// page keeps one 3D scene. "Get started" hands it back: the flower glides from the welcome into
// its place beside the steps while the welcome fades and the steps come in.
//
// It's shown once per tab session (sessionStorage), so a reload in the middle of an install goes
// straight back to the steps. The steps (app.ts) don't know it exists.

import { h } from "./dom.ts";

const SEEN = "eos-flasher-welcomed";

function seen(): boolean {
	try {
		return sessionStorage.getItem(SEEN) === "1";
	} catch {
		return false;
	}
}

function markSeen() {
	try {
		sessionStorage.setItem(SEEN, "1");
	} catch {
		// Private mode or storage blocked: the welcome just shows again next time
	}
}

export function showWelcome(): void {
	const host = document.getElementById("stage");
	const stageCol = host?.parentElement;
	const layout = document.querySelector<HTMLElement>(".layout");
	if (!host || !stageCol || !layout || seen()) return;

	const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
	const heroSlot = h("div", { class: "welcome-hero" });
	const start = h("button", { class: "btn btn-primary btn-big welcome-start", type: "button" }, "Get started");
	const welcome = h(
		"section",
		{ class: "welcome", "aria-labelledby": "welcome-title" },
		heroSlot,
		h(
			"div",
			{ class: "welcome-copy" },
			h("p", { class: "welcome-eyebrow" }, "ExpressiveOS for Pixel"),
			h("h1", { class: "welcome-title", id: "welcome-title" }, "Make your Pixel ", h("span", { class: "welcome-accent" }, "yours"), "."),
			h(
				"p",
				{ class: "welcome-lede" },
				"ExpressiveOS keeps the Pixel experience and adds theming, the Studio app and Expressive Launcher. This page installs it from your browser.",
			),
			h(
				"ul",
				{ class: "welcome-phones", "aria-label": "Supported phones" },
				h("li", null, "Pixel 7 Pro"),
				h("li", null, "Pixel 8 Pro"),
				h("li", null, "Pixel 11 series"),
			),
			h("div", { class: "welcome-actions" }, start),
			h(
				"ul",
				{ class: "welcome-needs", "aria-label": "What you'll need" },
				h("li", null, "Chrome or Edge on a computer"),
				h("li", null, "A USB cable"),
				h("li", null, "About 30 minutes"),
				h("li", null, "A backup: a fresh install erases the phone"),
			),
		),
	);

	// Lend the stage to the welcome; the steps wait, out of reach, until it's dismissed
	heroSlot.append(host);
	layout.inert = true;
	document.documentElement.classList.add("welcome-open");
	document.querySelector(".top")?.after(welcome);
	requestAnimationFrame(() => welcome.classList.add("is-in"));
	start.focus({ preventScroll: true });

	start.addEventListener(
		"click",
		() => {
			markSeen();
			const from = host.getBoundingClientRect();
			window.scrollTo({ top: 0 });
			stageCol.prepend(host);
			layout.inert = false;
			document.documentElement.classList.remove("welcome-open");
			welcome.classList.remove("is-in");
			welcome.classList.add("is-out");
			layout.classList.add("is-entering");

			if (!reduced) {
				// FLIP: start the stage where it was on the welcome, then let it settle into place
				const to = host.getBoundingClientRect();
				const s = from.width / Math.max(1, to.width);
				host.style.transformOrigin = "0 0";
				host.style.transform = `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${s})`;
				host.getBoundingClientRect();
				host.style.transition = "transform 0.95s cubic-bezier(0.2, 0.9, 0.2, 1)";
				host.style.transform = "";
			}
			const done = () => {
				host.style.transition = "";
				host.style.transformOrigin = "";
				welcome.remove();
				layout.classList.remove("is-entering");
				document.getElementById("panel")?.focus({ preventScroll: true });
			};
			setTimeout(done, reduced ? 0 : 1000);
		},
		{ once: true },
	);
}
