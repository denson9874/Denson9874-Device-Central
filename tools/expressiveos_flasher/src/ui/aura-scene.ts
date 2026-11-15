// The background aura: a full-page field of the four petal colours, flowing slowly behind
// everything, that follows the install. It listens for the Bloom stage's mode and progress
// (bloom.ts's BLOOM_EVENT): calm while idle, rising from the bottom as a build downloads,
// shimmering while it's checked, turning while it installs, breathing while it waits for the
// phone, a burst of light when it's done, and a cooler, drained field on an error.
//
// three.js, loaded after first paint with the 3D flower's chunk (main.ts), which shares three
// with it: a full-screen plane and a fragment shader, drawn at a fraction of the page's
// resolution (it's all soft light anyway), at most 30 frames a second, never while the tab is
// hidden. With reduced motion it draws one still frame per change. Until it loads, and without
// WebGL, the CSS gradient under it (body::before) is the background. It takes on the chosen
// phone's colours (palettes.ts) with the flower.

import { Color, LinearSRGBColorSpace, Mesh, OrthographicCamera, PlaneGeometry, Scene, ShaderMaterial, Vector2, WebGLRenderer } from "three";
import { BLOOM_EVENT, type BloomEventDetail, type BloomMode, currentBloom } from "./bloom.ts";
import type { Palette } from "./palettes.ts";

const VERT = `void main(){ gl_Position = vec4(position.xy, 0.0, 1.0); }`;

const FRAG = `uniform vec2 uRes;
uniform float uTime;
uniform vec2 uPointer;
uniform float uDark;
uniform float uEnergy;
uniform float uRise;
uniform float uSpin;
uniform float uBurst;
uniform float uDrain;
uniform float uShimmer;
uniform vec3 uC0;
uniform vec3 uC1;
uniform vec3 uC2;
uniform vec3 uC3;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p){
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p){
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 17.0; a *= 0.5; }
	return v;
}
vec2 rot(vec2 v, float a){ float c = cos(a), s = sin(a); return vec2(c * v.x - s * v.y, s * v.x + c * v.y); }

void main(){
	vec2 uv = gl_FragCoord.xy / uRes;
	float aspect = uRes.x / uRes.y;
	vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
	float t = uTime * (0.045 + 0.09 * uEnergy);

	// Domain-warped flow so the colour fields drift like light through silk
	vec2 w = vec2(fbm(p * 1.4 + t), fbm(p * 1.4 - t + 5.2));
	vec2 q = p + (w - 0.5) * (0.55 + 0.35 * uEnergy);
	q = rot(q, uSpin);

	// Four petal lights orbiting the page, pulled toward the pointer a little
	vec2 pull = (uPointer - 0.5) * vec2(aspect, 1.0) * 0.18;
	float r = 0.62 + 0.06 * sin(uTime * 0.21);
	vec2 o0 = vec2(-0.55, 0.38) * r + vec2(sin(t * 3.1), cos(t * 2.3)) * 0.14 + pull;
	vec2 o1 = vec2(0.6, 0.42) * r + vec2(cos(t * 2.7), sin(t * 3.3)) * 0.14 + pull;
	vec2 o2 = vec2(0.58, -0.45) * r + vec2(sin(t * 2.2 + 1.0), cos(t * 2.9)) * 0.14 + pull;
	vec2 o3 = vec2(-0.6, -0.42) * r + vec2(cos(t * 3.4 + 2.0), sin(t * 2.1)) * 0.14 + pull;
	float k = 2.4 - 0.6 * uEnergy;
	float g0 = exp(-k * dot(q - o0, q - o0) * 2.2);
	float g1 = exp(-k * dot(q - o1, q - o1) * 2.2);
	float g2 = exp(-k * dot(q - o2, q - o2) * 2.2);
	float g3 = exp(-k * dot(q - o3, q - o3) * 2.2);
	vec3 aura = uC0 * g0 + uC1 * g1 + uC2 * g2 + uC3 * g3;

	// A download fills the page from the bottom with a rising tide of all four colours
	float tide = smoothstep(uRise + 0.12, uRise - 0.22, uv.y + (fbm(vec2(uv.x * 3.0, uTime * 0.2)) - 0.5) * 0.12) * step(0.001, uRise);
	vec3 tideCol = mix(mix(uC0, uC1, uv.x), mix(uC3, uC2, uv.x), 0.5);
	aura += tideCol * tide * 0.35;

	// Checking: a slow band of light sweeps across
	float band = exp(-pow((uv.x + uv.y * 0.35) - fract(uTime * 0.12) * 1.8 + 0.3, 2.0) * 60.0);
	aura += vec3(1.0) * band * 0.12 * uShimmer;

	// Done: light blooms out from the centre and fades
	float d = length(p);
	aura += mix(uC1, uC0, 0.5) * uBurst * exp(-d * d * 3.0) * 1.2;

	float strength = mix(0.55, 0.85, uEnergy);
	vec3 base = mix(vec3(0.961, 0.945, 1.0), vec3(0.051, 0.047, 0.114), uDark);
	vec3 col;
	if (uDark > 0.5) {
		col = base + aura * strength * 0.5;
	} else {
		col = mix(base, base * (0.72 + 0.28 * aura) + aura * 0.18, clamp(length(aura) * strength, 0.0, 0.9));
	}
	// Capped under the content: even the celebration's burst stays a dim field in dark, so the
	// panels' glass and the header keep their contrast over it
	if (uDark > 0.5) {
		float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col *= min(1.0, 0.36 / max(luma, 0.0001));
	}
	// An error drains the colour toward a cool grey with a coral edge
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, mix(vec3(lum), uC3 * lum * 1.6, 0.18), uDrain * 0.7);

	// Vignette and fine grain against banding
	col *= mix(1.0, 1.0 - 0.38 * smoothstep(0.35, 1.05, d), uDark);
	col += (hash(gl_FragCoord.xy + uTime) - 0.5) * 0.012;
	gl_FragColor = vec4(col, 1.0);
}`;

const SCALE = 0.4;
const FRAME_MS = 1000 / 30;

interface Targets {
	energy: number;
	rise: number;
	spinRate: number;
	shimmer: number;
	drain: number;
}

function targetsFor(mode: BloomMode, progress: number): Targets {
	switch (mode) {
		case "download":
			return { energy: 0.6, rise: 0.08 + progress * 0.6, spinRate: 0, shimmer: 0, drain: 0 };
		case "verify":
			return { energy: 0.45, rise: 0.68, spinRate: 0, shimmer: 1, drain: 0 };
		case "install":
			return { energy: 0.8, rise: 0.25 + progress * 0.5, spinRate: 0.06 + progress * 0.08, shimmer: 0, drain: 0 };
		case "waiting":
			return { energy: 0.3, rise: 0.2, spinRate: 0.02, shimmer: 0, drain: 0 };
		case "complete":
			return { energy: 1, rise: 0.95, spinRate: 0.03, shimmer: 0, drain: 0 };
		case "error":
			return { energy: 0.15, rise: 0, spinRate: 0, shimmer: 0, drain: 1 };
		default:
			return { energy: 0.35, rise: 0, spinRate: 0, shimmer: 0, drain: 0 };
	}
}

/**
 * The shader works in the page's own (sRGB) values and writes them straight out, as the CSS
 * colours it sits under do: keep the hex values as they are rather than converting to linear.
 */
function shaderColor(hex: string, into = new Color()): Color {
	return into.setStyle(hex, LinearSRGBColorSpace);
}

function isDark(): boolean {
	const t = document.documentElement.dataset.theme;
	if (t === "dark") return true;
	if (t === "light") return false;
	return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

export class Aura {
	private readonly renderer: WebGLRenderer;
	private readonly scene = new Scene();
	private readonly camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
	private readonly material: ShaderMaterial;
	private readonly u: Record<string, { value: number | Vector2 | Color }>;
	private readonly colors: Color[];
	private readonly colorTargets: Color[];
	private readonly reduced: boolean;
	private raf = 0;
	private last = 0;
	private start = performance.now();
	private target: Targets;
	private cur: Targets;
	private spin = 0;
	private burst = 0;
	private dark = isDark() ? 1 : 0;
	private pointer: [number, number] = [0.5, 0.5];
	private pointerTarget: [number, number] = [0.5, 0.5];

	/** Null when the page can't draw it (no WebGL): the CSS gradient stays. */
	static mount(): Aura | null {
		try {
			return new Aura();
		} catch {
			return null;
		}
	}

	private constructor() {
		this.reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
		this.renderer = new WebGLRenderer({ antialias: false, alpha: false, powerPreference: "low-power" });
		this.renderer.setPixelRatio(1);
		const canvas = this.renderer.domElement;
		canvas.className = "aura";
		canvas.setAttribute("aria-hidden", "true");

		const state = currentBloom();
		this.target = targetsFor(state.mode, state.progress);
		this.cur = { ...this.target };
		this.colors = state.palette.petals.map((t) => shaderColor(t.mid));
		this.colorTargets = this.colors.map((c) => c.clone());
		this.u = {
			uRes: { value: new Vector2(1, 1) },
			uTime: { value: 0 },
			uPointer: { value: new Vector2(0.5, 0.5) },
			uDark: { value: this.dark },
			uEnergy: { value: this.cur.energy },
			uRise: { value: this.cur.rise },
			uSpin: { value: 0 },
			uBurst: { value: 0 },
			uDrain: { value: this.cur.drain },
			uShimmer: { value: this.cur.shimmer },
			uC0: { value: this.colors[0] },
			uC1: { value: this.colors[1] },
			uC2: { value: this.colors[2] },
			uC3: { value: this.colors[3] },
		};
		this.material = new ShaderMaterial({ vertexShader: VERT, fragmentShader: FRAG, uniforms: this.u, depthTest: false, depthWrite: false });
		this.scene.add(new Mesh(new PlaneGeometry(2, 2), this.material));

		canvas.style.opacity = "0";
		document.body.prepend(canvas);
		document.documentElement.classList.add("has-aura");
		this.resize();
		// Fade in over the CSS gradient it replaces
		requestAnimationFrame(() => {
			canvas.style.transition = "opacity 1.2s ease";
			canvas.style.opacity = "1";
		});
		window.addEventListener("resize", () => {
			this.resize();
			this.kick();
		});
		document.addEventListener(BLOOM_EVENT, (e) => {
			const { mode, progress, palette } = (e as CustomEvent<BloomEventDetail>).detail;
			if (mode === "complete" && this.target.energy !== 1) this.burst = 1;
			this.target = targetsFor(mode, progress);
			this.setPalette(palette);
			this.kick();
		});
		window.addEventListener(
			"pointermove",
			(e) => {
				this.pointerTarget = [e.clientX / window.innerWidth, 1 - e.clientY / window.innerHeight];
			},
			{ passive: true },
		);
		document.addEventListener("visibilitychange", () => this.kick());
		new MutationObserver(() => this.kick()).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
		window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => this.kick());
		canvas.addEventListener("webglcontextlost", (e) => {
			e.preventDefault();
			cancelAnimationFrame(this.raf);
			this.raf = 0;
			canvas.remove();
			document.documentElement.classList.remove("has-aura");
		});
		this.kick();
	}

	private setPalette(palette: Palette) {
		palette.petals.forEach((t, i) => shaderColor(t.mid, this.colorTargets[i]));
	}

	private resize() {
		const w = Math.max(1, Math.round(window.innerWidth * SCALE));
		const h = Math.max(1, Math.round(window.innerHeight * SCALE));
		this.renderer.setSize(w, h, false);
		(this.u.uRes.value as Vector2).set(w, h);
	}

	private kick() {
		if (this.raf || document.hidden) return;
		this.raf = requestAnimationFrame((t) => this.frame(t));
	}

	private frame(now: number) {
		this.raf = 0;
		if (document.hidden) return;
		if (!this.reduced && now - this.last < FRAME_MS) {
			this.kick();
			return;
		}
		const dt = Math.min(0.1, (now - (this.last || now)) / 1000);
		this.last = now;
		const ease = this.reduced ? 1 : 1 - Math.exp(-dt * 2.2);
		const c = this.cur;
		const t = this.target;
		c.energy += (t.energy - c.energy) * ease;
		c.rise += (t.rise - c.rise) * ease;
		c.spinRate += (t.spinRate - c.spinRate) * ease;
		c.shimmer += (t.shimmer - c.shimmer) * ease;
		c.drain += (t.drain - c.drain) * ease;
		this.colors.forEach((col, i) => col.lerp(this.colorTargets[i], this.reduced ? 1 : Math.min(1, dt * 1.6)));
		this.dark += ((isDark() ? 1 : 0) - this.dark) * (this.reduced ? 1 : 1 - Math.exp(-dt * 4));
		this.spin += c.spinRate * dt * Math.PI * 2;
		this.burst = this.reduced ? 0 : Math.max(0, this.burst - dt * 0.45);
		this.pointer[0] += (this.pointerTarget[0] - this.pointer[0]) * Math.min(1, dt * 2);
		this.pointer[1] += (this.pointerTarget[1] - this.pointer[1]) * Math.min(1, dt * 2);

		const u = this.u;
		u.uTime.value = this.reduced ? 12 : (now - this.start) / 1000;
		(u.uPointer.value as Vector2).set(this.pointer[0], this.pointer[1]);
		u.uDark.value = this.dark;
		u.uEnergy.value = c.energy;
		u.uRise.value = c.rise;
		u.uSpin.value = this.spin;
		u.uBurst.value = this.burst;
		u.uDrain.value = c.drain;
		u.uShimmer.value = c.shimmer;
		this.renderer.render(this.scene, this.camera);

		// Reduced motion: one still frame per change, nothing in between
		const settling = this.colors.some((col, i) => !col.equals(this.colorTargets[i]));
		if (!this.reduced || settling) this.kick();
	}
}
