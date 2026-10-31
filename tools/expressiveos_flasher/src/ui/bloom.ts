// The Bloom stage: ExpressiveOS's four-petal mark, alive. While a build downloads its petals fill
// one by one from the centre out as pollen drifts in; while it installs the flower turns slowly
// inside a ring of petal colours that fills, and each finished partition throws off petals; when
// the install is done it bursts into full bloom.

import { PETALS, type Petal } from "./petals.ts";

export type BloomMode = "idle" | "download" | "verify" | "install" | "waiting" | "complete" | "error";

const SVG = "http://www.w3.org/2000/svg";
const CENTER = 54;
const R_MIN = 6;
const R_MAX = 46;

/** Direction from the mark's centre to each petal's middle. */
const DIRECTION: Record<Petal["name"], [number, number]> = {
	violet: [-0.69, -0.72],
	blue: [0.76, -0.65],
	green: [0.7, 0.72],
	coral: [-0.74, 0.67],
};

interface Particle {
	x: number;
	y: number;
	vx: number;
	vy: number;
	life: number;
	max: number;
	size: number;
	color: string;
	rot: number;
	vr: number;
	kind: "pollen" | "petal" | "spark";
	petal?: Path2D;
	/** Pollen spirals in towards this point. */
	tx?: number;
	ty?: number;
}

function el<K extends keyof SVGElementTagNameMap>(name: K, attrs: Record<string, string | number> = {}): SVGElementTagNameMap[K] {
	const e = document.createElementNS(SVG, name);
	for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
	return e;
}

let uid = 0;

/** The mark alone as an SVG element (header logo, favicon-sized uses). */
export function bloomMark(size: number, label = "ExpressiveOS"): SVGSVGElement {
	const id = `bm${uid++}`;
	const svg = el("svg", { viewBox: "18 18 72 72", width: size, height: size, role: "img", "aria-label": label });
	const defs = el("defs");
	for (const p of PETALS) {
		const g = el("linearGradient", { id: `${id}-${p.name}`, gradientUnits: "userSpaceOnUse", x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2 });
		g.append(el("stop", { offset: 0, "stop-color": p.light }), el("stop", { offset: 1, "stop-color": p.deep }));
		defs.append(g);
	}
	svg.append(defs);
	for (const p of PETALS) svg.append(el("path", { d: p.d, fill: `url(#${id}-${p.name})` }));
	return svg;
}

export class BloomStage {
	readonly root: HTMLDivElement;
	private canvas: HTMLCanvasElement;
	private ctx: CanvasRenderingContext2D;
	private mark: SVGSVGElement;
	private petalGroups: SVGGElement[] = [];
	private clips: SVGCircleElement[] = [];
	private ringArcs: SVGCircleElement[] = [];
	private ring: SVGSVGElement;
	private particles: Particle[] = [];
	private petalPaths: Path2D[];
	private raf = 0;
	private last = 0;
	private mode: BloomMode = "idle";
	private progress = 0;
	private rate = 0; // pollen per second
	private spawnDebt = 0;
	private readonly reduced: boolean;
	private resizeObs: ResizeObserver;
	private w = 0;
	private h = 0;
	private dpr = 1;

	constructor(host: HTMLElement) {
		this.reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
		this.root = document.createElement("div");
		this.root.className = "bloom-stage";
		this.root.dataset.mode = "idle";

		const glow = document.createElement("div");
		glow.className = "bloom-glow";

		this.canvas = document.createElement("canvas");
		this.canvas.className = "bloom-particles";
		this.canvas.setAttribute("aria-hidden", "true");
		this.ctx = this.canvas.getContext("2d")!;

		this.ring = this.buildRing();
		this.mark = this.buildMark();

		const markWrap = document.createElement("div");
		markWrap.className = "bloom-mark-wrap";
		markWrap.append(this.mark);

		this.root.append(glow, this.canvas, this.ring, markWrap);
		host.append(this.root);
		this.petalPaths = PETALS.map((p) => new Path2D(p.d));

		this.resizeObs = new ResizeObserver(() => this.resize());
		this.resizeObs.observe(this.root);
		this.resize();
		document.addEventListener("visibilitychange", this.onVisibility);
		this.setProgress(0);
		this.kick();
	}

	private buildMark(): SVGSVGElement {
		const id = `bs${uid++}`;
		const svg = el("svg", { viewBox: "0 0 108 108", class: "bloom-mark", "aria-hidden": "true" });
		const defs = el("defs");
		PETALS.forEach((p, i) => {
			const g = el("linearGradient", { id: `${id}-g${i}`, gradientUnits: "userSpaceOnUse", x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2 });
			g.append(el("stop", { offset: 0, "stop-color": p.light }), el("stop", { offset: 1, "stop-color": p.deep }));
			const clip = el("clipPath", { id: `${id}-c${i}` });
			const circle = el("circle", { cx: CENTER, cy: CENTER, r: R_MAX });
			clip.append(circle);
			this.clips.push(circle);
			defs.append(g, clip);
		});
		svg.append(defs);
		PETALS.forEach((p, i) => {
			const g = el("g", { class: `petal petal-${p.name}` });
			g.style.setProperty("--dx", `${DIRECTION[p.name][0] * 7}px`);
			g.style.setProperty("--dy", `${DIRECTION[p.name][1] * 7}px`);
			g.style.setProperty("--i", String(i));
			g.append(el("path", { d: p.d, class: "petal-ghost" }), el("path", { d: p.d, class: "petal-fill", fill: `url(#${id}-g${i})`, "clip-path": `url(#${id}-c${i})` }));
			this.petalGroups.push(g);
			svg.append(g);
		});
		return svg;
	}

	private buildRing(): SVGSVGElement {
		const svg = el("svg", { viewBox: "0 0 200 200", class: "bloom-ring", "aria-hidden": "true" });
		svg.append(el("circle", { cx: 100, cy: 100, r: 92, class: "bloom-ring-track" }));
		const len = 2 * Math.PI * 92;
		PETALS.forEach((p, i) => {
			const c = el("circle", {
				cx: 100,
				cy: 100,
				r: 92,
				class: "bloom-ring-arc",
				stroke: p.mid,
				"stroke-dasharray": `0 ${len}`,
				transform: `rotate(${-90 + i * 90} 100 100)`,
			});
			this.ringArcs.push(c);
			svg.append(c);
		});
		return svg;
	}

	private onVisibility = () => {
		if (document.visibilityState === "visible") this.kick();
	};

	private resize() {
		const r = this.root.getBoundingClientRect();
		this.dpr = Math.min(window.devicePixelRatio || 1, 2);
		this.w = r.width;
		this.h = r.height;
		this.canvas.width = Math.max(1, Math.round(r.width * this.dpr));
		this.canvas.height = Math.max(1, Math.round(r.height * this.dpr));
	}

	setMode(mode: BloomMode) {
		if (mode === this.mode) return;
		this.mode = mode;
		this.root.dataset.mode = mode;
		// The full bloom's rules would otherwise outrank every later mode's (another phone's install)
		if (mode !== "complete") this.root.classList.remove("is-blooming");
		if (mode === "download") this.rate = 18;
		else if (mode === "idle") this.rate = 2.5;
		else this.rate = 0;
		if (mode === "complete") this.setProgress(1);
		this.kick();
	}

	/** 0..1: petals fill in turn (download), the ring fills (install). */
	setProgress(p: number) {
		this.progress = Math.max(0, Math.min(1, p));
		const filling = this.mode === "download" || this.mode === "idle";
		this.clips.forEach((c, i) => {
			const f = filling ? Math.max(0, Math.min(1, this.progress * 4 - i)) : 1;
			c.setAttribute("r", String(R_MIN + (R_MAX - R_MIN) * f));
			this.petalGroups[i].classList.toggle("is-full", f >= 1);
		});
		const len = 2 * Math.PI * 92;
		const ringOn = this.mode === "install" || this.mode === "waiting" || this.mode === "complete";
		this.ringArcs.forEach((c, i) => {
			const f = ringOn ? Math.max(0, Math.min(1, this.progress * 4 - i)) : 0;
			const seg = (len / 4) * f;
			c.setAttribute("stroke-dasharray", `${seg} ${len}`);
		});
	}

	/** Pollen per second while downloading, from the download speed (bytes/s). */
	setSpeed(bytesPerSecond: number) {
		if (this.mode !== "download") return;
		const mb = bytesPerSecond / (1024 * 1024);
		this.rate = Math.max(6, Math.min(60, 6 + mb * 2));
	}

	private stageScale() {
		return Math.min(this.w, this.h) / 108;
	}

	private center(): [number, number] {
		return [this.w / 2, this.h / 2];
	}

	/** A few petals thrown off the flower (a partition written). */
	pulse(petal?: number) {
		if (this.reduced) return;
		const [cx, cy] = this.center();
		const s = this.stageScale();
		for (let k = 0; k < 14; k++) {
			const i = petal ?? k % 4;
			const p = PETALS[i];
			const [dx, dy] = DIRECTION[p.name];
			const a = Math.atan2(dy, dx) + (Math.random() - 0.5) * 1.6;
			const sp = (0.9 + Math.random() * 1.2) * s * 22;
			this.particles.push({
				x: cx + dx * s * 16,
				y: cy + dy * s * 16,
				vx: Math.cos(a) * sp,
				vy: Math.sin(a) * sp,
				life: 0,
				max: 1.1 + Math.random() * 0.6,
				size: s * (0.05 + Math.random() * 0.05),
				color: [p.light, p.mid, p.deep][k % 3],
				rot: Math.random() * Math.PI * 2,
				vr: (Math.random() - 0.5) * 4,
				kind: "petal",
				petal: this.petalPaths[i],
			});
		}
		this.kick();
	}

	/** Full bloom: petals spread and spring back, and a burst of petals and sparks. */
	celebrate() {
		this.setMode("complete");
		this.root.classList.remove("is-blooming");
		void this.root.offsetWidth;
		this.root.classList.add("is-blooming");
		if (this.reduced) return;
		const [cx, cy] = this.center();
		const s = this.stageScale();
		for (let k = 0; k < 170; k++) {
			const i = k % 4;
			const p = PETALS[i];
			const a = Math.random() * Math.PI * 2;
			const sp = (0.6 + Math.random() * 1.9) * s * 48;
			const spark = k % 5 === 0;
			this.particles.push({
				x: cx,
				y: cy,
				vx: Math.cos(a) * sp,
				vy: Math.sin(a) * sp - s * 20,
				life: -Math.random() * 0.25,
				max: 2.2 + Math.random() * 1.6,
				size: spark ? s * (0.6 + Math.random()) : s * (0.06 + Math.random() * 0.09),
				color: [p.light, p.mid, p.deep][Math.floor(Math.random() * 3)],
				rot: Math.random() * Math.PI * 2,
				vr: (Math.random() - 0.5) * 6,
				kind: spark ? "spark" : "petal",
				petal: this.petalPaths[i],
			});
		}
		this.kick();
	}

	private spawnPollen(dt: number) {
		if (this.reduced || this.rate <= 0) return;
		this.spawnDebt += this.rate * dt;
		const [cx, cy] = this.center();
		const s = this.stageScale();
		const filling = Math.min(3, Math.floor(this.progress * 4));
		while (this.spawnDebt >= 1) {
			this.spawnDebt -= 1;
			const a = Math.random() * Math.PI * 2;
			const r = Math.max(this.w, this.h) * (0.48 + Math.random() * 0.12);
			const p = PETALS[this.mode === "download" ? filling : Math.floor(Math.random() * 4)];
			const [dx, dy] = DIRECTION[p.name];
			this.particles.push({
				x: cx + Math.cos(a) * r,
				y: cy + Math.sin(a) * r,
				vx: -Math.sin(a) * s * 18,
				vy: Math.cos(a) * s * 18,
				life: 0,
				max: this.mode === "idle" ? 6 : 2.4,
				size: s * (0.35 + Math.random() * 0.5),
				color: Math.random() < 0.5 ? p.light : p.mid,
				rot: 0,
				vr: 0,
				kind: "pollen",
				tx: cx + dx * s * 14,
				ty: cy + dy * s * 14,
			});
		}
	}

	private kick() {
		if (this.raf || document.visibilityState === "hidden") return;
		this.last = performance.now();
		this.raf = requestAnimationFrame(this.frame);
	}

	private frame = (now: number) => {
		this.raf = 0;
		const dt = Math.min(0.05, (now - this.last) / 1000);
		this.last = now;
		this.spawnPollen(dt);
		const ctx = this.ctx;
		ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
		ctx.clearRect(0, 0, this.w, this.h);
		const s = this.stageScale();
		const keep: Particle[] = [];
		for (const p of this.particles) {
			p.life += dt;
			if (p.life < 0) {
				keep.push(p);
				continue;
			}
			if (p.life > p.max) continue;
			const t = p.life / p.max;
			if (p.kind === "pollen") {
				// Spiral in towards the flower and fade as it arrives
				const dx = (p.tx ?? 0) - p.x;
				const dy = (p.ty ?? 0) - p.y;
				const d = Math.hypot(dx, dy);
				if (d < s * 6) continue;
				const pull = s * 260;
				p.vx += (dx / d) * pull * dt;
				p.vy += (dy / d) * pull * dt;
				p.vx *= 1 - 1.6 * dt;
				p.vy *= 1 - 1.6 * dt;
			} else {
				p.vy += s * 42 * dt; // gravity
				p.vx *= 1 - 0.9 * dt;
				p.vy *= 1 - 0.9 * dt;
				p.rot += p.vr * dt;
			}
			p.x += p.vx * dt;
			p.y += p.vy * dt;
			const alpha = p.kind === "pollen" ? Math.min(1, p.life * 3) * (1 - t * t) : t < 0.1 ? t * 10 : 1 - Math.pow((t - 0.1) / 0.9, 2);
			ctx.globalAlpha = Math.max(0, alpha);
			ctx.fillStyle = p.color;
			if (p.kind === "petal" && p.petal) {
				ctx.save();
				ctx.translate(p.x, p.y);
				ctx.rotate(p.rot);
				ctx.scale(p.size, p.size);
				ctx.translate(-CENTER, -CENTER);
				ctx.fill(p.petal);
				ctx.restore();
			} else {
				ctx.beginPath();
				ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
				ctx.fill();
				if (p.kind === "spark") {
					ctx.globalAlpha = Math.max(0, alpha * 0.25);
					ctx.beginPath();
					ctx.arc(p.x, p.y, p.size * 3, 0, Math.PI * 2);
					ctx.fill();
				}
			}
			keep.push(p);
		}
		ctx.globalAlpha = 1;
		this.particles = keep;
		if (this.particles.length || this.rate > 0) this.kick();
	};

	destroy() {
		cancelAnimationFrame(this.raf);
		this.resizeObs.disconnect();
		document.removeEventListener("visibilitychange", this.onVisibility);
		this.root.remove();
	}
}
