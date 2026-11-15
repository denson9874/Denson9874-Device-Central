// The background aura: a full-page field of the four petal colours, flowing slowly behind
// everything, that follows the install. It listens for the Bloom stage's mode and progress
// (bloom.ts's BLOOM_EVENT): calm while idle, rising from the bottom as a build downloads,
// shimmering while it's checked, turning while it installs, breathing while it waits for the
// phone, a burst of light when it's done, and a cooler, drained field on an error.
//
// Plain WebGL (no three.js, so it costs nothing on first load): one full-screen triangle and a
// fragment shader, drawn at a fraction of the page's resolution (it's all soft light anyway), at
// most 30 frames a second, never while the tab is hidden. With reduced motion it draws one still
// frame per change. Without WebGL it does nothing and the CSS gradient under it (body::before)
// stays the background.

import { BLOOM_EVENT, type BloomEventDetail, type BloomMode } from "./bloom.ts";
import { PETALS } from "./petals.ts";

const VERT = `attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }`;

const FRAG = `precision mediump float;
uniform vec2 uRes;
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

function hexToRgb(hex: string): [number, number, number] {
	const n = Number.parseInt(hex.slice(1), 16);
	return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}

function isDark(): boolean {
	const t = document.documentElement.dataset.theme;
	if (t === "dark") return true;
	if (t === "light") return false;
	return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

export class Aura {
	private readonly canvas: HTMLCanvasElement;
	private readonly gl: WebGLRenderingContext;
	private readonly u: Record<string, WebGLUniformLocation | null> = {};
	private readonly reduced: boolean;
	private raf = 0;
	private last = 0;
	private start = performance.now();
	private target: Targets = targetsFor("idle", 0);
	private cur: Targets = { ...this.target };
	private spin = 0;
	private burst = 0;
	private dark = isDark() ? 1 : 0;
	private pointer: [number, number] = [0.5, 0.5];
	private pointerTarget: [number, number] = [0.5, 0.5];

	/** Null when the page can't draw it (no WebGL): the CSS gradient stays. */
	static mount(): Aura | null {
		try {
			const canvas = document.createElement("canvas");
			const gl = canvas.getContext("webgl", { antialias: false, alpha: false, premultipliedAlpha: false, powerPreference: "low-power" });
			if (!gl) return null;
			return new Aura(canvas, gl);
		} catch {
			return null;
		}
	}

	private constructor(canvas: HTMLCanvasElement, gl: WebGLRenderingContext) {
		this.canvas = canvas;
		this.gl = gl;
		this.reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
		canvas.className = "aura";
		canvas.setAttribute("aria-hidden", "true");
		const prog = this.program(VERT, FRAG);
		gl.useProgram(prog);
		const buf = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, buf);
		gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
		const loc = gl.getAttribLocation(prog, "p");
		gl.enableVertexAttribArray(loc);
		gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
		for (const n of ["uRes", "uTime", "uPointer", "uDark", "uEnergy", "uRise", "uSpin", "uBurst", "uDrain", "uShimmer", "uC0", "uC1", "uC2", "uC3"]) {
			this.u[n] = gl.getUniformLocation(prog, n);
		}
		PETALS.forEach((p, i) => gl.uniform3fv(this.u[`uC${i}`], hexToRgb(p.mid)));

		document.body.prepend(canvas);
		document.documentElement.classList.add("has-aura");
		this.resize();
		window.addEventListener("resize", () => {
			this.resize();
			this.kick();
		});
		document.addEventListener(BLOOM_EVENT, (e) => {
			const { mode, progress } = (e as CustomEvent<BloomEventDetail>).detail;
			if (mode === "complete" && this.target.energy !== 1) this.burst = 1;
			this.target = targetsFor(mode, progress);
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

	private program(vs: string, fs: string): WebGLProgram {
		const gl = this.gl;
		const make = (type: number, src: string) => {
			const s = gl.createShader(type)!;
			gl.shaderSource(s, src);
			gl.compileShader(s);
			if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) ?? "shader");
			return s;
		};
		const p = gl.createProgram()!;
		gl.attachShader(p, make(gl.VERTEX_SHADER, vs));
		gl.attachShader(p, make(gl.FRAGMENT_SHADER, fs));
		gl.linkProgram(p);
		if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p) ?? "program");
		return p;
	}

	private resize() {
		const w = Math.max(1, Math.round(window.innerWidth * SCALE));
		const h = Math.max(1, Math.round(window.innerHeight * SCALE));
		if (this.canvas.width !== w || this.canvas.height !== h) {
			this.canvas.width = w;
			this.canvas.height = h;
			this.gl.viewport(0, 0, w, h);
		}
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
		this.dark += ((isDark() ? 1 : 0) - this.dark) * (this.reduced ? 1 : 1 - Math.exp(-dt * 4));
		this.spin += c.spinRate * dt * Math.PI * 2;
		this.burst = this.reduced ? 0 : Math.max(0, this.burst - dt * 0.45);
		this.pointer[0] += (this.pointerTarget[0] - this.pointer[0]) * Math.min(1, dt * 2);
		this.pointer[1] += (this.pointerTarget[1] - this.pointer[1]) * Math.min(1, dt * 2);

		const gl = this.gl;
		const u = this.u;
		gl.uniform2f(u.uRes, this.canvas.width, this.canvas.height);
		gl.uniform1f(u.uTime, this.reduced ? 12 : (now - this.start) / 1000);
		gl.uniform2f(u.uPointer, this.pointer[0], this.pointer[1]);
		gl.uniform1f(u.uDark, this.dark);
		gl.uniform1f(u.uEnergy, c.energy);
		gl.uniform1f(u.uRise, c.rise);
		gl.uniform1f(u.uSpin, this.spin);
		gl.uniform1f(u.uBurst, this.burst);
		gl.uniform1f(u.uDrain, c.drain);
		gl.uniform1f(u.uShimmer, c.shimmer);
		gl.drawArrays(gl.TRIANGLES, 0, 3);

		// Reduced motion: one still frame per change, nothing in between
		if (!this.reduced) this.kick();
	}
}
