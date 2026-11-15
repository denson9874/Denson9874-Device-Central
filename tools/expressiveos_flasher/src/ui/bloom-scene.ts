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
	CanvasTexture,
	Color,
	DirectionalLight,
	DoubleSide,
	DynamicDrawUsage,
	ExtrudeGeometry,
	Float32BufferAttribute,
	Group,
	InstancedMesh,
	LineBasicMaterial,
	LineSegments,
	MathUtils,
	Mesh,
	MeshBasicMaterial,
	MeshPhysicalMaterial,
	Object3D,
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
	Vector2,
	Vector3,
	WebGLRenderer,
} from "three";
import { PETALS, type Petal } from "./petals.ts";

export type BloomSceneMode = "idle" | "download" | "verify" | "install" | "waiting" | "complete" | "error";

const SVG_CENTER = 54;
const SVG_SCALE = 1 / 20;
const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

/** Outward unit direction in Three.js XY space (SVG +Y flipped to +Y up). */
const PETAL_DIRS: Record<Petal["name"], [number, number]> = {
	violet: [-0.69, 0.72],
	blue: [0.76, 0.65],
	green: [0.7, -0.72],
	coral: [-0.74, -0.67],
};

const easeOutBack = (t: number): number => {
	const c1 = 1.70158;
	const c3 = c1 + 1;
	const u = MathUtils.clamp(t, 0, 1);
	return 1 + c3 * Math.pow(u - 1, 3) + c1 * Math.pow(u - 1, 2);
};

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - MathUtils.clamp(t, 0, 1), 3);

/** Parse ExpressiveOS's SVG M/C/Z petal path into a centered Three.js Shape. */
function petalPathToShape(d: string): Shape {
	const shape = new Shape();
	const tokens = d.match(/[MCZ]|-?\d*\.?\d+/g) ?? [];
	const toX = (sx: number) => (sx - SVG_CENTER) * SVG_SCALE;
	const toY = (sy: number) => (SVG_CENTER - sy) * SVG_SCALE;
	let i = 0;
	let cmd = "";
	while (i < tokens.length) {
		const t = tokens[i];
		if (t === "M" || t === "C" || t === "Z") {
			cmd = t;
			i++;
			if (cmd === "Z") shape.closePath();
			continue;
		}
		if (cmd === "M") {
			shape.moveTo(toX(Number(tokens[i])), toY(Number(tokens[i + 1])));
			i += 2;
		} else if (cmd === "C") {
			shape.bezierCurveTo(
				toX(Number(tokens[i])),
				toY(Number(tokens[i + 1])),
				toX(Number(tokens[i + 2])),
				toY(Number(tokens[i + 3])),
				toX(Number(tokens[i + 4])),
				toY(Number(tokens[i + 5])),
			);
			i += 6;
		} else {
			i++;
		}
	}
	return shape;
}

/** Build a sculpted, cupped 3D ExpressiveOS brand petal with gradient vertex colors and radial fill attribute. */
function createBrandPetalGeometry(petal: Petal): BufferGeometry {
	const shape = petalPathToShape(petal.d);
	const geom = new ExtrudeGeometry(shape, {
		depth: 0.075,
		bevelEnabled: true,
		bevelThickness: 0.042,
		bevelSize: 0.032,
		bevelSegments: 5,
		curveSegments: 28,
	});
	geom.translate(0, 0, -0.0375);

	const pos = geom.attributes.position;
	const count = pos.count;
	const colors = new Float32Array(count * 3);
	const fillAttr = new Float32Array(count);

	const gx1 = (petal.x1 - SVG_CENTER) * SVG_SCALE;
	const gy1 = (SVG_CENTER - petal.y1) * SVG_SCALE;
	const gx2 = (petal.x2 - SVG_CENTER) * SVG_SCALE;
	const gy2 = (SVG_CENTER - petal.y2) * SVG_SCALE;
	const gdx = gx2 - gx1;
	const gdy = gy2 - gy1;
	const gLenSq = Math.max(1e-5, gdx * gdx + gdy * gdy);

	const cLight = new Color(petal.light);
	const cMid = new Color(petal.mid);
	const cDeep = new Color(petal.deep);
	const cTmp = new Color();

	for (let i = 0; i < count; i++) {
		const x = pos.getX(i);
		const y = pos.getY(i);
		const z = pos.getZ(i);

		const r = Math.hypot(x, y);
		const rNorm = MathUtils.clamp((r - 0.16) / 1.42, 0, 1);
		fillAttr[i] = rNorm;

		// Cupping dome toward viewer with gentle outer tip curl (adapted from flowers-ref/js/utils.js)
		const cupOffset = Math.sin(rNorm * Math.PI * 0.88) * 0.145 - Math.pow(rNorm, 1.9) * 0.065;
		pos.setZ(i, z + cupOffset);

		const t = MathUtils.clamp(((x - gx1) * gdx + (y - gy1) * gdy) / gLenSq, 0, 1);
		if (t < 0.5) cTmp.lerpColors(cLight, cMid, t * 2);
		else cTmp.lerpColors(cMid, cDeep, (t - 0.5) * 2);
		colors[i * 3] = cTmp.r;
		colors[i * 3 + 1] = cTmp.g;
		colors[i * 3 + 2] = cTmp.b;
	}

	pos.needsUpdate = true;
	geom.setAttribute("color", new BufferAttribute(colors, 3));
	geom.setAttribute("aFill", new Float32BufferAttribute(fillAttr, 1));
	geom.computeVertexNormals();
	return geom;
}

/** Dual-axis curved translucent backing petal geometry (adapted from flowers-ref/js/utils.js). */
function createCalixPetalGeometry(width = 0.52, length = 1.25): BufferGeometry {
	const uSegs = 14;
	const vSegs = 22;
	const geom = new PlaneGeometry(width, length, uSegs, vSegs);
	const pos = geom.attributes.position;
	const cup = 0.16;
	const curl = 0.24;
	const flare = 0.1;
	const ruffle = 0.02;

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

/** Procedural soft-glow radial sprite texture for bokeh pollen and core corona. */
function createGlowTexture(innerStop = "rgba(255,255,255,1)", midStop = "rgba(255,255,255,0.4)"): CanvasTexture {
	const canvas = document.createElement("canvas");
	canvas.width = 128;
	canvas.height = 128;
	const ctx = canvas.getContext("2d")!;
	const g = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
	g.addColorStop(0, innerStop);
	g.addColorStop(0.28, midStop);
	g.addColorStop(0.65, "rgba(255,255,255,0.08)");
	g.addColorStop(1, "rgba(255,255,255,0)");
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
		bg.addColorStop(0.55, "#ebe4ff");
		bg.addColorStop(1, "#d8cff7");
	} else {
		bg.addColorStop(0, "#1d1a3d");
		bg.addColorStop(0.5, "#111028");
		bg.addColorStop(1, "#070714");
	}
	ctx.fillStyle = bg;
	ctx.fillRect(0, 0, 512, 256);

	const drawLight = (x: number, y: number, r: number, inner: string, mid: string) => {
		const g = ctx.createRadialGradient(x, y, 4, x, y, r);
		g.addColorStop(0, inner);
		g.addColorStop(0.45, mid);
		g.addColorStop(1, "transparent");
		ctx.fillStyle = g;
		ctx.fillRect(x - r, y - r, r * 2, r * 2);
	};

	// Key studio softbox + violet/blue/coral rim accents matching ExpressiveOS palette
	drawLight(140, 72, 130, "#ffffff", lightTheme ? "rgba(243, 177, 252, 0.5)" : "rgba(243, 177, 252, 0.65)");
	drawLight(385, 92, 120, "#f5f8ff", lightTheme ? "rgba(118, 188, 251, 0.45)" : "rgba(118, 188, 251, 0.55)");
	drawLight(256, 200, 140, "rgba(253, 207, 142, 0.45)", "rgba(172, 239, 179, 0.2)");

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
}

interface HeroPetalItem {
	petal: Petal;
	pivot: Group;
	mesh: Mesh;
	material: MeshPhysicalMaterial;
	uniforms: PetalUniforms;
	perpAxis: Vector3;
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
	};
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
	private spawnDebt = 0;

	private elapsed = 0;
	private lastFrameTime = 0;
	private raf = 0;
	private destroyed = false;

	private celebrateTimer = 0;
	private wiltBlend = 0;
	private spinAngle = 0;
	private ringRot = 0;

	// Pointer parallax & gentle drag-orbit
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
		this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
		this.renderer.toneMapping = ACESFilmicToneMapping;
		this.renderer.toneMappingExposure = 1.12;
		this.renderer.domElement.className = "bloom-webgl";
		this.renderer.domElement.setAttribute("aria-hidden", "true");
		container.append(this.renderer.domElement);

		this.scene = new Scene();
		this.camera = new PerspectiveCamera(38, 1, 0.1, 40);
		this.camera.position.set(0, -0.15, 6.2);
		this.camera.lookAt(0, 0, 0);

		// Studio lighting
		this.ambientLight = new AmbientLight(0xeae6ff, 0.55);
		this.keyLight = new DirectionalLight(0xfff6f0, 2.0);
		this.keyLight.position.set(3.2, 4.2, 4.5);
		this.rimLight = new DirectionalLight(0xae69fc, 1.5);
		this.rimLight.position.set(-3.5, 2.5, -2.5);
		this.fillLight = new DirectionalLight(0x76bcfb, 0.95);
		this.fillLight.position.set(2.5, -3.0, 2.0);
		this.scene.add(this.ambientLight, this.keyLight, this.rimLight, this.fillLight);

		this.flowerGroup = new Group();
		this.scene.add(this.flowerGroup);

		// Build backing translucent calyx petals (from flowers-ref createCurvedPetalGeometry)
		this.buildBackingPetals();

		// Build the 4 sculpted ExpressiveOS brand petals
		this.buildHeroPetals();

		// Build luminous center core, corona glow sprite & Fibonacci stamen anthers
		const { coreGroup, coreLight, coronaSprite, coronaMat } = this.buildCore();
		this.coreGroup = coreGroup;
		this.coreLight = coreLight;
		this.coronaSprite = coronaSprite;
		this.coronaMat = coronaMat;
		this.flowerGroup.add(this.coreGroup);

		// Build 3D orbital progress ring
		const ring = this.buildProgressRing();
		this.ringUniforms = ring.uniforms;
		this.ringTrackMat = ring.trackMat;
		this.ringMesh = ring.arcMesh;
		this.ringTrackMesh = ring.trackMesh;
		this.scene.add(this.ringTrackMesh, this.ringMesh);

		// Build pollen & celebration particles
		const glowTex = createGlowTexture("rgba(255,255,255,1)", "rgba(255,255,255,0.45)");
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
		this.initAmbientPollen();

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

		// Instanced 3D mini-petals for partition pulse & full-bloom burst
		const miniGeom = createCalixPetalGeometry(0.16, 0.28);
		const miniMat = new MeshPhysicalMaterial({
			color: 0xffffff,
			roughness: 0.25,
			metalness: 0.05,
			clearcoat: 0.8,
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

		// Sync light/dark theme
		this.syncTheme();
		this.themeObs = new MutationObserver(() => this.syncTheme());
		this.themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
		this.colorSchemeQuery = window.matchMedia?.("(prefers-color-scheme: light)") ?? null;
		this.colorSchemeQuery?.addEventListener?.("change", this.onThemeMedia);

		// Pointer parallax & drag interaction on canvas
		const dom = this.renderer.domElement;
		dom.addEventListener("pointermove", this.onPointerMove);
		dom.addEventListener("pointerdown", this.onPointerDown);
		window.addEventListener("pointerup", this.onPointerUp);
		dom.addEventListener("pointerleave", this.onPointerLeave);

		this.resizeObs = new ResizeObserver(() => this.resize());
		this.resizeObs.observe(container);
		this.resize();

		document.addEventListener("visibilitychange", this.onVisibility);
		this.kick();
	}

	private buildBackingPetals() {
		const backingColors = [
			new Color(PETALS[0].light).lerp(new Color(PETALS[1].light), 0.5),
			new Color(PETALS[1].light).lerp(new Color(PETALS[2].light), 0.5),
			new Color(PETALS[2].light).lerp(new Color(PETALS[3].light), 0.5),
			new Color(PETALS[3].light).lerp(new Color(PETALS[0].light), 0.5),
		];
		const geom = createCalixPetalGeometry(0.62, 1.32);
		this.disposables.push(geom);

		for (let i = 0; i < 4; i++) {
			const mat = new MeshPhysicalMaterial({
				color: backingColors[i],
				emissive: backingColors[i],
				emissiveIntensity: 0.14,
				roughness: 0.22,
				metalness: 0.05,
				clearcoat: 1.0,
				clearcoatRoughness: 0.12,
				iridescence: 0.65,
				iridescenceIOR: 1.35,
				transparent: true,
				opacity: 0.34,
				side: DoubleSide,
				depthWrite: false,
			});
			this.disposables.push(mat);

			const pivot = new Group();
			pivot.rotation.z = (Math.PI / 4) + i * (Math.PI / 2);
			pivot.position.z = -0.14;

			const mesh = new Mesh(geom, mat);
			const baseRotX = -0.42;
			mesh.rotation.x = baseRotX;
			mesh.position.y = 0.08;
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
				uRipple: { value: 0.7 },
				uShimmer: { value: 0 },
				uWilt: { value: 0 },
				uPhase: { value: i * 1.45 },
				uGhostColor: { value: new Color(0x2d2958) },
				uPetalLight: { value: new Color(petal.light) },
			};

			const mat = new MeshPhysicalMaterial({
				vertexColors: true,
				roughness: 0.22,
				metalness: 0.05,
				clearcoat: 0.92,
				clearcoatRoughness: 0.12,
				sheen: 0.85,
				sheenRoughness: 0.32,
				sheenColor: new Color(petal.light),
				iridescence: 0.36,
				iridescenceIOR: 1.32,
				emissive: new Color(petal.mid),
				emissiveIntensity: 0.16,
				transparent: true,
				envMapIntensity: 1.25,
			});
			mat.customProgramCacheKey = () => "eos-petal-v1";
			mat.onBeforeCompile = (shader) => {
				Object.assign(shader.uniforms, uniforms);
				shader.vertexShader = shader.vertexShader
					.replace(
						"#include <common>",
						`#include <common>
attribute float aFill;
varying float vFillPos;
uniform float uTime;
uniform float uRipple;
uniform float uPhase;`,
					)
					.replace(
						"#include <begin_vertex>",
						`#include <begin_vertex>
vFillPos = aFill;
float tipW = smoothstep(0.18, 1.0, aFill);
float w1 = sin(position.y * 4.2 - uTime * 2.1 + uPhase + position.x * 3.1) * 0.032;
float w2 = cos(position.x * 5.6 - uTime * 2.8 + uPhase) * 0.016;
transformed.z += (w1 + w2) * tipW * uRipple;`,
					);

				shader.fragmentShader = shader.fragmentShader
					.replace(
						"#include <common>",
						`#include <common>
varying float vFillPos;
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
float edgeDist = abs(vFillPos - uFill);
float fillWave = (uFill > 0.01 && uFill < 0.99) ? exp(-edgeDist * edgeDist * 170.0) : 0.0;
float sweep = pow(max(0.0, sin(vFillPos * 5.2 - uTime * 3.6 + uPhase)), 6.0) * uShimmer;
vec3 viewDirF = normalize(vViewPosition);
float fresnelF = pow(1.0 - abs(dot(normal, viewDirF)), 2.5);
totalEmissiveRadiance *= fillMask * (1.0 - uWilt * 0.85);
totalEmissiveRadiance += uPetalLight * (fillWave * 1.35 + sweep * 0.9 + fresnelF * mix(0.18, 0.34, fillMask) * (1.0 - uWilt * 0.72));`,
					);
			};

			this.disposables.push(mat);

			const pivot = new Group();
			const mesh = new Mesh(geom, mat);
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
		coreGroup.position.set(0, 0, 0.12);

		// Pearlescent inner hub sphere
		const sphereGeom = new SphereGeometry(0.13, 24, 24);
		const sphereMat = new MeshPhysicalMaterial({
			color: 0xffffff,
			emissive: 0xd8b4fe,
			emissiveIntensity: 0.9,
			roughness: 0.12,
			metalness: 0.1,
			clearcoat: 1.0,
		});
		this.disposables.push(sphereGeom, sphereMat);
		coreGroup.add(new Mesh(sphereGeom, sphereMat));

		// Soft volumetric additive corona sprite
		const coronaTex = createGlowTexture("rgba(255,255,255,0.95)", "rgba(210,175,255,0.45)");
		const coronaMat = new SpriteMaterial({
			map: coronaTex,
			color: 0xd8b4fe,
			transparent: true,
			opacity: 0.72,
			blending: AdditiveBlending,
			depthWrite: false,
		});
		this.disposables.push(coronaTex, coronaMat);
		const coronaSprite = new Sprite(coronaMat);
		coronaSprite.scale.set(0.95, 0.95, 1);
		coreGroup.add(coronaSprite);

		// Fibonacci stamen filaments (1 merged LineSegments + 1 InstancedMesh = 2 draw calls)
		const stamenCount = 16;
		const linePts: number[] = [];
		const antherGeom = new SphereGeometry(0.022, 10, 10);
		const antherMat = new MeshPhysicalMaterial({
			color: 0xffe4a0,
			emissive: 0xfdcf8e,
			emissiveIntensity: 0.65,
			roughness: 0.35,
		});
		this.disposables.push(antherGeom, antherMat);
		const anthers = new InstancedMesh(antherGeom, antherMat, stamenCount);
		const dummy = new Object3D();

		for (let i = 0; i < stamenCount; i++) {
			const theta = i * GOLDEN_ANGLE;
			const r = 0.08 + 0.11 * Math.sqrt((i + 1) / stamenCount);
			const bx = Math.cos(theta) * 0.04;
			const by = Math.sin(theta) * 0.04;
			const tx = Math.cos(theta) * r;
			const ty = Math.sin(theta) * r;
			const tz = 0.11 + (i % 3) * 0.025;
			linePts.push(bx, by, 0, tx, ty, tz);

			dummy.position.set(tx, ty, tz);
			dummy.scale.set(1, 1, 1.35);
			dummy.lookAt(tx * 2, ty * 2, tz + 0.2);
			dummy.updateMatrix();
			anthers.setMatrixAt(i, dummy.matrix);
		}
		anthers.instanceMatrix.needsUpdate = true;

		const lineGeom = new BufferGeometry();
		lineGeom.setAttribute("position", new Float32BufferAttribute(linePts, 3));
		const lineMat = new LineBasicMaterial({ color: 0xf5e9ff, transparent: true, opacity: 0.55 });
		this.disposables.push(lineGeom, lineMat);
		coreGroup.add(new LineSegments(lineGeom, lineMat), anthers);

		const coreLight = new PointLight(0xc084fc, 2.2, 5.5);
		coreLight.position.set(0, 0, 0.35);
		coreGroup.add(coreLight);

		return { coreGroup, coreLight, coronaSprite, coronaMat };
	}

	private buildProgressRing() {
		const radius = 1.88;
		const trackGeom = new TorusGeometry(radius, 0.014, 10, 112);
		const trackMat = new MeshBasicMaterial({
			color: 0xffffff,
			transparent: true,
			opacity: 0,
			depthWrite: false,
		});
		const trackMesh = new Mesh(trackGeom, trackMat);

		const arcGeom = new TorusGeometry(radius, 0.028, 12, 128);
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

	private initAmbientPollen() {
		const c = new Color();
		for (let i = 0; i < MAX_AMBIENT_POLLEN; i++) {
			const p = PETALS[i % 4];
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
			this.sparkPos[i * 3 + 2] = -20;
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
			this.ambientLight.intensity = 0.85;
			this.keyLight.intensity = 1.75;
			this.ringTrackMat.color.setHex(0x141329);
		} else {
			if (!this.envTargetDark) this.envTargetDark = createStudioEnvTexture(this.renderer, false);
			this.scene.environment = this.envTargetDark.texture;
			this.ambientLight.intensity = 0.55;
			this.keyLight.intensity = 2.05;
			this.ringTrackMat.color.setHex(0xffffff);
		}

		const ghostHex = this.isLight ? 0xd9cef7 : 0x2a2754;
		for (const item of this.heroPetals) {
			item.uniforms.uGhostColor.value.setHex(ghostHex);
		}
	}

	private onPointerMove = (ev: PointerEvent) => {
		const rect = this.renderer.domElement.getBoundingClientRect();
		if (rect.width <= 0 || rect.height <= 0) return;
		const nx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
		const ny = ((ev.clientY - rect.top) / rect.height) * 2 - 1;
		this.pointerTarget.set(MathUtils.clamp(nx, -1, 1), MathUtils.clamp(ny, -1, 1));

		if (this.dragging) {
			const dx = ev.clientX - this.lastDrag.x;
			const dy = ev.clientY - this.lastDrag.y;
			this.lastDrag.set(ev.clientX, ev.clientY);
			this.dragOffset.x = MathUtils.clamp(this.dragOffset.x + dx * 0.008, -0.65, 0.65);
			this.dragOffset.y = MathUtils.clamp(this.dragOffset.y + dy * 0.008, -0.45, 0.45);
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

	resize() {
		const r = this.container.getBoundingClientRect();
		const w = Math.max(1, r.width);
		const h = Math.max(1, r.height);
		this.camera.aspect = w / h;
		this.camera.updateProjectionMatrix();
		this.renderer.setSize(w, h, false);
	}

	setMode(mode: BloomSceneMode) {
		this.mode = mode;
		if (mode === "download") this.downloadRate = 18;
		else if (mode === "idle") this.downloadRate = 3;
		else this.downloadRate = 0;
		if (mode !== "complete") this.celebrateTimer = 0;
		this.setProgress(mode === "complete" ? 1 : this.progress);
	}

	setProgress(p: number) {
		this.progress = MathUtils.clamp(p, 0, 1);
		const filling = this.mode === "download" || this.mode === "idle";
		this.heroPetals.forEach((item, i) => {
			item.targetFill = filling ? MathUtils.clamp(this.progress * 4 - i, 0, 1) : 1;
		});
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
			bp.z = 0.18 + Math.random() * 0.15;
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
			bp.color.set([p.light, p.mid, p.deep][spawned % 3]);
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
			sp.z = 0.2;
			sp.vx = Math.cos(a) * speed;
			sp.vy = Math.sin(a) * speed + 0.4 * power;
			sp.vz = (Math.random() - 0.4) * 2.0 * power;
			sp.life = 0;
			sp.max = 1.0 + Math.random() * 1.2;
			c.set(spawned % 4 === 0 ? "#ffffff" : p.light);
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

		this.updateScene(dt);
		this.renderer.render(this.scene, this.camera);

		this.raf = requestAnimationFrame(this.frame);
	};

	private updateScene(dt: number) {
		const t = this.elapsed;

		// Smooth pointer parallax & spring-back orbit
		this.pointerCurrent.lerp(this.pointerTarget, Math.min(1, dt * 5));
		if (!this.dragging) {
			this.dragOffset.multiplyScalar(Math.max(0, 1 - dt * 3.2));
		}

		// Mode-driven wilt / celebrate / spin transitions
		const targetWilt = this.mode === "error" ? 1 : 0;
		this.wiltBlend += (targetWilt - this.wiltBlend) * Math.min(1, dt * 4.5);

		if (this.celebrateTimer > 0) {
			this.celebrateTimer = Math.max(0, this.celebrateTimer - dt);
		}

		if (this.mode === "install") {
			this.spinAngle += dt * 0.34;
		} else {
			// Ease back cleanly toward upright orientation so brand mark reads clearly
			const wrap = Math.atan2(Math.sin(this.spinAngle), Math.cos(this.spinAngle));
			this.spinAngle = wrap * Math.max(0, 1 - dt * 3.5);
		}

		// Hero camera subtle orbital breathing + pointer parallax
		const camDriftX = Math.sin(t * 0.45) * 0.14 + this.pointerCurrent.x * 0.28 + this.dragOffset.x * 1.1;
		const camDriftY = -0.14 + Math.cos(t * 0.38) * 0.09 - this.pointerCurrent.y * 0.22 - this.dragOffset.y * 0.9;
		this.camera.position.set(camDriftX, camDriftY, 6.15);
		this.camera.lookAt(0, 0, 0);

		// Whole flower float, tilt & mode expression
		const floatY = this.mode === "error" ? -0.12 : Math.sin(t * 1.15) * 0.045;
		const tiltX = this.mode === "error" ? 0.36 : -0.14 + Math.sin(t * 0.65) * 0.04 + this.pointerCurrent.y * 0.12;
		const tiltY = Math.cos(t * 0.55) * 0.07 + this.pointerCurrent.x * 0.16;
		this.flowerGroup.position.y += (floatY - this.flowerGroup.position.y) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.x += (tiltX - this.flowerGroup.rotation.x) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.y += (tiltY - this.flowerGroup.rotation.y) * Math.min(1, dt * 5);
		this.flowerGroup.rotation.z = this.spinAngle;

		const bloomFlare = this.celebrateTimer > 0 ? Math.sin((this.celebrateTimer / 1.8) * Math.PI) * 0.12 : 0;
		const idleBreathe = this.mode === "idle" ? Math.sin(t * 1.4) * 0.025 : 0;
		const baseScale = (this.mode === "error" ? 0.9 : 1.0) + bloomFlare + idleBreathe;
		this.flowerGroup.scale.setScalar(baseScale);

		// Update 4 ExpressiveOS Hero Petals
		const shimmerTarget = this.mode === "verify" ? 1 : 0;
		const rippleAmt = this.mode === "error" ? 0.15 : this.mode === "install" ? 1.15 : 0.72;

		this.heroPetals.forEach((item, i) => {
			item.fill += (item.targetFill - item.fill) * Math.min(1, dt * 6);
			const isFull = item.fill >= 0.96;
			if (isFull && !item.wasFull && this.mode === "download") {
				item.popTimer = 1;
				this.spawnMiniPetals(10, i, 0.75);
			}
			item.wasFull = isFull;

			if (item.popTimer > 0) item.popTimer = Math.max(0, item.popTimer - dt * 1.35);
			if (item.pulseFlash > 0) item.pulseFlash = Math.max(0, item.pulseFlash - dt * 2.2);

			// Curl inward as translucent bud when unfilled, flare open on bloom/waiting, droop on error
			const budCurl = (1 - item.fill) * -0.48;
			const waitPart = this.mode === "waiting" ? Math.sin(t * 2.6 + i * 0.45) * 0.12 + 0.08 : 0;
			const popSpring = item.popTimer > 0 ? Math.sin(item.popTimer * Math.PI) * 0.22 : 0;
			const errorDroop = this.wiltBlend * -0.34;
			const breatheTilt = Math.sin(t * 1.35 + i * 1.2) * 0.035 * (1 - this.wiltBlend);

			const tiltAngle = budCurl + waitPart + popSpring + errorDroop + breatheTilt;
			this.tmpQuat.setFromAxisAngle(item.perpAxis, tiltAngle);
			item.pivot.quaternion.copy(this.tmpQuat);

			const [dx, dy] = PETAL_DIRS[item.petal.name];
			const spread = (this.mode === "waiting" ? Math.sin(t * 2.6 + i * 0.4) * 0.045 : 0) + popSpring * 0.22;
			item.pivot.position.set(dx * spread, dy * spread, 0);

			const s = 0.84 + 0.16 * easeOutCubic(item.fill) + popSpring * 0.18;
			item.mesh.scale.setScalar(s);

			// Shader uniforms
			item.uniforms.uFill.value = item.fill;
			item.uniforms.uTime.value = t;
			item.uniforms.uRipple.value = rippleAmt;
			item.uniforms.uWilt.value = this.wiltBlend;
			const shimmerVal = Math.max(shimmerTarget, item.pulseFlash);
			item.uniforms.uShimmer.value += (shimmerVal - item.uniforms.uShimmer.value) * Math.min(1, dt * 8);

			const baseEmissive = this.mode === "complete" ? 0.34 : this.mode === "install" ? 0.24 : 0.15;
			item.material.emissiveIntensity = (baseEmissive + item.pulseFlash * 0.75) * (1 - this.wiltBlend * 0.8);
		});

		// Update backing translucent calyx petals
		for (const bp of this.backingPetals) {
			const openLift = this.mode === "error" ? -0.25 : this.celebrateTimer > 0 ? 0.24 : 0;
			bp.mesh.rotation.x = bp.baseRotX + openLift + Math.sin(t * 1.1 + bp.phase) * 0.05;
			bp.material.opacity = (this.isLight ? 0.28 : 0.34) * (1 - this.wiltBlend * 0.65);
		}

		// Update luminous core & corona
		const corePulse = 1 + Math.sin(t * (this.mode === "waiting" ? 2.6 : 3.2)) * 0.12 + (this.celebrateTimer > 0 ? 0.32 : 0);
		this.coreGroup.scale.setScalar(corePulse * (1 - this.wiltBlend * 0.35));
		const coronaSize = 0.95 + Math.sin(t * 2.4) * 0.1 + (this.celebrateTimer > 0 ? 0.35 : 0);
		this.coronaSprite.scale.set(coronaSize, coronaSize, 1);
		this.coreLight.intensity = (this.mode === "complete" ? 3.2 : this.mode === "install" ? 2.6 : 1.9) * (1 - this.wiltBlend * 0.75);
		this.coronaMat.opacity = (this.mode === "complete" ? 0.92 : 0.68) * (1 - this.wiltBlend * 0.75);

		if (this.mode === "error") this.coreLight.color.setHex(0xd33952);
		else if (this.mode === "verify") this.coreLight.color.setHex(0x76bcfb);
		else if (this.mode === "waiting") this.coreLight.color.setHex(0xfdcf8e);
		else this.coreLight.color.setHex(0xc084fc);
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
		this.ringMesh.rotation.set(this.flowerGroup.rotation.x * 0.45, this.flowerGroup.rotation.y * 0.45, this.ringRot);
		this.ringTrackMesh.rotation.copy(this.ringMesh.rotation);

		// Update ambient pollen motes
		this.updatePollen(dt, t);
		this.updateBursts(dt);
	}

	private updatePollen(dt: number, t: number) {
		const fillingIdx = Math.min(3, Math.floor(this.progress * 4));
		const activeDir = PETAL_DIRS[PETALS[fillingIdx].name];
		const speedMult = this.mode === "download" ? 1 + this.downloadRate * 0.045 : this.mode === "error" ? 0.25 : 1;

		if (this.mode === "download") {
			this.spawnDebt += this.downloadRate * dt * 0.5;
		}

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
					// Tangential swirl + inward pull
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
			bp.vy -= 1.35 * dt; // soft gravity
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
				this.sparkPos[i * 3 + 2] = -20;
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

		const dom = this.renderer.domElement;
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
