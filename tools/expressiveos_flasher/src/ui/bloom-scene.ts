/*
 * 3D ExpressiveOS Bloom Scene (Three.js)
 *
 * Petal curvature, studio PMREM environment lighting, luminous core/corona,
 * Fibonacci stamen arrangement, and floating pollen atmosphere techniques are
 * adapted from "Flowers For You" (https://github.com/hubshashwat/flowers):
 *
 * MIT License
 * Copyright (c) 2026 Shashwat
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 */

import {
	ACESFilmicToneMapping,
	AdditiveBlending,
	AmbientLight,
	BufferAttribute,
	BufferGeometry,
	CatmullRomCurve3,
	CanvasTexture,
	Color,
	CylinderGeometry,
	DirectionalLight,
	DoubleSide,
	DynamicDrawUsage,
	Float32BufferAttribute,
	Group,
	InstancedMesh,
	LatheGeometry,
	MathUtils,
	Mesh,
	MeshBasicMaterial,
	MeshPhysicalMaterial,
	Object3D,
	PCFSoftShadowMap,
	PerspectiveCamera,
	PlaneGeometry,
	PMREMGenerator,
	PointLight,
	Points,
	PointsMaterial,
	Quaternion,
	Scene,
	ShaderMaterial,
	Shape,
	SphereGeometry,
	Sprite,
	SpriteMaterial,
	SRGBColorSpace,
	TorusGeometry,
	TubeGeometry,
	Vector2,
	Vector3,
	WebGLRenderer,
} from "three";
import { PLANT_EVENT } from "./bloom.ts";
import { BRAND_PALETTE, type Palette } from "./palettes.ts";
import { PETALS, type Petal } from "./petals.ts";

export type BloomSceneMode = "idle" | "download" | "verify" | "install" | "waiting" | "complete" | "error";

const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

/** Outward unit direction in Three.js XY space (SVG +Y flipped to +Y up). */
const PETAL_DIRS: Record<Petal["name"], [number, number]> = {
	violet: [-0.69, 0.72],
	blue: [0.76, 0.65],
	green: [0.7, -0.72],
	coral: [-0.74, -0.67],
};

/** Slight Z and pitch stagger per brand petal so petals visibly layer in 3D space. */
const PETAL_LAYERS: Record<Petal["name"], { z: number; pitch: number }> = {
	violet: { z: 0.08, pitch: 0.28 },
	blue: { z: -0.02, pitch: 0.19 },
	green: { z: 0.06, pitch: 0.26 },
	coral: { z: -0.04, pitch: 0.17 },
};

const easeOutBack = (t: number): number => {
	const c1 = 1.70158;
	const c3 = c1 + 1;
	const u = MathUtils.clamp(t, 0, 1);
	return 1 + c3 * Math.pow(u - 1, 3) + c1 * Math.pow(u - 1, 2);
};

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - MathUtils.clamp(t, 0, 1), 3);
const smooth = (a: number, b: number, x: number): number => {
	const t = MathUtils.clamp((x - a) / (b - a), 0, 1);
	return t * t * (3 - 2 * t);
};

// The growth story's ground: the soil's top, below the flower
const SOIL_Y = -1.72;
// The canvas is this much larger than its box (styles.css .bloom-webgl), centred on it, and the
// camera zooms out to match: the ring, pollen and bursts can leave the box without being cut off
const OVERSCAN = 1.45;
// While the plant is small, the camera looks this far above the soil's top: the pot then sits a
// little below the stage's middle, with the sprout's room above it
const PLANTED_LOOK = 0.04;
// Where a spark waits while it isn't flying: behind the camera, so it's clipped. (In front of it,
// at the far plane's side, a dark unlit speck showed above the seed on a transparent canvas.)
const SPARK_PARKED_Z = 1000;
// The growth story's planter, per theme: a glazed pot (deep plum in dark, pale lilac in light)
// holding dark earth, so the seed reads as planted rather than resting on a floating disc
const SOIL_DARK = 0x33231f;
const SOIL_LIGHT = 0x4a3530;
const PEBBLE_DARK = 0x5a4a4a;
const PEBBLE_LIGHT = 0x8c7a72;
const POT_DARK = 0x4a3478;
const POT_LIGHT = 0xe2d6f6;
const STEM_SEGS = 96;
const STEM_RADIAL = 10;

/** Small helper clamp avoiding extra imports. */
const clamp01 = (v: number): number => (v < 0 ? 0 : v > 1 ? 1 : v);

/**
 * A real petal's outline, pointing out from the flower's centre along its brand position: a narrow
 * claw at the base, widening to a broad blade and a rounded tip with a shallow notch, a little
 * asymmetric (no two petals of a flower are the same).
 */
function botanicalPetalShape(petal: Petal): Shape {
	const [dx, dy] = PETAL_DIRS[petal.name];
	const seed = PETALS.indexOf(petal);
	const L = 1.42 + seed * 0.02;
	const W = 0.6;
	const skew = (seed % 2 === 0 ? 1 : -1) * 0.05;
	const n = 64;
	const width = (t: number) => {
		const claw = 0.16 + 0.84 * smooth(0, 0.5, t);
		const tip = t < 0.58 ? 1 : Math.sqrt(Math.max(0, 1 - ((t - 0.58) / 0.42) ** 2));
		return W * claw * tip;
	};
	const local: Array<[number, number]> = [];
	const point = (t: number, side: number): [number, number] => {
		const x = side * width(t) + skew * Math.sin(t * Math.PI);
		const notch = 0.07 * Math.exp(-((x / (0.22 * W)) ** 2)) * smooth(0.85, 1, t);
		return [x, t * L - notch];
	};
	for (let i = 0; i <= n; i++) local.push(point(i / n, 1));
	for (let i = n; i >= 0; i--) local.push(point(i / n, -1));
	// Local +y out along the petal's direction, +x to its right, from just off the centre
	const toWorld = ([x, y]: [number, number]): [number, number] => [dx * (0.05 + y) + dy * x, dy * (0.05 + y) - dx * x];
	const shape = new Shape();
	local.forEach((p, i) => {
		const [wx, wy] = toWorld(p);
		if (i === 0) shape.moveTo(wx, wy);
		else shape.lineTo(wx, wy);
	});
	shape.closePath();
	return shape;
}

/**
 * A thick petal solid meshed densely enough to bend smoothly: rings from the outline's centroid
 * out to the outline on the front and back faces, joined by a rounded rim. ExtrudeGeometry
 * meshes its caps from the outline alone (a few long triangles), so cupping them showed facets.
 */
function createDensePetalSolid(shape: Shape, thickness = 0.13, rings = 22, rimSteps = 7): BufferGeometry {
	const outline = shape.getSpacedPoints(176).slice(0, -1);
	const k = outline.length;
	let cx = 0;
	let cy = 0;
	for (const p of outline) {
		cx += p.x;
		cy += p.y;
	}
	cx /= k;
	cy /= k;
	// Outward 2D normal at each outline point (away from the centroid)
	const nx = new Float32Array(k);
	const ny = new Float32Array(k);
	for (let i = 0; i < k; i++) {
		const a = outline[(i + k - 1) % k];
		const b = outline[(i + 1) % k];
		let x = b.y - a.y;
		let y = -(b.x - a.x);
		const len = Math.hypot(x, y) || 1;
		x /= len;
		y /= len;
		if (x * (outline[i].x - cx) + y * (outline[i].y - cy) < 0) {
			x = -x;
			y = -y;
		}
		nx[i] = x;
		ny[i] = y;
	}
	const half = thickness / 2;
	const rows: Array<(i: number) => [number, number, number]> = [];
	const ring = (t: number, z: number) => (i: number): [number, number, number] => [
		cx + (outline[i].x - cx) * t,
		cy + (outline[i].y - cy) * t,
		z,
	];
	for (let r = 0; r <= rings; r++) rows.push(ring(r / rings, half));
	for (let j = 1; j < rimSteps; j++) {
		const a = Math.PI / 2 - (Math.PI * j) / rimSteps;
		const out = Math.cos(a) * half * 0.9;
		const z = Math.sin(a) * half;
		rows.push((i) => [outline[i].x + nx[i] * out, outline[i].y + ny[i] * out, z]);
	}
	for (let r = rings; r >= 0; r--) rows.push(ring(r / rings, -half));

	const positions = new Float32Array(rows.length * k * 3);
	// How far out from the centroid (0) to the edge (1), and where round the outline (0..1)
	const ringAttr = new Float32Array(rows.length * k);
	const aroundAttr = new Float32Array(rows.length * k);
	const frontRows = rings + 1;
	const rimRows = rimSteps - 1;
	rows.forEach((row, ri) => {
		const ring = ri < frontRows ? ri / rings : ri < frontRows + rimRows ? 1 : (rows.length - 1 - ri) / rings;
		for (let i = 0; i < k; i++) {
			positions.set(row(i), (ri * k + i) * 3);
			ringAttr[ri * k + i] = ring;
			aroundAttr[ri * k + i] = i / k;
		}
	});
	const index: number[] = [];
	for (let ri = 0; ri < rows.length - 1; ri++) {
		for (let i = 0; i < k; i++) {
			const a = ri * k + i;
			const b = ri * k + ((i + 1) % k);
			const c = (ri + 1) * k + i;
			const d = (ri + 1) * k + ((i + 1) % k);
			index.push(a, c, b, b, c, d);
		}
	}
	const geom = new BufferGeometry();
	geom.setAttribute("position", new BufferAttribute(positions, 3));
	geom.setAttribute("aRing", new BufferAttribute(ringAttr, 1));
	geom.setAttribute("aAround", new BufferAttribute(aroundAttr, 1));
	geom.setIndex(index);
	geom.computeVertexNormals();
	// The winding follows the outline's direction: the front face's normals must point at the camera
	const frontNormalZ = geom.attributes.normal.getZ(Math.floor(rings / 2) * k);
	if (frontNormalZ < 0) {
		for (let t = 0; t < index.length; t += 3) [index[t + 1], index[t + 2]] = [index[t + 2], index[t + 1]];
		geom.setIndex(index);
	}
	return geom;
}

/** Build a deeply sculpted, cupped 3D ExpressiveOS brand petal with thickness, camber, vertex gradient, and radial fill attribute. */
function createBrandPetalGeometry(petal: Petal): BufferGeometry {
	const geom = createDensePetalSolid(botanicalPetalShape(petal));

	const pos = geom.attributes.position;
	const count = pos.count;
	const colors = new Float32Array(count * 3);
	const fillAttr = new Float32Array(count);
	const crossAttr = new Float32Array(count);
	const ringAttr = geom.attributes.aRing;
	const aroundAttr = geom.attributes.aAround;
	const rufflePhase = PETALS.indexOf(petal) * 1.7;

	const [dx, dy] = PETAL_DIRS[petal.name];

	for (let i = 0; i < count; i++) {
		const x = pos.getX(i);
		const y = pos.getY(i);
		const z = pos.getZ(i);

		const r = Math.hypot(x, y);
		const rNorm = MathUtils.clamp((r - 0.14) / 1.45, 0, 1);
		fillAttr[i] = rNorm;

		// Transverse coordinate across petal spine (0 on centerline, +/- away from centerline)
		const cross = x * dy - y * dx;

		// Botanical spoon cupping + curved forward arch + outer rim flare + gentle cross camber (adapted from flowers-ref/js/utils.js)
		const spoonCup = Math.sin(rNorm * Math.PI * 0.84) * 0.34 - Math.pow(rNorm, 2.05) * 0.17;
		const transverseCup = cross * cross * 0.38 * (1 - rNorm * 0.35);
		const centerVeinRib = Math.exp(-cross * cross * 14) * Math.sin(rNorm * Math.PI) * 0.045;
		// A soft ruffle along the outer edge, as real petals have
		const ruffle = Math.sin(aroundAttr.getX(i) * Math.PI * 2 * 7 + rufflePhase) * 0.04 * smooth(0.7, 1, ringAttr.getX(i));
		pos.setZ(i, z + spoonCup + transverseCup + centerVeinRib + ruffle);
		crossAttr[i] = cross;

		// Occlusion only: the colour comes from the palette in the shader, so a phone's palette can change it
		const ao = 0.64 + 0.36 * clamp01(rNorm / 0.38);
		colors[i * 3] = ao;
		colors[i * 3 + 1] = ao;
		colors[i * 3 + 2] = ao;
	}

	pos.needsUpdate = true;
	geom.setAttribute("color", new BufferAttribute(colors, 3));
	geom.setAttribute("aFill", new Float32BufferAttribute(fillAttr, 1));
	geom.setAttribute("aCross", new Float32BufferAttribute(crossAttr, 1));
	geom.computeVertexNormals();
	return geom;
}

/** Dual-axis curved translucent backing petal geometry (adapted from flowers-ref/js/utils.js). */
function createCalixPetalGeometry(width = 0.58, length = 1.38): BufferGeometry {
	const uSegs = 16;
	const vSegs = 24;
	const geom = new PlaneGeometry(width, length, uSegs, vSegs);
	const pos = geom.attributes.position;
	const cup = 0.24;
	const curl = 0.3;
	const flare = 0.12;
	const ruffle = 0.025;

	for (let i = 0; i < pos.count; i++) {
		const x = pos.getX(i);
		const y = pos.getY(i) + length * 0.5;
		pos.setY(i, y);

		const v = MathUtils.clamp(y / length, 0, 1);
		const u = x / (width * 0.5);

		const widthScale = Math.sin(Math.pow(v, 0.72) * Math.PI);
		pos.setX(i, x * Math.max(0.06, widthScale));

		const cupOffset = (1 - u * u) * Math.sin(v * Math.PI * 0.85) * cup;
		const curlOffset = Math.pow(v, 1.6) * curl - Math.sin(v * Math.PI) * flare;
		const edgeDist = Math.abs(u);
		const edgeRuffle = edgeDist > 0.5 ? Math.sin(v * 20 + edgeDist * 5) * ruffle * (edgeDist - 0.5) : 0;

		pos.setZ(i, cupOffset - curlOffset + edgeRuffle);
	}

	pos.needsUpdate = true;
	geom.computeVertexNormals();
	return geom;
}

/** Procedural soft-glow or soft-occlusion radial sprite texture. */
function createRadialTexture(innerStop: string, midStop: string, edgeMidStop = "rgba(255,255,255,0.06)"): CanvasTexture {
	const canvas = document.createElement("canvas");
	canvas.width = 128;
	canvas.height = 128;
	const ctx = canvas.getContext("2d")!;
	const g = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
	g.addColorStop(0, innerStop);
	g.addColorStop(0.32, midStop);
	g.addColorStop(0.68, edgeMidStop);
	g.addColorStop(1, "rgba(0,0,0,0)");
	ctx.fillStyle = g;
	ctx.fillRect(0, 0, 128, 128);
	const tex = new CanvasTexture(canvas);
	tex.colorSpace = SRGBColorSpace;
	return tex;
}

/** Studio softbox environment map via PMREM (adapted from flowers-ref/js/utils.js). */
function createStudioEnvTexture(renderer: WebGLRenderer, lightTheme: boolean) {
	const canvas = document.createElement("canvas");
	canvas.width = 512;
	canvas.height = 256;
	const ctx = canvas.getContext("2d")!;

	const bg = ctx.createLinearGradient(0, 0, 0, 256);
	if (lightTheme) {
		bg.addColorStop(0, "#ffffff");
		bg.addColorStop(0.5, "#ebe4ff");
		bg.addColorStop(1, "#cec1f4");
	} else {
		bg.addColorStop(0, "#24204e");
		bg.addColorStop(0.45, "#12102a");
		bg.addColorStop(1, "#060612");
	}
	ctx.fillStyle = bg;
	ctx.fillRect(0, 0, 512, 256);

	const drawLight = (x: number, y: number, r: number, inner: string, mid: string) => {
		const g = ctx.createRadialGradient(x, y, 4, x, y, r);
		g.addColorStop(0, inner);
		g.addColorStop(0.42, mid);
		g.addColorStop(1, "transparent");
		ctx.fillStyle = g;
		ctx.fillRect(x - r, y - r, r * 2, r * 2);
	};

	// High-contrast studio strip softboxes for crisp curved specular highlights on petal bevels
	drawLight(150, 58, 125, "#ffffff", lightTheme ? "rgba(243, 177, 252, 0.58)" : "rgba(243, 177, 252, 0.72)");
	drawLight(385, 86, 115, "#f5f8ff", lightTheme ? "rgba(118, 188, 251, 0.52)" : "rgba(118, 188, 251, 0.65)");
	drawLight(256, 206, 130, "rgba(253, 207, 142, 0.52)", "rgba(172, 239, 179, 0.25)");

	const equirect = new CanvasTexture(canvas);
	equirect.colorSpace = SRGBColorSpace;
	const pmrem = new PMREMGenerator(renderer);
	const rt = pmrem.fromEquirectangular(equirect);
	equirect.dispose();
	pmrem.dispose();
	return rt;
}

interface PetalUniforms {
	uFill: { value: number };
	uTime: { value: number };
	uRipple: { value: number };
	uShimmer: { value: number };
	uWilt: { value: number };
	uPhase: { value: number };
	uGhostColor: { value: Color };
	uPetalLight: { value: Color };
	uLight: { value: Color };
	uMid: { value: Color };
	uDeep: { value: Color };
}

interface HeroPetalItem {
	petal: Petal;
	pivot: Group;
	mesh: Mesh;
	material: MeshPhysicalMaterial;
	uniforms: PetalUniforms;
	perpAxis: Vector3;
	baseZ: number;
	basePitch: number;
	fill: number;
	targetFill: number;
	wasFull: boolean;
	popTimer: number;
	pulseFlash: number;
}

interface BackingPetalItem {
	pivot: Group;
	mesh: Mesh;
	material: MeshPhysicalMaterial;
	baseRotX: number;
	phase: number;
}

interface PollenParticle {
	x: number;
	y: number;
	z: number;
	vx: number;
	vy: number;
	vz: number;
	life: number;
	max: number;
	petalIdx: number;
	kind: "ambient" | "inward" | "spark";
	orbitR: number;
	orbitAngle: number;
	orbitSpeed: number;
}

interface BurstPetal {
	active: boolean;
	x: number;
	y: number;
	z: number;
	vx: number;
	vy: number;
	vz: number;
	rx: number;
	ry: number;
	rz: number;
	vrx: number;
	vry: number;
	vrz: number;
	life: number;
	max: number;
	scale: number;
	color: Color;
}

const MAX_AMBIENT_POLLEN = 110;
const MAX_BURST_SPARKS = 90;
const MAX_BURST_PETALS = 96;

export class BloomScene {
	private readonly container: HTMLElement;
	private readonly renderer: WebGLRenderer;
	private readonly scene: Scene;
	private readonly camera: PerspectiveCamera;
	private readonly flowerGroup: Group;
	private readonly coreGroup: Group;
	private readonly coreLight: PointLight;
	private readonly coronaSprite: Sprite;
	private readonly coronaMat: SpriteMaterial;
	private readonly centerShadowMat: MeshBasicMaterial;
	private readonly keyLight: DirectionalLight;
	private readonly rimLight: DirectionalLight;
	private readonly fillLight: DirectionalLight;
	private readonly ambientLight: AmbientLight;

	private readonly heroPetals: HeroPetalItem[] = [];
	private readonly backingPetals: BackingPetalItem[] = [];
	private readonly ringUniforms: {
		uProgress: { value: number };
		uOpacity: { value: number };
		uPulse: { value: number };
		uTime: { value: number };
		uC0: { value: Color };
		uC1: { value: Color };
		uC2: { value: Color };
		uC3: { value: Color };
	};
	// The chosen phone's colours (palettes.ts): the flower eases into them
	private palette: Palette = BRAND_PALETTE;
	private readonly paletteTarget = BRAND_PALETTE.petals.map((t) => ({ light: new Color(t.light), mid: new Color(t.mid), deep: new Color(t.deep) }));
	private readonly coreTint = new Color(0xc084fc);
	private readonly tmpColor = new Color();
	private readonly ringTrackMat: MeshBasicMaterial;
	private readonly ringMesh: Mesh;
	private readonly ringTrackMesh: Mesh;

	private readonly pollenGeom: BufferGeometry;
	private readonly pollenPos: Float32Array;
	private readonly pollenCol: Float32Array;
	private readonly pollenParticles: PollenParticle[] = [];
	private readonly pollenPoints: Points;

	private readonly sparkGeom: BufferGeometry;
	private readonly sparkPos: Float32Array;
	private readonly sparkCol: Float32Array;
	private readonly sparkParticles: PollenParticle[] = [];
	private readonly sparkPoints: Points;

	private readonly burstMesh: InstancedMesh;
	private readonly burstPetals: BurstPetal[] = [];
	private readonly dummy = new Object3D();
	private readonly tmpQuat = new Quaternion();

	private readonly disposables: Array<{ dispose: () => void }> = [];
	private envTargetDark: ReturnType<PMREMGenerator["fromEquirectangular"]> | null = null;
	private envTargetLight: ReturnType<PMREMGenerator["fromEquirectangular"]> | null = null;
	private isLight = false;

	private mode: BloomSceneMode = "idle";
	private progress = 1;
	private downloadRate = 0;

	private elapsed = 0;
	private lastFrameTime = 0;
	private raf = 0;
	private destroyed = false;

	private lastW = 0;
	private lastH = 0;
	private lastDpr = 0;

	private celebrateTimer = 0;
	private pendingCelebrate = false;
	private celebrateWaves: number[] = [];
	private celebrateClock = 0;

	// The growth story, 0..1: seed in the soil (0), sprout and seed leaves (download), stem
	// (check), true leaves and a swelling bud (install), the open flower (done, 1)
	private growth = 0;
	private growthTarget = 0;
	private pendingStage = 0;
	private planting = false;
	private seedDropPending = false;
	private seedDrop = 0;
	private sprouted = false;
	private plantGroup!: Group;
	private soilMat!: MeshPhysicalMaterial;
	private pebbleMat?: MeshPhysicalMaterial;
	private potMat?: MeshPhysicalMaterial;
	private seed!: Mesh;
	private stemGeom!: TubeGeometry;
	private stemCurve!: CatmullRomCurve3;
	private stemMesh!: Mesh;
	private stemTip!: Mesh;
	private readonly leaves: Array<{ pivot: Group; at: number; from: number; to: number; side: number; size: number }> = [];
	private wiltBlend = 0;
	private spinAngle = 0;
	private ringRot = 0;

	// Pointer parallax & spring-back drag orbit
	private pointerTarget = new Vector2(0, 0);
	private pointerCurrent = new Vector2(0, 0);
	private dragOffset = new Vector2(0, 0);
	private dragging = false;
	private lastDrag = new Vector2(0, 0);

	private resizeObs: ResizeObserver;
	private themeObs: MutationObserver;
	private colorSchemeQuery: MediaQueryList | null = null;

	constructor(container: HTMLElement) {
		this.container = container;

		this.renderer = new WebGLRenderer({
			antialias: true,
			alpha: true,
			powerPreference: "high-performance",
		});
		this.renderer.setClearColor(0x000000, 0);
		this.renderer.toneMapping = ACESFilmicToneMapping;
		this.renderer.toneMappingExposure = 0.95;
		this.renderer.shadowMap.enabled = true;
		this.renderer.shadowMap.type = PCFSoftShadowMap;
		this.renderer.domElement.className = "bloom-webgl";
		this.renderer.domElement.setAttribute("aria-hidden", "true");
		container.append(this.renderer.domElement);

		this.scene = new Scene();
		// Elevated 3/4 view (~11 deg above, subtle off-axis angle) so petal cup, bevel thickness, and overlap clearly read in 3D
		this.camera = new PerspectiveCamera(37, 1, 0.1, 40);
		this.camera.zoom = 1 / OVERSCAN;
		this.camera.position.set(0.46, 0.96, 5.15);
		this.camera.lookAt(0, -0.04, 0);

		// Sculpted studio lighting + soft self-shadowing across overlapping petals
		this.ambientLight = new AmbientLight(0xe4deff, 0.45);
		this.keyLight = new DirectionalLight(0xfff7f2, 2.35);
		this.keyLight.position.set(3.2, 4.4, 4.6);
		this.keyLight.castShadow = true;
		this.keyLight.shadow.mapSize.set(512, 512);
		this.keyLight.shadow.camera.near = 1;
		this.keyLight.shadow.camera.far = 14;
		this.keyLight.shadow.camera.left = -2.2;
		this.keyLight.shadow.camera.right = 2.2;
		this.keyLight.shadow.camera.top = 2.2;
		this.keyLight.shadow.camera.bottom = -2.2;
		this.keyLight.shadow.bias = -0.0018;
		this.keyLight.shadow.normalBias = 0.025;
		this.keyLight.shadow.radius = 4;

		// Neutral light, so each phone's petals show their own colours rather than a violet cast
		this.rimLight = new DirectionalLight(0xfff2f6, 1.25);
		this.rimLight.position.set(-3.8, 3.4, -2.4);

		this.fillLight = new DirectionalLight(0xe6edff, 0.6);
		this.fillLight.position.set(2.8, -2.8, 2.4);

		this.scene.add(this.ambientLight, this.keyLight, this.rimLight, this.fillLight);

		this.flowerGroup = new Group();
		this.scene.add(this.flowerGroup);

		// Sculpted calyx receptacle cup tucked behind center
		this.buildReceptacle();

		// Backing translucent calyx petals (from flowers-ref createCurvedPetalGeometry)
		this.buildBackingPetals();

		// 4 sculpted ExpressiveOS brand petals
		this.buildHeroPetals();

		// Luminous center hub, soft AO crevice disc, corona sprite & Fibonacci stamen anthers
		const { coreGroup, coreLight, coronaSprite, coronaMat, centerShadowMat } = this.buildCore();
		this.coreGroup = coreGroup;
		this.coreLight = coreLight;
		this.coronaSprite = coronaSprite;
		this.coronaMat = coronaMat;
		this.centerShadowMat = centerShadowMat;
		this.flowerGroup.add(this.coreGroup);

		// 3D orbital progress ring
		const ring = this.buildProgressRing();
		this.ringUniforms = ring.uniforms;
		this.ringTrackMat = ring.trackMat;
		this.ringMesh = ring.arcMesh;
		this.ringTrackMesh = ring.trackMesh;
		this.scene.add(this.ringTrackMesh, this.ringMesh);

		// Pollen & celebration sparks
		const glowTex = createRadialTexture("rgba(255,255,255,1)", "rgba(255,255,255,0.45)");
		this.disposables.push(glowTex);

		this.pollenPos = new Float32Array(MAX_AMBIENT_POLLEN * 3);
		this.pollenCol = new Float32Array(MAX_AMBIENT_POLLEN * 3);
		this.pollenGeom = new BufferGeometry();
		this.pollenGeom.setAttribute("position", new BufferAttribute(this.pollenPos, 3));
		this.pollenGeom.setAttribute("color", new BufferAttribute(this.pollenCol, 3));
		const pollenMat = new PointsMaterial({
			size: 0.14,
			map: glowTex,
			vertexColors: true,
			transparent: true,
			opacity: 0.85,
			blending: AdditiveBlending,
			depthWrite: false,
		});
		this.disposables.push(this.pollenGeom, pollenMat);
		this.pollenPoints = new Points(this.pollenGeom, pollenMat);
		this.scene.add(this.pollenPoints);

		this.sparkPos = new Float32Array(MAX_BURST_SPARKS * 3);
		this.sparkCol = new Float32Array(MAX_BURST_SPARKS * 3);
		this.sparkGeom = new BufferGeometry();
		this.sparkGeom.setAttribute("position", new BufferAttribute(this.sparkPos, 3));
		this.sparkGeom.setAttribute("color", new BufferAttribute(this.sparkCol, 3));
		const sparkMat = new PointsMaterial({
			size: 0.22,
			map: glowTex,
			vertexColors: true,
			transparent: true,
			opacity: 0.95,
			blending: AdditiveBlending,
			depthWrite: false,
		});
		this.disposables.push(this.sparkGeom, sparkMat);
		this.sparkPoints = new Points(this.sparkGeom, sparkMat);
		this.scene.add(this.sparkPoints);
		// After the spark buffers exist: it seeds both the ambient pollen and the burst sparks
		this.initAmbientPollen();

		// Instanced 3D mini-petals for partition pulse & full-bloom burst
		const miniGeom = createCalixPetalGeometry(0.16, 0.28);
		const miniMat = new MeshPhysicalMaterial({
			color: 0xffffff,
			roughness: 0.22,
			metalness: 0.05,
			clearcoat: 0.85,
			side: DoubleSide,
			transparent: true,
			opacity: 0.92,
		});
		this.disposables.push(miniGeom, miniMat);
		this.burstMesh = new InstancedMesh(miniGeom, miniMat, MAX_BURST_PETALS);
		this.burstMesh.instanceMatrix.setUsage(DynamicDrawUsage);
		this.burstMesh.frustumCulled = false;
		const cWhite = new Color(0xffffff);
		for (let i = 0; i < MAX_BURST_PETALS; i++) {
			this.burstMesh.setColorAt(i, cWhite);
			this.dummy.scale.setScalar(0);
			this.dummy.updateMatrix();
			this.burstMesh.setMatrixAt(i, this.dummy.matrix);
			this.burstPetals.push({
				active: false,
				x: 0,
				y: 0,
				z: 0,
				vx: 0,
				vy: 0,
				vz: 0,
				rx: 0,
				ry: 0,
				rz: 0,
				vrx: 0,
				vry: 0,
				vrz: 0,
				life: 0,
				max: 1,
				scale: 0,
				color: new Color(),
			});
		}
		this.scene.add(this.burstMesh);

		// Sync theme: the system's scheme is read first, so a page that's light by the system setting
		// starts with the light studio rather than the dark one
		this.colorSchemeQuery = window.matchMedia?.("(prefers-color-scheme: light)") ?? null;
		this.colorSchemeQuery?.addEventListener?.("change", this.onThemeMedia);
		this.syncTheme();
		this.themeObs = new MutationObserver(() => this.syncTheme());
		this.themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

		// Pointer parallax & drag interaction on canvas
		// The canvas lets clicks through (it overhangs the page around the stage): the stage takes them
		const dom = this.container;
		dom.addEventListener("pointermove", this.onPointerMove);
		dom.addEventListener("pointerdown", this.onPointerDown);
		window.addEventListener("pointerup", this.onPointerUp);
		dom.addEventListener("pointerleave", this.onPointerLeave);

		this.buildPlant();
		// The welcome page shows the full flower; otherwise the story starts from the seed
		this.growth = this.growthTarget = document.documentElement.classList.contains("welcome-open") ? 1 : 0;
		document.addEventListener(PLANT_EVENT, this.onPlant);

		this.resizeObs = new ResizeObserver(() => this.syncSize());
		this.resizeObs.observe(container);
		this.resizeObs.observe(dom);

		// Measure laid-out canvas dimensions and paint initial frame synchronously so SVG -> 3D swap has zero blank flash
		if (this.syncSize()) {
			this.updateScene(0);
			this.renderer.render(this.scene, this.camera);
		}

		document.addEventListener("visibilitychange", this.onVisibility);
		this.kick();
	}

	private buildReceptacle() {
		// Turned calyx cup behind the center of the blossom visible when orbited/angled
		const pts = [
			new Vector2(0.01, -0.34),
			new Vector2(0.16, -0.26),
			new Vector2(0.28, -0.14),
			new Vector2(0.32, 0.0),
			new Vector2(0.18, 0.04),
		];
		const geom = new LatheGeometry(pts, 28);
		geom.rotateX(Math.PI * 0.5);
		const mat = new MeshPhysicalMaterial({
			color: 0x38285c,
			emissive: 0x1e1638,
			emissiveIntensity: 0.25,
			roughness: 0.45,
			metalness: 0.1,
			clearcoat: 0.5,
		});
		this.disposables.push(geom, mat);
		const mesh = new Mesh(geom, mat);
		mesh.position.z = -0.12;
		mesh.castShadow = true;
		mesh.receiveShadow = true;
		this.flowerGroup.add(mesh);
	}

	private buildBackingPetals() {
		const backingColors = [
			new Color(PETALS[0].mid).lerp(new Color(PETALS[1].mid), 0.5),
			new Color(PETALS[1].mid).lerp(new Color(PETALS[2].mid), 0.5),
			new Color(PETALS[2].mid).lerp(new Color(PETALS[3].mid), 0.5),
			new Color(PETALS[3].mid).lerp(new Color(PETALS[0].mid), 0.5),
		];
		const geom = createCalixPetalGeometry(0.64, 1.38);
		this.disposables.push(geom);

		for (let i = 0; i < 4; i++) {
			// The second whorl behind the four: the same velvet, in the palette's in-between colours
			const mat = new MeshPhysicalMaterial({
				color: backingColors[i],
				emissive: backingColors[i],
				emissiveIntensity: 0.05,
				roughness: 0.6,
				metalness: 0,
				sheen: 0.9,
				sheenRoughness: 0.5,
				sheenColor: new Color(0xffffff),
				transparent: true,
				opacity: 0.94,
				side: DoubleSide,
				depthWrite: false,
			});
			this.disposables.push(mat);

			const pivot = new Group();
			pivot.rotation.z = Math.PI / 4 + i * (Math.PI / 2);
			pivot.position.z = -0.18;

			const mesh = new Mesh(geom, mat);
			const baseRotX = -0.52;
			mesh.rotation.x = baseRotX;
			mesh.position.y = 0.06;
			mesh.receiveShadow = true;
			pivot.add(mesh);
			this.flowerGroup.add(pivot);

			this.backingPetals.push({
				pivot,
				mesh,
				material: mat,
				baseRotX,
				phase: i * 1.15,
			});
		}
	}

	private buildHeroPetals() {
		PETALS.forEach((petal, i) => {
			const geom = createBrandPetalGeometry(petal);
			this.disposables.push(geom);

			const uniforms: PetalUniforms = {
				uFill: { value: 1 },
				uTime: { value: 0 },
				uRipple: { value: 0.72 },
				uShimmer: { value: 0 },
				uWilt: { value: 0 },
				uPhase: { value: i * 1.45 },
				uGhostColor: { value: new Color(0x2d2958) },
				uPetalLight: { value: new Color(petal.light) },
				uLight: { value: new Color(petal.light) },
				uMid: { value: new Color(petal.mid) },
				uDeep: { value: new Color(petal.deep) },
			};

			// Velvet, not glass: a soft sheen, a faint waxy coat and a little backlight through the petal
			const mat = new MeshPhysicalMaterial({
				vertexColors: true,
				roughness: 0.62,
				metalness: 0,
				clearcoat: 0.1,
				clearcoatRoughness: 0.6,
				sheen: 0.18,
				sheenRoughness: 0.7,
				sheenColor: uniforms.uLight.value,
				emissive: uniforms.uMid.value,
				emissiveIntensity: 0.04,
				transparent: true,
				envMapIntensity: 0.32,
			});
			mat.customProgramCacheKey = () => "eos-petal-v3";
			mat.onBeforeCompile = (shader) => {
				Object.assign(shader.uniforms, uniforms);
				shader.vertexShader = shader.vertexShader
					.replace(
						"#include <common>",
						`#include <common>
attribute float aFill;
attribute float aCross;
attribute float aRing;
varying float vFillPos;
varying float vCross;
varying float vRing;
uniform float uTime;
uniform float uRipple;
uniform float uPhase;`,
					)
					.replace(
						"#include <begin_vertex>",
						`#include <begin_vertex>
vFillPos = aFill;
vCross = aCross;
vRing = aRing;
float tipW = smoothstep(0.18, 1.0, aFill);
float w1 = sin(position.y * 4.2 - uTime * 2.1 + uPhase + position.x * 3.1) * 0.036;
float w2 = cos(position.x * 5.6 - uTime * 2.8 + uPhase) * 0.018;
transformed.z += (w1 + w2) * tipW * uRipple;`,
					);

				shader.fragmentShader = shader.fragmentShader
					.replace(
						"#include <common>",
						`#include <common>
varying float vFillPos;
varying float vCross;
varying float vRing;
uniform vec3 uLight;
uniform vec3 uMid;
uniform vec3 uDeep;
uniform float uFill;
uniform float uTime;
uniform float uShimmer;
uniform float uWilt;
uniform float uPhase;
uniform vec3 uGhostColor;
uniform vec3 uPetalLight;`,
					)
					.replace(
						"#include <color_fragment>",
						`#include <color_fragment>
// The palette's colour: deep in the throat, the body colour, paling toward the tip and the rim,
// with fine veins running out from the centre (diffuseColor holds the occlusion so far)
vec3 pal = mix(uDeep, uMid, smoothstep(0.04, 0.42, vFillPos));
pal = mix(pal, uLight, smoothstep(0.7, 1.0, vFillPos) * 0.22);
float vein = pow(abs(cos(vCross / max(vFillPos * 1.45 + 0.12, 0.12) * 26.0)), 10.0) * smoothstep(0.12, 0.8, vFillPos);
pal *= 1.0 - vein * 0.1;
pal = mix(pal, uLight, smoothstep(0.92, 1.0, vRing) * 0.18);
// Petal pigment: deeper and more saturated than the flat swatch, so light tones don't wash out
pal = pow(pal, vec3(1.45));
diffuseColor.rgb *= pal;
float fillMask = 1.0 - smoothstep(uFill - 0.08, uFill + 0.02, vFillPos);
vec3 baseCol = mix(uGhostColor, diffuseColor.rgb, fillMask);
float lum = dot(baseCol, vec3(0.299, 0.587, 0.114));
baseCol = mix(baseCol, vec3(lum * 0.68), uWilt * 0.85);
diffuseColor.rgb = baseCol;
diffuseColor.a *= mix(0.28, 1.0, fillMask) * mix(1.0, 0.78, uWilt);`,
					)
					.replace(
						"#include <emissivemap_fragment>",
						`#include <emissivemap_fragment>
float centerAO = smoothstep(0.0, 0.42, vFillPos);
float edgeDist = abs(vFillPos - uFill);
float fillWave = (uFill > 0.01 && uFill < 0.99) ? exp(-edgeDist * edgeDist * 170.0) : 0.0;
float sweep = pow(max(0.0, sin(vFillPos * 5.2 - uTime * 3.6 + uPhase)), 6.0) * uShimmer;
vec3 viewDirF = normalize(vViewPosition);
float fresnelF = pow(1.0 - abs(dot(normal, viewDirF)), 2.4);
totalEmissiveRadiance *= fillMask * mix(0.3, 1.0, centerAO) * (1.0 - uWilt * 0.85);
totalEmissiveRadiance += uPetalLight * (fillWave * 1.35 + sweep * 0.9 + fresnelF * mix(0.06, 0.16, fillMask) * centerAO * (1.0 - uWilt * 0.72));`,
					);
			};

			this.disposables.push(mat);

			const layer = PETAL_LAYERS[petal.name];
			const pivot = new Group();
			pivot.position.z = layer.z;
			const mesh = new Mesh(geom, mat);
			mesh.castShadow = true;
			mesh.receiveShadow = true;
			pivot.add(mesh);
			this.flowerGroup.add(pivot);

			const [dx, dy] = PETAL_DIRS[petal.name];
			// Perpendicular axis in XY plane to tilt petal toward/away from center
			const perpAxis = new Vector3(-dy, dx, 0).normalize();

			this.heroPetals.push({
				petal,
				pivot,
				mesh,
				material: mat,
				uniforms,
				perpAxis,
				baseZ: layer.z,
				basePitch: layer.pitch,
				fill: 1,
				targetFill: 1,
				wasFull: true,
				popTimer: 0,
				pulseFlash: 0,
			});
		});
	}

	private buildCore() {
		const coreGroup = new Group();
		coreGroup.position.set(0, 0, 0.16);

		// Soft dark occlusion halo at the heart between petals and stamen crown
		const aoTex = createRadialTexture("rgba(12,8,30,0.72)", "rgba(18,12,44,0.34)", "rgba(18,12,44,0.06)");
		const aoGeom = new PlaneGeometry(0.95, 0.95);
		const centerShadowMat = new MeshBasicMaterial({
			map: aoTex,
			transparent: true,
			depthWrite: false,
		});
		this.disposables.push(aoTex, aoGeom, centerShadowMat);
		const aoMesh = new Mesh(aoGeom, centerShadowMat);
		aoMesh.position.z = -0.08;
		coreGroup.add(aoMesh);

		// The stigma: a small, matte, yellow-green crown in the middle of the stamens
		const sphereGeom = new SphereGeometry(0.075, 24, 18);
		const sphereMat = new MeshPhysicalMaterial({
			color: 0xc8d46a,
			emissive: 0x6d7a1e,
			emissiveIntensity: 0.18,
			roughness: 0.7,
			sheen: 0.8,
			sheenColor: new Color(0xf3f7c4),
		});
		this.disposables.push(sphereGeom, sphereMat);
		const hubMesh = new Mesh(sphereGeom, sphereMat);
		hubMesh.scale.set(1, 1, 0.7);
		hubMesh.position.z = 0.06;
		hubMesh.castShadow = true;
		hubMesh.receiveShadow = true;
		coreGroup.add(hubMesh);

		// Soft volumetric additive corona sprite
		const coronaTex = createRadialTexture("rgba(255,255,255,0.95)", "rgba(210,175,255,0.42)");
		const coronaMat = new SpriteMaterial({
			map: coronaTex,
			color: 0xd8b4fe,
			transparent: true,
			opacity: 0.25,
			blending: AdditiveBlending,
			depthWrite: false,
		});
		this.disposables.push(coronaTex, coronaMat);
		const coronaSprite = new Sprite(coronaMat);
		coronaSprite.scale.set(0.96, 0.96, 1);
		coreGroup.add(coronaSprite);

		// Stamens: tapered filaments curving out from the centre, each tipped with a pollen-gold
		// anther (two instanced meshes, two draw calls)
		const stamenCount = 54;
		const filamentGeom = new CylinderGeometry(0.0045, 0.0075, 1, 6, 1);
		filamentGeom.translate(0, 0.5, 0);
		const filamentMat = new MeshPhysicalMaterial({ color: 0xf2ead2, roughness: 0.55, sheen: 0.6, sheenColor: new Color(0xffffff) });
		const antherGeom = new SphereGeometry(0.019, 10, 8);
		const antherMat = new MeshPhysicalMaterial({
			color: 0xf0bd45,
			emissive: 0x8a5a0c,
			emissiveIntensity: 0.2,
			roughness: 0.75,
			sheen: 1,
			sheenColor: new Color(0xffe7a3),
		});
		this.disposables.push(filamentGeom, filamentMat, antherGeom, antherMat);
		const filaments = new InstancedMesh(filamentGeom, filamentMat, stamenCount);
		const anthers = new InstancedMesh(antherGeom, antherMat, stamenCount);
		const dummy = new Object3D();
		const up = new Vector3(0, 1, 0);
		const dir = new Vector3();

		for (let i = 0; i < stamenCount; i++) {
			const theta = i * GOLDEN_ANGLE;
			const f = (i + 1) / stamenCount;
			const r = 0.07 + 0.17 * Math.sqrt(f);
			const base = new Vector3(Math.cos(theta) * 0.05, Math.sin(theta) * 0.05, 0.02);
			const tip = new Vector3(Math.cos(theta) * r, Math.sin(theta) * r, 0.1 + (1 - f) * 0.13 + Math.sin(i * 2.3) * 0.015);
			dir.subVectors(tip, base);
			const len = dir.length();
			dummy.position.copy(base);
			dummy.quaternion.setFromUnitVectors(up, dir.normalize());
			dummy.scale.set(1, len, 1);
			dummy.updateMatrix();
			filaments.setMatrixAt(i, dummy.matrix);

			dummy.position.copy(tip);
			dummy.scale.set(1, 1.6, 1);
			dummy.updateMatrix();
			anthers.setMatrixAt(i, dummy.matrix);
		}
		filaments.instanceMatrix.needsUpdate = true;
		anthers.instanceMatrix.needsUpdate = true;
		coreGroup.add(filaments, anthers);

		const coreLight = new PointLight(0xc084fc, 2.3, 5.5);
		coreLight.position.set(0, 0, 0.42);
		coreGroup.add(coreLight);

		return { coreGroup, coreLight, coronaSprite, coronaMat, centerShadowMat };
	}

	private buildProgressRing() {
		const radius = 1.88;
		const trackGeom = new TorusGeometry(radius, 0.015, 10, 112);
		const trackMat = new MeshBasicMaterial({
			color: 0xffffff,
			transparent: true,
			opacity: 0,
			depthWrite: false,
		});
		const trackMesh = new Mesh(trackGeom, trackMat);

		const arcGeom = new TorusGeometry(radius, 0.03, 12, 128);
		const uniforms = {
			uProgress: { value: 0 },
			uOpacity: { value: 0 },
			uPulse: { value: 1 },
			uTime: { value: 0 },
			uC0: { value: new Color(PETALS[0].mid) },
			uC1: { value: new Color(PETALS[1].mid) },
			uC2: { value: new Color(PETALS[2].mid) },
			uC3: { value: new Color(PETALS[3].mid) },
		};

		const arcMat = new ShaderMaterial({
			uniforms,
			transparent: true,
			depthWrite: false,
			blending: AdditiveBlending,
			vertexShader: `
				varying vec3 vPos;
				void main() {
					vPos = position;
					gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
				}
			`,
			fragmentShader: `
				uniform float uProgress;
				uniform float uOpacity;
				uniform float uPulse;
				uniform float uTime;
				uniform vec3 uC0;
				uniform vec3 uC1;
				uniform vec3 uC2;
				uniform vec3 uC3;
				varying vec3 vPos;
				void main() {
					// Clockwise from 12 o'clock (0, +R)
					float angle = atan(vPos.x, vPos.y);
					float norm = mod(angle / 6.28318530718 + 1.0, 1.0);
					float fill = 1.0 - smoothstep(uProgress - 0.012, uProgress + 0.004, norm);
					if (uProgress <= 0.001) fill = 0.0;
					if (uProgress >= 0.999) fill = 1.0;

					vec3 col = uC0;
					if (norm < 0.25) col = mix(uC0, uC1, smoothstep(0.18, 0.25, norm));
					else if (norm < 0.5) col = mix(uC1, uC2, smoothstep(0.43, 0.5, norm));
					else if (norm < 0.75) col = mix(uC2, uC3, smoothstep(0.68, 0.75, norm));
					else col = mix(uC3, uC0, smoothstep(0.93, 1.0, norm));

					// Glowing leading tip while installing
					float headDist = abs(norm - uProgress);
					float head = (uProgress > 0.01 && uProgress < 0.99) ? exp(-headDist * headDist * 2400.0) : 0.0;
					vec3 finalCol = col * (1.15 + 0.2 * sin(uTime * 3.0 + norm * 12.0)) + vec3(1.0) * head * 1.4;
					float alpha = (fill * 0.92 + head * 0.9) * uOpacity * uPulse;
					if (alpha < 0.01) discard;
					gl_FragColor = vec4(finalCol, alpha);
				}
			`,
		});

		const arcMesh = new Mesh(arcGeom, arcMat);
		this.disposables.push(trackGeom, trackMat, arcGeom, arcMat);
		return { uniforms, trackMat, trackMesh, arcMesh };
	}

	/** The growth story's set: soil, the seed, a stem revealed as it grows, its leaves. */
	private buildPlant() {
		const g = new Group();
		this.plantGroup = g;
		this.scene.add(g);

		// A glazed pot, its rim just under the soil's top: a lathed profile with a rolled lip
		const potGeom = new LatheGeometry(
			[
				[0, -0.8],
				[0.46, -0.8],
				[0.5, -0.76],
				[0.66, -0.16],
				[0.73, -0.15],
				[0.76, -0.12],
				[0.77, -0.01],
				[0.74, 0.02],
				[0.68, 0.0],
				[0.66, -0.1],
			].map(([x, y]) => new Vector2(x, y)),
			72,
		);
		this.potMat = new MeshPhysicalMaterial({
			color: this.isLight ? POT_LIGHT : POT_DARK,
			roughness: 0.38,
			clearcoat: 0.7,
			clearcoatRoughness: 0.25,
			sheen: 0.3,
			sheenColor: new Color(0xae69fc),
			side: DoubleSide,
			transparent: true,
		});
		const pot = new Mesh(potGeom, this.potMat);
		pot.position.set(0, SOIL_Y - 0.02, 0);
		g.add(pot);

		// A soft mound of dark earth filling the pot, with a few pebbles
		const soilGeom = new SphereGeometry(1, 48, 24);
		this.soilMat = new MeshPhysicalMaterial({ color: this.isLight ? SOIL_LIGHT : SOIL_DARK, roughness: 0.96, metalness: 0, sheen: 0.25, sheenColor: new Color(0x6b4a3e), transparent: true });
		const soil = new Mesh(soilGeom, this.soilMat);
		soil.scale.set(0.69, 0.11, 0.69);
		soil.position.set(0, SOIL_Y - 0.04, 0);
		g.add(soil);
		const pebbleGeom = new SphereGeometry(0.06, 16, 10);
		const pebbleMat = new MeshPhysicalMaterial({ color: this.isLight ? PEBBLE_LIGHT : PEBBLE_DARK, roughness: 0.7, clearcoat: 0.3, transparent: true });
		this.pebbleMat = pebbleMat;
		[
			[-0.62, 0.02, 0.22, 1.2],
			[0.48, 0.0, 0.3, 0.9],
			[0.75, -0.04, -0.1, 1.4],
			[-0.3, 0.04, 0.42, 0.7],
			[0.22, 0.03, 0.48, 0.8],
		].forEach(([x, y, z, sc]) => {
			const p = new Mesh(pebbleGeom, pebbleMat);
			// Pulled in to sit on the earth inside the pot's rim
			p.position.set(x * 0.78, SOIL_Y + y - 0.02, z * 0.78);
			p.scale.set(sc * 1.3, sc * 0.7, sc);
			g.add(p);
		});
		this.disposables.push(potGeom, this.potMat, soilGeom, this.soilMat, pebbleGeom, pebbleMat);

		// The seed: warm, glossy, with a violet sheen of the bloom to come
		const seedGeom = new SphereGeometry(0.14, 32, 20);
		const seedMat = new MeshPhysicalMaterial({
			color: 0x9a6a3e,
			roughness: 0.35,
			clearcoat: 0.8,
			sheen: 1,
			sheenColor: new Color(PETALS[0].light),
			emissive: new Color(PETALS[0].deep),
			emissiveIntensity: 0.12,
		});
		this.seed = new Mesh(seedGeom, seedMat);
		this.seed.scale.set(1, 1.35, 1);
		this.seed.position.set(0, SOIL_Y + 0.07, 0.04);
		g.add(this.seed);
		this.disposables.push(seedGeom, seedMat);

		// The stem, drawn up to how far it has grown (drawRange over its tube's segments)
		this.stemCurve = new CatmullRomCurve3([
			new Vector3(0, SOIL_Y + 0.02, 0.02),
			new Vector3(0.07, SOIL_Y + 0.42, -0.02),
			new Vector3(-0.06, -0.86, -0.06),
			new Vector3(0.04, -0.46, -0.1),
			new Vector3(0, -0.12, -0.16),
		]);
		this.stemGeom = new TubeGeometry(this.stemCurve, STEM_SEGS, 0.042, STEM_RADIAL, false);
		const green = PETALS[2];
		const stemMat = new MeshPhysicalMaterial({ color: new Color(green.mid).lerp(new Color(green.deep), 0.45), roughness: 0.42, clearcoat: 0.55, sheen: 0.5, sheenColor: new Color(green.light), emissive: new Color(green.deep), emissiveIntensity: 0.1 });
		this.stemMesh = new Mesh(this.stemGeom, stemMat);
		g.add(this.stemMesh);
		const tipGeom = new SphereGeometry(0.048, 20, 12);
		const tipMat = new MeshPhysicalMaterial({ color: new Color(green.light), roughness: 0.3, clearcoat: 0.7, emissive: new Color(green.mid), emissiveIntensity: 0.35 });
		this.stemTip = new Mesh(tipGeom, tipMat);
		g.add(this.stemTip);
		this.disposables.push(this.stemGeom, stemMat, tipGeom, tipMat);

		// Two round seed leaves low on the stem, then two long true leaves higher up
		const leafMat = new MeshPhysicalMaterial({ color: new Color(green.mid), roughness: 0.4, clearcoat: 0.6, sheen: 0.6, sheenColor: new Color(green.light), emissive: new Color(green.deep), emissiveIntensity: 0.12, side: DoubleSide });
		const seedLeafGeom = createCalixPetalGeometry(0.34, 0.36);
		const trueLeafGeom = createCalixPetalGeometry(0.38, 0.72);
		this.disposables.push(leafMat, seedLeafGeom, trueLeafGeom);
		const defs: Array<[geom: BufferGeometry, at: number, from: number, to: number, side: number, size: number]> = [
			[seedLeafGeom, 0.1, 0.07, 0.22, -1, 1],
			[seedLeafGeom, 0.1, 0.09, 0.24, 1, 1],
			[trueLeafGeom, 0.3, 0.32, 0.56, 1, 1],
			[trueLeafGeom, 0.42, 0.42, 0.66, -1, 0.9],
		];
		for (const [geom, at, from, to, side, size] of defs) {
			const pivot = new Group();
			const leaf = new Mesh(geom, leafMat);
			pivot.add(leaf);
			// Set back behind the stem, so the open flower covers them as on a real plant seen from the front
			pivot.position.copy(this.stemCurve.getPointAt(at)).add(new Vector3(0, 0, -0.34));
			pivot.scale.setScalar(0);
			g.add(pivot);
			this.leaves.push({ pivot, at, from, to, side, size });
		}
	}

	/** A puff of particles from a point: earth when the seed lands, green when it sprouts. */
	private spawnPuff(x: number, y: number, z: number, count: number, colors: string[], power: number) {
		const c = new Color();
		let spawned = 0;
		for (let i = 0; i < this.sparkParticles.length && spawned < count; i++) {
			const sp = this.sparkParticles[i];
			if (sp.life < sp.max) continue;
			const a = Math.PI * (0.1 + Math.random() * 0.8);
			const speed = (0.6 + Math.random() * 1.4) * power;
			sp.x = x + (Math.random() - 0.5) * 0.1;
			sp.y = y;
			sp.z = z + (Math.random() - 0.5) * 0.1;
			sp.vx = Math.cos(a) * speed;
			sp.vy = Math.sin(a) * speed;
			sp.vz = (Math.random() - 0.5) * speed;
			sp.life = 0;
			sp.max = 0.6 + Math.random() * 0.7;
			c.set(colors[spawned % colors.length]);
			this.sparkCol[i * 3] = c.r;
			this.sparkCol[i * 3 + 1] = c.g;
			this.sparkCol[i * 3 + 2] = c.b;
			spawned++;
		}
		this.sparkGeom.attributes.color.needsUpdate = true;
	}

	/**
	 * Steps the growth and poses the plant. Returns how far the camera has followed it up
	 * (0 at the seed, 1 at the flower), the flower head's scale, how open it is, and where it
	 * sits relative to its full-grown place.
	 */
	private updatePlant(dt: number, t: number): { follow: number; headScale: number; open: number; headY: number } {
		const rate = this.planting ? 1.5 : this.mode === "complete" ? 0.6 : 0.22;
		const d = this.growthTarget - this.growth;
		this.growth += Math.sign(d) * Math.min(Math.abs(d), rate * dt);
		const g = this.growth;

		// Planting: once the flower has folded away, the seed falls into the soil
		if (this.planting && this.seedDropPending && g <= 0.001) {
			this.seedDropPending = false;
			this.seedDrop = 1;
		}
		if (this.seedDrop > 0) {
			this.seedDrop = Math.max(0, this.seedDrop - dt / 0.8);
			if (this.seedDrop === 0) {
				this.spawnPuff(0, SOIL_Y + 0.02, 0.05, 26, ["#6b5a4c", "#8a7360", "#4a3d58", "#c9a98a"], 0.9);
				this.planting = false;
				this.growthTarget = Math.max(this.growthTarget, this.pendingStage);
			}
		}
		if (!this.sprouted && g > 0.045 && !this.planting) {
			this.sprouted = true;
			this.spawnPuff(0, SOIL_Y + 0.12, 0.05, 18, [PETALS[2].light, PETALS[2].mid, "#ffffff"], 0.7);
		}
		if (this.pendingCelebrate && g >= 0.97) {
			this.pendingCelebrate = false;
			this.burstOpen();
		}

		// The seed: resting (breathing), cracking open as the sprout starts, then gone into the soil
		const seedVisible = !(this.planting && this.seedDropPending);
		const seedSize = seedVisible ? 1 - smooth(0.1, 0.3, g) : 0;
		const breathe = 1 + Math.sin(t * 2.2) * 0.04 * (1 - smooth(0, 0.05, g));
		this.seed.visible = seedSize > 0.01;
		this.seed.scale.set(seedSize * breathe, seedSize * 1.35 * breathe, seedSize * breathe);
		const drop = this.seedDrop * this.seedDrop;
		this.seed.position.y = SOIL_Y + 0.07 + drop * 2.4;
		this.seed.rotation.z = g > 0.02 && g < 0.3 ? Math.sin(t * 14) * 0.06 : drop * 3;

		// The stem, revealed up to its growing tip
		const sg = MathUtils.clamp(g / 0.9, 0, 1);
		const segs = Math.floor(sg * STEM_SEGS);
		this.stemGeom.setDrawRange(0, segs * STEM_RADIAL * 6);
		this.stemMesh.visible = segs > 0;
		const tip = this.stemCurve.getPointAt(Math.max(0.001, sg));
		this.stemTip.position.copy(tip);
		this.stemTip.visible = sg > 0.01 && g < 0.66;

		// Leaves unfurl as the stem passes them, and droop on an error
		for (const leaf of this.leaves) {
			const a = sg >= leaf.at ? easeOutCubic(smooth(leaf.from, leaf.to, g)) : 0;
			leaf.pivot.visible = a > 0.01;
			leaf.pivot.scale.setScalar(a * leaf.size);
			leaf.pivot.rotation.set(
				MathUtils.lerp(1.35, 0.32, a) + this.wiltBlend * 0.7 + Math.sin(t * 1.3 + leaf.at * 9) * 0.05,
				leaf.side * 0.35,
				leaf.side * (0.95 + Math.sin(t * 0.9 + leaf.at * 5) * 0.06),
			);
		}

		this.soilMat.opacity = 1 - smooth(0.93, 1, g);
		if (this.potMat) this.potMat.opacity = this.soilMat.opacity;
		this.plantGroup.visible = this.soilMat.opacity > 0.01 || segs > 0;
		this.plantGroup.rotation.z = this.wiltBlend * 0.14;

		// A bud forms and swells to about half size during the install, and opens to full size when done
		const open = smooth(0.89, 1, g);
		const bud = g < 0.62 ? 0 : 0.1 + 0.36 * easeOutCubic(smooth(0.62, 0.88, g));
		const headScale = bud <= 0 ? 0 : bud + (1 - bud) * easeOutCubic(open);
		const end = this.stemCurve.getPointAt(1);
		return { follow: smooth(0.08, 0.95, g), headScale, open, headY: tip.y - end.y };
	}

	private initAmbientPollen() {
		const c = new Color();
		for (let i = 0; i < MAX_AMBIENT_POLLEN; i++) {
			const p = this.palette.petals[i % 4];
			c.set(i % 2 === 0 ? p.light : p.mid);
			const orbitR = 1.35 + Math.random() * 1.45;
			const orbitAngle = Math.random() * Math.PI * 2;
			const particle: PollenParticle = {
				x: Math.cos(orbitAngle) * orbitR,
				y: Math.sin(orbitAngle) * orbitR,
				z: (Math.random() - 0.5) * 1.1,
				vx: 0,
				vy: 0,
				vz: 0,
				life: Math.random() * 5,
				max: 4 + Math.random() * 4,
				petalIdx: i % 4,
				kind: "ambient",
				orbitR,
				orbitAngle,
				orbitSpeed: (0.16 + Math.random() * 0.24) * (i % 2 === 0 ? 1 : -1),
			};
			this.pollenParticles.push(particle);
			this.pollenPos[i * 3] = particle.x;
			this.pollenPos[i * 3 + 1] = particle.y;
			this.pollenPos[i * 3 + 2] = particle.z;
			this.pollenCol[i * 3] = c.r;
			this.pollenCol[i * 3 + 1] = c.g;
			this.pollenCol[i * 3 + 2] = c.b;
		}
		this.pollenGeom.attributes.position.needsUpdate = true;
		this.pollenGeom.attributes.color.needsUpdate = true;

		for (let i = 0; i < MAX_BURST_SPARKS; i++) {
			this.sparkParticles.push({
				x: 0,
				y: 0,
				z: -20,
				vx: 0,
				vy: 0,
				vz: 0,
				life: 99,
				max: 1,
				petalIdx: i % 4,
				kind: "spark",
				orbitR: 0,
				orbitAngle: 0,
				orbitSpeed: 0,
			});
			this.sparkPos[i * 3 + 2] = SPARK_PARKED_Z;
		}
		this.sparkGeom.attributes.position.needsUpdate = true;
	}

	private onThemeMedia = () => this.syncTheme();

	private syncTheme() {
		const explicit = document.documentElement.dataset.theme;
		const prefersLight = this.colorSchemeQuery?.matches ?? false;
		this.isLight = explicit ? explicit === "light" : prefersLight;

		if (this.isLight) {
			if (!this.envTargetLight) this.envTargetLight = createStudioEnvTexture(this.renderer, true);
			this.scene.environment = this.envTargetLight.texture;
			this.ambientLight.intensity = 0.72;
			this.keyLight.intensity = 2.05;
			this.ringTrackMat.color.setHex(0x141329);
			this.centerShadowMat.opacity = 0.48;
		} else {
			if (!this.envTargetDark) this.envTargetDark = createStudioEnvTexture(this.renderer, false);
			this.scene.environment = this.envTargetDark.texture;
			this.ambientLight.intensity = 0.45;
			this.keyLight.intensity = 2.35;
			this.ringTrackMat.color.setHex(0xffffff);
			this.centerShadowMat.opacity = 0.88;
		}

		this.soilMat?.color.setHex(this.isLight ? SOIL_LIGHT : SOIL_DARK);
		this.pebbleMat?.color.setHex(this.isLight ? PEBBLE_LIGHT : PEBBLE_DARK);
		this.potMat?.color.setHex(this.isLight ? POT_LIGHT : POT_DARK);

		const ghostHex = this.isLight ? 0xd9cef7 : 0x2a2754;
		for (const item of this.heroPetals) {
			item.uniforms.uGhostColor.value.setHex(ghostHex);
		}
	}

	private onPointerMove = (ev: PointerEvent) => {
		const rect = this.container.getBoundingClientRect();
		if (rect.width <= 0 || rect.height <= 0) return;
		const nx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
		const ny = ((ev.clientY - rect.top) / rect.height) * 2 - 1;
		this.pointerTarget.set(MathUtils.clamp(nx, -1, 1), MathUtils.clamp(ny, -1, 1));

		if (this.dragging) {
			const dx = ev.clientX - this.lastDrag.x;
			const dy = ev.clientY - this.lastDrag.y;
			this.lastDrag.set(ev.clientX, ev.clientY);
			this.dragOffset.x = MathUtils.clamp(this.dragOffset.x + dx * 0.009, -0.85, 0.85);
			this.dragOffset.y = MathUtils.clamp(this.dragOffset.y + dy * 0.009, -0.55, 0.55);
		}
	};

	private onPointerDown = (ev: PointerEvent) => {
		this.dragging = true;
		this.lastDrag.set(ev.clientX, ev.clientY);
	};

	private onPointerUp = () => {
		this.dragging = false;
	};

	private onPointerLeave = () => {
		this.pointerTarget.set(0, 0);
	};

	private onVisibility = () => {
		if (document.visibilityState === "visible") {
			this.lastFrameTime = performance.now();
			this.kick();
		} else if (this.raf) {
			cancelAnimationFrame(this.raf);
			this.raf = 0;
		}
	};

	/** Measure the CSS box the canvas actually fills and align drawing buffer + DPR + aspect ratio. */
	private syncSize(): boolean {
		const canvas = this.renderer.domElement;
		const rect = canvas.getBoundingClientRect();
		const cw = rect.width > 0 ? rect.width : this.container.getBoundingClientRect().width;
		const ch = rect.height > 0 ? rect.height : this.container.getBoundingClientRect().height;
		const w = Math.round(cw);
		const h = Math.round(ch);
		if (w <= 0 || h <= 0) return false;

		const dpr = Math.min(window.devicePixelRatio || 1, 1.75);
		const targetW = Math.floor(w * dpr);
		const targetH = Math.floor(h * dpr);
		if (canvas.width !== targetW || canvas.height !== targetH || this.lastW !== w || this.lastH !== h || this.lastDpr !== dpr) {
			this.lastW = w;
			this.lastH = h;
			this.lastDpr = dpr;
			this.renderer.setPixelRatio(dpr);
			this.renderer.setSize(w, h, false);
			this.camera.aspect = w / h;
			this.camera.updateProjectionMatrix();
		}
		return true;
	}

	resize() {
		this.syncSize();
	}

	setMode(mode: BloomSceneMode) {
		const changed = mode !== this.mode;
		this.mode = mode;
		if (mode === "download") this.downloadRate = 18;
		else if (mode === "idle") this.downloadRate = 3;
		else this.downloadRate = 0;
		if (mode !== "complete") {
			this.celebrateTimer = 0;
			this.pendingCelebrate = false;
		}
		// A step that just began has made no progress yet (the last one's would grow the plant ahead)
		const fresh = changed && (mode === "download" || mode === "install");
		this.setProgress(mode === "complete" ? 1 : fresh ? 0 : this.progress);
	}

	setProgress(p: number) {
		this.progress = MathUtils.clamp(p, 0, 1);
		const filling = this.mode === "download" || this.mode === "idle";
		this.heroPetals.forEach((item, i) => {
			item.targetFill = filling ? MathUtils.clamp(this.progress * 4 - i, 0, 1) : 1;
		});
		this.updateGrowthTarget();
	}

	/** Where the install's step puts the plant; it only grows, until a new install replants it. */
	private updateGrowthTarget() {
		let stage: number | null = null;
		if (this.mode === "download") stage = 0.05 + 0.33 * this.progress;
		else if (this.mode === "verify") stage = 0.42;
		else if (this.mode === "install") stage = 0.46 + 0.42 * this.progress;
		else if (this.mode === "complete") stage = 1;
		if (stage === null) return;
		// Another install after a full bloom starts again from a seed
		if (stage < 1 && this.growthTarget >= 1 && !this.planting) this.plant();
		this.pendingStage = Math.max(this.pendingStage, stage);
		if (!this.planting) this.growthTarget = Math.max(this.growthTarget, stage);
	}

	private onPlant = () => this.plant();

	/** Fold the flower back and drop a seed into the soil. */
	plant() {
		this.planting = true;
		this.seedDropPending = true;
		this.sprouted = false;
		this.growthTarget = 0;
		this.pendingStage = 0;
		this.kick();
	}

	/** Ease the flower, its pollen and the ring into a phone's colours. */
	setPalette(palette: Palette) {
		if (palette === this.palette) return;
		this.palette = palette;
		palette.petals.forEach((t, i) => {
			this.paletteTarget[i].light.set(t.light);
			this.paletteTarget[i].mid.set(t.mid);
			this.paletteTarget[i].deep.set(t.deep);
		});
		const c = new Color();
		this.pollenParticles.forEach((_, i) => {
			const t = palette.petals[i % 4];
			c.set(i % 2 === 0 ? t.light : t.mid);
			this.pollenCol[i * 3] = c.r;
			this.pollenCol[i * 3 + 1] = c.g;
			this.pollenCol[i * 3 + 2] = c.b;
		});
		this.pollenGeom.attributes.color.needsUpdate = true;
		this.kick();
	}

	/** One frame of easing toward the palette's colours. */
	private easePalette(dt: number) {
		const k = Math.min(1, dt * 2.4);
		const tg = this.paletteTarget;
		this.heroPetals.forEach((item, i) => {
			const u = item.uniforms;
			u.uLight.value.lerp(tg[i].light, k);
			u.uMid.value.lerp(tg[i].mid, k);
			u.uDeep.value.lerp(tg[i].deep, k);
			u.uPetalLight.value.copy(u.uLight.value);
		});
		this.backingPetals.forEach((bp, i) => {
			this.tmpColor.copy(tg[i].mid).lerp(tg[(i + 1) % 4].mid, 0.5);
			bp.material.color.lerp(this.tmpColor, k);
			bp.material.emissive.copy(bp.material.color);
		});
		this.ringUniforms.uC0.value.lerp(tg[0].mid, k);
		this.ringUniforms.uC1.value.lerp(tg[1].mid, k);
		this.ringUniforms.uC2.value.lerp(tg[2].mid, k);
		this.ringUniforms.uC3.value.lerp(tg[3].mid, k);
		this.tmpColor.copy(tg[0].light).lerp(tg[1].light, 0.5);
		this.coreTint.lerp(this.tmpColor, k);
	}

	setSpeed(bytesPerSecond: number) {
		if (this.mode !== "download") return;
		const mb = bytesPerSecond / (1024 * 1024);
		this.downloadRate = MathUtils.clamp(8 + mb * 2.2, 8, 60);
	}

	pulse(petal?: number) {
		const idx = petal !== undefined ? ((petal % 4) + 4) % 4 : Math.floor(Math.random() * 4);
		const item = this.heroPetals[idx];
		if (item) {
			item.popTimer = 1;
			item.pulseFlash = 1;
		}
		this.spawnMiniPetals(16, idx, 1.0);
		this.spawnSparks(14, idx, 0.9);
	}

	celebrate() {
		this.setMode("complete");
		// The burst comes once the bud has opened (updatePlant)
		this.pendingCelebrate = true;
		this.kick();
	}

	private burstOpen() {
		this.celebrateWaves = [0.55, 1.15];
		this.celebrateClock = 0;
		this.celebrateTimer = 1.8;
		for (const item of this.heroPetals) {
			item.popTimer = 1.15;
			item.pulseFlash = 1.1;
		}
		this.spawnMiniPetals(MAX_BURST_PETALS, undefined, 1.55);
		this.spawnSparks(MAX_BURST_SPARKS, undefined, 1.65);
	}

	private spawnMiniPetals(count: number, fixedPetal: number | undefined, power: number) {
		let spawned = 0;
		for (let i = 0; i < this.burstPetals.length && spawned < count; i++) {
			const bp = this.burstPetals[i];
			if (bp.active && fixedPetal !== undefined) continue;
			const pIdx = fixedPetal ?? spawned % 4;
			const p = PETALS[pIdx];
			const [dx, dy] = PETAL_DIRS[p.name];
			const baseAngle = Math.atan2(dy, dx);
			const angle = fixedPetal !== undefined ? baseAngle + (Math.random() - 0.5) * 1.4 : Math.random() * Math.PI * 2;
			const speed = (1.3 + Math.random() * 2.1) * power;

			bp.active = true;
			bp.x = dx * 0.45;
			bp.y = dy * 0.45;
			bp.z = 0.22 + Math.random() * 0.15;
			bp.vx = Math.cos(angle) * speed;
			bp.vy = Math.sin(angle) * speed + 0.55 * power;
			bp.vz = (Math.random() - 0.3) * 1.8 * power;
			bp.rx = Math.random() * Math.PI * 2;
			bp.ry = Math.random() * Math.PI * 2;
			bp.rz = Math.random() * Math.PI * 2;
			bp.vrx = (Math.random() - 0.5) * 6;
			bp.vry = (Math.random() - 0.5) * 6;
			bp.vrz = (Math.random() - 0.5) * 6;
			bp.life = 0;
			bp.max = 1.2 + Math.random() * 1.1;
			bp.scale = 0.55 + Math.random() * 0.65;
			const tone = this.palette.petals[pIdx];
			bp.color.set([tone.light, tone.mid, tone.deep][spawned % 3]);
			this.burstMesh.setColorAt(i, bp.color);
			spawned++;
		}
		if (this.burstMesh.instanceColor) this.burstMesh.instanceColor.needsUpdate = true;
	}

	private spawnSparks(count: number, fixedPetal: number | undefined, power: number) {
		const c = new Color();
		let spawned = 0;
		for (let i = 0; i < this.sparkParticles.length && spawned < count; i++) {
			const sp = this.sparkParticles[i];
			if (sp.life < sp.max && fixedPetal !== undefined) continue;
			const pIdx = fixedPetal ?? spawned % 4;
			const p = PETALS[pIdx];
			const [dx, dy] = PETAL_DIRS[p.name];
			const a = fixedPetal !== undefined ? Math.atan2(dy, dx) + (Math.random() - 0.5) * 1.5 : Math.random() * Math.PI * 2;
			const speed = (1.5 + Math.random() * 2.5) * power;
			sp.x = dx * 0.35;
			sp.y = dy * 0.35;
			sp.z = 0.24;
			sp.vx = Math.cos(a) * speed;
			sp.vy = Math.sin(a) * speed + 0.4 * power;
			sp.vz = (Math.random() - 0.4) * 2.0 * power;
			sp.life = 0;
			sp.max = 1.0 + Math.random() * 1.2;
			c.set(spawned % 4 === 0 ? "#ffffff" : this.palette.petals[pIdx].light);
			this.sparkCol[i * 3] = c.r;
			this.sparkCol[i * 3 + 1] = c.g;
			this.sparkCol[i * 3 + 2] = c.b;
			spawned++;
		}
		this.sparkGeom.attributes.color.needsUpdate = true;
	}

	private kick() {
		if (this.destroyed || this.raf || document.visibilityState === "hidden") return;
		this.lastFrameTime = performance.now();
		this.raf = requestAnimationFrame(this.frame);
	}

	private frame = (now: number) => {
		this.raf = 0;
		if (this.destroyed || document.visibilityState === "hidden") return;

		// Cap framerate (~30fps during active WebUSB install, ~45fps otherwise) so flashing stays silky and main thread stays responsive
		const minFrameMs = this.mode === "install" ? 33 : 22;
		const rawMs = now - this.lastFrameTime;
		if (rawMs < minFrameMs) {
			this.raf = requestAnimationFrame(this.frame);
			return;
		}
		this.lastFrameTime = now;
		const dt = Math.min(0.05, rawMs / 1000);
		this.elapsed += dt;

		if (this.syncSize()) {
			this.updateScene(dt);
			this.renderer.render(this.scene, this.camera);
		}

		this.raf = requestAnimationFrame(this.frame);
	};

	private updateScene(dt: number) {
		const t = this.elapsed;

		// Smooth pointer parallax & spring-back orbit
		this.pointerCurrent.lerp(this.pointerTarget, Math.min(1, dt * 5));
		if (!this.dragging) {
			this.dragOffset.multiplyScalar(Math.max(0, 1 - dt * 3.0));
		}

		// Mode-driven wilt / celebrate / spin transitions
		const targetWilt = this.mode === "error" ? 1 : 0;
		this.wiltBlend += (targetWilt - this.wiltBlend) * Math.min(1, dt * 4.5);

		if (this.celebrateTimer > 0) {
			this.celebrateTimer = Math.max(0, this.celebrateTimer - dt);
		}
		const plant = this.updatePlant(dt, t);
		this.easePalette(dt);
		// The celebration's later waves of petal confetti and sparks
		if (this.celebrateWaves.length) {
			this.celebrateClock += dt;
			if (this.celebrateClock >= this.celebrateWaves[0]) {
				this.celebrateWaves.shift();
				this.spawnMiniPetals(64, undefined, 1.35);
				this.spawnSparks(72, undefined, 1.5);
			}
		}
		// While the plant is small the camera looks down at the soil, closer in
		const lift = (1 - plant.follow) * (SOIL_Y + PLANTED_LOOK);

		if (this.mode === "install") {
			this.spinAngle += dt * 0.36;
		} else {
			const sway = Math.sin(t * 0.32) * 0.08 * (1 - this.wiltBlend);
			const wrap = Math.atan2(Math.sin(this.spinAngle), Math.cos(this.spinAngle));
			this.spinAngle = wrap * Math.max(0, 1 - dt * 3.5) + sway * Math.min(1, dt * 3.5);
		}

		// Angled 3/4 sculptural hero camera with gentle orbital drift & pointer parallax
		const camX = 0.44 + Math.sin(t * 0.42) * 0.36 + this.pointerCurrent.x * 0.42 + this.dragOffset.x * 1.45;
		const camY = 0.94 + Math.cos(t * 0.36) * 0.22 - this.pointerCurrent.y * 0.34 - this.dragOffset.y * 1.15;
		this.camera.position.set(camX, camY + lift, 5.15 - (1 - plant.follow) * 0.75);
		this.camera.lookAt(0, -0.04 + lift, 0);
		this.pollenPoints.position.y = lift;

		// Whole flower float, spatial sway, & mode expression
		const floatY = this.mode === "error" ? -0.14 : Math.sin(t * 1.15) * 0.05;
		const tiltX = this.mode === "error" ? 0.44 : 0.06 + Math.cos(t * 0.48) * 0.07 + this.pointerCurrent.y * 0.14;
		const tiltY = Math.sin(t * 0.44) * 0.22 * (1 - this.wiltBlend) + this.pointerCurrent.x * 0.22;
		this.flowerGroup.position.y += (floatY + plant.headY - this.flowerGroup.position.y) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.x += (tiltX - this.flowerGroup.rotation.x) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.y += (tiltY - this.flowerGroup.rotation.y) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.z = this.spinAngle;

		const bloomFlare = this.celebrateTimer > 0 ? Math.sin((this.celebrateTimer / 1.8) * Math.PI) * 0.12 : 0;
		const idleBreathe = this.mode === "idle" ? Math.sin(t * 1.35) * 0.024 : 0;
		const baseScale = (this.mode === "error" ? 0.92 : 1.06) + bloomFlare + idleBreathe;
		this.flowerGroup.scale.setScalar(baseScale * plant.headScale);
		this.flowerGroup.visible = plant.headScale > 0.001;

		// Update 4 sculpted ExpressiveOS Hero Petals
		const shimmerTarget = this.mode === "verify" ? 1 : 0;
		const rippleAmt = this.mode === "error" ? 0.15 : this.mode === "install" ? 1.15 : 0.78;

		this.heroPetals.forEach((item, i) => {
			// Full colour throughout: the bud's closing is a curl (budClose below), not a fade
			item.targetFill = 1;
			item.fill += (item.targetFill - item.fill) * Math.min(1, dt * 6);
			const isFull = item.fill >= 0.96;
			if (isFull && !item.wasFull && this.mode === "download") {
				item.popTimer = 1;
				this.spawnMiniPetals(10, i, 0.75);
			}
			item.wasFull = isFull;

			if (item.popTimer > 0) item.popTimer = Math.max(0, item.popTimer - dt * 1.35);
			if (item.pulseFlash > 0) item.pulseFlash = Math.max(0, item.pulseFlash - dt * 2.2);

			// True 3D cupped corolla pitch: unfilled petals curl inward as closed buds; open petals hold sculptural cup & gentle wave
			const budCurl = (1 - item.fill) * -0.58;
			const waitPart = this.mode === "waiting" ? Math.sin(t * 2.6 + i * 0.45) * 0.14 + 0.08 : 0;
			const popSpring = item.popTimer > 0 ? Math.sin(item.popTimer * Math.PI) * 0.24 : 0;
			const errorDroop = this.wiltBlend * -0.42;
			const breatheTilt = Math.sin(t * 1.25 + i * 1.35) * 0.055 * (1 - this.wiltBlend);

			// A closed bud until the install is done, opening into full bloom
			const budClose = (1 - plant.open) * -1.15;
			const tiltAngle = item.basePitch * item.fill + budCurl + budClose + waitPart + popSpring + errorDroop + breatheTilt;
			this.tmpQuat.setFromAxisAngle(item.perpAxis, tiltAngle);
			item.pivot.quaternion.copy(this.tmpQuat);

			const [dx, dy] = PETAL_DIRS[item.petal.name];
			const spread = (this.mode === "waiting" ? Math.sin(t * 2.6 + i * 0.4) * 0.05 : 0) + popSpring * 0.22;
			item.pivot.position.set(dx * spread, dy * spread, item.baseZ);

			const s = 0.84 + 0.16 * easeOutCubic(item.fill) + popSpring * 0.18;
			item.mesh.scale.setScalar(s);

			// Shader uniforms
			item.uniforms.uFill.value = item.fill;
			item.uniforms.uTime.value = t;
			item.uniforms.uRipple.value = rippleAmt;
			item.uniforms.uWilt.value = this.wiltBlend;
			const shimmerVal = Math.max(shimmerTarget, item.pulseFlash);
			item.uniforms.uShimmer.value += (shimmerVal - item.uniforms.uShimmer.value) * Math.min(1, dt * 8);

			const baseEmissive = this.mode === "complete" ? 0.3 : this.mode === "install" ? 0.22 : 0.12;
			item.material.emissiveIntensity = (baseEmissive + item.pulseFlash * 0.75) * (1 - this.wiltBlend * 0.8);
		});

		// Update backing translucent calyx petals
		for (const bp of this.backingPetals) {
			const openLift = this.mode === "error" ? -0.25 : this.celebrateTimer > 0 ? 0.24 : 0;
			bp.mesh.rotation.x = bp.baseRotX + openLift + Math.sin(t * 1.1 + bp.phase) * 0.06;
			bp.material.opacity = 0.94 * (1 - this.wiltBlend * 0.4) * plant.open;
			bp.pivot.visible = plant.open > 0.01;
		}

		// Update luminous core & corona
		const corePulse = 1 + Math.sin(t * (this.mode === "waiting" ? 2.6 : 3.2)) * 0.1 + (this.celebrateTimer > 0 ? 0.3 : 0);
		this.coreGroup.scale.setScalar(corePulse * (1 - this.wiltBlend * 0.35));
		const coronaSize = 0.94 + Math.sin(t * 2.4) * 0.09 + (this.celebrateTimer > 0 ? 0.34 : 0);
		this.coronaSprite.scale.set(coronaSize, coronaSize, 1);
		this.coreLight.intensity = (this.mode === "complete" ? 3.2 : this.mode === "install" ? 2.6 : 2.1) * (1 - this.wiltBlend * 0.75);
		this.coronaMat.opacity = (this.mode === "complete" ? 0.4 : 0.22) * (1 - this.wiltBlend * 0.75);

		if (this.mode === "error") this.coreLight.color.setHex(0xd33952);
		else if (this.mode === "verify") this.coreLight.color.setHex(0x76bcfb);
		else if (this.mode === "waiting") this.coreLight.color.setHex(0xfdcf8e);
		else this.coreLight.color.copy(this.coreTint);
		this.coronaMat.color.copy(this.coreLight.color);

		// Update 3D Orbital Progress Ring
		const ringOn = this.mode === "install" || this.mode === "waiting" || this.mode === "complete";
		const targetRingOpacity = ringOn ? 1 : 0;
		this.ringUniforms.uOpacity.value += (targetRingOpacity - this.ringUniforms.uOpacity.value) * Math.min(1, dt * 5);
		this.ringTrackMat.opacity = this.ringUniforms.uOpacity.value * (this.isLight ? 0.1 : 0.12);
		this.ringUniforms.uProgress.value += (this.progress - this.ringUniforms.uProgress.value) * Math.min(1, dt * 8);
		this.ringUniforms.uTime.value = t;
		this.ringUniforms.uPulse.value = this.mode === "waiting" ? 0.55 + 0.45 * Math.sin(t * 2.8) : 1;
		if (this.mode === "install") this.ringRot += dt * 0.12;
		this.ringMesh.rotation.set(this.flowerGroup.rotation.x * 0.55, this.flowerGroup.rotation.y * 0.55, this.ringRot);
		this.ringTrackMesh.rotation.copy(this.ringMesh.rotation);
		// The ring circles the growing head
		this.ringMesh.position.y = this.ringTrackMesh.position.y = this.flowerGroup.position.y;
		this.ringMesh.scale.setScalar(Math.max(0.5, plant.headScale));
		this.ringTrackMesh.scale.copy(this.ringMesh.scale);

		// Update ambient pollen motes & bursts
		this.updatePollen(dt, t);
		this.updateBursts(dt);
	}

	private updatePollen(dt: number, t: number) {
		const fillingIdx = Math.min(3, Math.floor(this.progress * 4));
		const activeDir = PETAL_DIRS[PETALS[fillingIdx].name];
		const speedMult = this.mode === "download" ? 1 + this.downloadRate * 0.045 : this.mode === "error" ? 0.25 : 1;

		for (let i = 0; i < MAX_AMBIENT_POLLEN; i++) {
			const p = this.pollenParticles[i];
			if (this.mode === "download" && i % 2 === 0) {
				// Spiral inward toward the currently filling petal
				const tx = activeDir[0] * 0.65;
				const ty = activeDir[1] * 0.65;
				const dx = tx - p.x;
				const dy = ty - p.y;
				const d = Math.hypot(dx, dy);
				if (d < 0.2 || p.life > p.max) {
					const a = Math.random() * Math.PI * 2;
					const r = 2.0 + Math.random() * 0.8;
					p.x = Math.cos(a) * r;
					p.y = Math.sin(a) * r;
					p.z = (Math.random() - 0.5) * 0.8;
					p.life = 0;
				} else {
					const pull = (1.6 + speedMult * 0.75) * dt;
					p.x += (dx / d) * pull - (dy / d) * pull * 0.55;
					p.y += (dy / d) * pull + (dx / d) * pull * 0.55;
					p.z += Math.sin(t * 2 + i) * 0.15 * dt;
					p.life += dt;
				}
			} else if (this.mode === "error") {
				p.y -= dt * 0.35;
				p.x += Math.sin(t + i) * 0.08 * dt;
				if (p.y < -2.3) p.y = 2.2;
			} else {
				p.orbitAngle += p.orbitSpeed * dt * (this.mode === "install" ? 1.8 : 1.0);
				const bob = Math.sin(t * 0.9 + i * 0.7) * 0.14;
				p.x = Math.cos(p.orbitAngle) * p.orbitR;
				p.y = Math.sin(p.orbitAngle) * p.orbitR + bob;
				p.z = Math.cos(t * 0.6 + i) * 0.45;
			}
			this.pollenPos[i * 3] = p.x;
			this.pollenPos[i * 3 + 1] = p.y;
			this.pollenPos[i * 3 + 2] = p.z;
		}
		this.pollenGeom.attributes.position.needsUpdate = true;
	}

	private updateBursts(dt: number) {
		let anyPetal = false;
		for (let i = 0; i < MAX_BURST_PETALS; i++) {
			const bp = this.burstPetals[i];
			if (!bp.active) continue;
			anyPetal = true;
			bp.life += dt;
			if (bp.life >= bp.max) {
				bp.active = false;
				this.dummy.scale.setScalar(0);
				this.dummy.updateMatrix();
				this.burstMesh.setMatrixAt(i, this.dummy.matrix);
				continue;
			}
			const t = bp.life / bp.max;
			bp.vy -= 1.35 * dt;
			bp.vx *= 1 - 0.95 * dt;
			bp.vz *= 1 - 0.95 * dt;
			bp.x += bp.vx * dt;
			bp.y += bp.vy * dt;
			bp.z += bp.vz * dt;
			bp.rx += bp.vrx * dt;
			bp.ry += bp.vry * dt;
			bp.rz += bp.vrz * dt;

			const fade = t < 0.15 ? easeOutBack(t / 0.15) : 1 - Math.pow((t - 0.15) / 0.85, 2);
			this.dummy.position.set(bp.x, bp.y, bp.z);
			this.dummy.rotation.set(bp.rx, bp.ry, bp.rz);
			this.dummy.scale.setScalar(Math.max(0, bp.scale * fade));
			this.dummy.updateMatrix();
			this.burstMesh.setMatrixAt(i, this.dummy.matrix);
		}
		if (anyPetal) this.burstMesh.instanceMatrix.needsUpdate = true;

		let anySpark = false;
		for (let i = 0; i < MAX_BURST_SPARKS; i++) {
			const sp = this.sparkParticles[i];
			if (sp.life >= sp.max) continue;
			anySpark = true;
			sp.life += dt;
			if (sp.life >= sp.max) {
				this.sparkPos[i * 3 + 2] = SPARK_PARKED_Z;
				continue;
			}
			sp.vy -= 1.1 * dt;
			sp.vx *= 1 - 1.2 * dt;
			sp.vz *= 1 - 1.2 * dt;
			sp.x += sp.vx * dt;
			sp.y += sp.vy * dt;
			sp.z += sp.vz * dt;
			this.sparkPos[i * 3] = sp.x;
			this.sparkPos[i * 3 + 1] = sp.y;
			this.sparkPos[i * 3 + 2] = sp.z;
		}
		if (anySpark) this.sparkGeom.attributes.position.needsUpdate = true;
	}

	destroy() {
		this.destroyed = true;
		cancelAnimationFrame(this.raf);
		this.raf = 0;
		this.resizeObs.disconnect();
		this.themeObs.disconnect();
		this.colorSchemeQuery?.removeEventListener?.("change", this.onThemeMedia);
		document.removeEventListener("visibilitychange", this.onVisibility);
		document.removeEventListener(PLANT_EVENT, this.onPlant);

		const dom = this.container;
		dom.removeEventListener("pointermove", this.onPointerMove);
		dom.removeEventListener("pointerdown", this.onPointerDown);
		window.removeEventListener("pointerup", this.onPointerUp);
		dom.removeEventListener("pointerleave", this.onPointerLeave);

		this.envTargetDark?.dispose();
		this.envTargetLight?.dispose();
		for (const d of this.disposables) d.dispose();
		this.renderer.dispose();
		dom.remove();
	}
}
