// Writing the dynamic partitions straight into super from the bootloader, as AOSP fastboot does
// whenever it can (OptimizedFlashSuperTask in task.cpp, SuperFlashHelper, and liblp's
// SuperLayoutBuilder and MetadataBuilder): super_empty.img's metadata gets an extent for each
// partition written, and one sparse image of super holds the geometry, every metadata slot and the
// partition images. The phone never has to restart into fastbootd.

import { CHUNK_HEADER_SIZE, type Chunk, ChunkType, FILE_HEADER_SIZE, type SparseHeader, parseSparseHeader } from "./sparse.ts";

const SECTOR = 512; // LP_SECTOR_SIZE
const RESERVED = 4096; // LP_PARTITION_RESERVED_BYTES
const GEOMETRY_SIZE = 4096; // LP_METADATA_GEOMETRY_SIZE
const GEOMETRY_MAGIC = 0x616c4467;
const GEOMETRY_STRUCT = 52;
const HEADER_MAGIC = 0x414c5030;
const HEADER_V1_0 = 128;
const HEADER_V1_2 = 256;
const EXPANDED_HEADER = 2; // LP_METADATA_VERSION_FOR_EXPANDED_HEADER
const UPDATED_ATTR = 1; // LP_METADATA_VERSION_FOR_UPDATED_ATTR
const PARTITION_ENTRY = 52;
const EXTENT_ENTRY = 24;
const GROUP_ENTRY = 48;
const BLOCK_DEVICE_ENTRY = 64;
const ATTR_READONLY = 1;
const ATTR_SLOT_SUFFIXED = 2;
const ATTR_MASK_V1 = 4 | 8; // UPDATED | DISABLED
const ATTR_MASK = 1 | 2 | 4 | 8;
/** libsparse alignment for the metadata copies (SuperLayoutBuilder::GetImageLayout). */
const SPARSE_ALIGNMENT = 4096;

/** Why super can't be written from the bootloader; the install then goes through fastbootd. */
export class SuperLayoutError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "SuperLayoutError";
	}
}

interface Geometry {
	metadataMaxSize: number;
	slotCount: number;
	logicalBlockSize: number;
}
interface BlockDevice {
	firstLogicalSector: number;
	alignment: number;
	alignmentOffset: number;
	size: number;
	name: Uint8Array; // 36 bytes, as stored
	flags: number;
}
interface Group {
	name: string;
	maximumSize: number;
}
export interface Extent {
	sectors: number;
	start: number; // physical sector
}
export interface Partition {
	name: string;
	attributes: number;
	group: string;
	extents: Extent[];
}
export interface LpMetadata {
	geometry: Geometry;
	minorVersion: number;
	flags: number;
	partitions: Partition[];
	groups: Group[];
	blockDevices: BlockDevice[];
	/** Partitions that already had extents (never in a super_empty.img). */
	hasExtents: boolean;
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
	return new Uint8Array(await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>));
}

const equal = (a: Uint8Array, b: Uint8Array) => a.byteLength === b.byteLength && a.every((x, i) => x === b[i]);

function u64(v: DataView, at: number): number {
	const n = v.getBigUint64(at, true);
	if (n > BigInt(Number.MAX_SAFE_INTEGER)) throw new SuperLayoutError("super_empty.img has a size too big to work with");
	return Number(n);
}

function cString(bytes: Uint8Array, at: number, len: number): string {
	let s = "";
	for (let i = 0; i < len && bytes[at + i] !== 0; i++) s += String.fromCharCode(bytes[at + i]);
	return s;
}

/** Reads super_empty.img (ReadFromImageBlob: geometry first, metadata right after), checksums included. */
export async function readLpMetadata(bytes: Uint8Array): Promise<LpMetadata> {
	const bad = (why: string) => new SuperLayoutError(`super_empty.img isn't valid: ${why}`);
	if (bytes.byteLength < GEOMETRY_SIZE + HEADER_V1_0) throw bad("too short");
	const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	// ParseGeometry
	if (v.getUint32(0, true) !== GEOMETRY_MAGIC) throw bad("no geometry");
	if (v.getUint32(4, true) !== GEOMETRY_STRUCT) throw bad("unknown geometry size");
	const geo = bytes.slice(0, GEOMETRY_STRUCT);
	geo.fill(0, 8, 40);
	if (!equal(await sha256(geo), bytes.subarray(8, 40))) throw bad("geometry checksum");
	const geometry: Geometry = { metadataMaxSize: v.getUint32(40, true), slotCount: v.getUint32(44, true), logicalBlockSize: v.getUint32(48, true) };
	if (geometry.slotCount === 0) throw bad("no metadata slots");
	if (geometry.metadataMaxSize % SECTOR !== 0) throw bad("metadata size not sector-aligned");
	if (geometry.logicalBlockSize === 0 || geometry.logicalBlockSize % SECTOR !== 0) throw bad("bad logical block size");

	// ReadMetadataHeader
	const h = GEOMETRY_SIZE;
	if (v.getUint32(h, true) !== HEADER_MAGIC) throw bad("no metadata header");
	const major = v.getUint16(h + 4, true);
	const minor = v.getUint16(h + 6, true);
	if (major !== 10 || minor > 2) throw bad(`metadata version ${major}.${minor}`);
	const headerSize = v.getUint32(h + 8, true);
	if (headerSize !== (minor >= EXPANDED_HEADER ? HEADER_V1_2 : HEADER_V1_0)) throw bad("metadata header size");
	if (h + headerSize > bytes.byteLength) throw bad("too short");
	const header = bytes.slice(h, h + headerSize);
	header.fill(0, 12, 44);
	if (!equal(await sha256(header), bytes.subarray(h + 12, h + 44))) throw bad("metadata header checksum");
	const tablesSize = v.getUint32(h + 44, true);
	if (tablesSize > geometry.metadataMaxSize) throw bad("tables too big");
	const t = h + headerSize;
	if (t + tablesSize > bytes.byteLength) throw bad("tables cut short");
	if (!equal(await sha256(bytes.subarray(t, t + tablesSize)), bytes.subarray(h + 48, h + 80))) throw bad("tables checksum");
	const table = (i: number, entry: number) => {
		const offset = v.getUint32(h + 80 + i * 12, true);
		const count = v.getUint32(h + 84 + i * 12, true);
		const size = v.getUint32(h + 88 + i * 12, true);
		if (size !== entry) throw bad("table entry size");
		if (offset > tablesSize || tablesSize - offset < count * size) throw bad("table bounds");
		return { at: t + offset, count };
	};
	const pt = table(0, PARTITION_ENTRY);
	const et = table(1, EXTENT_ENTRY);
	const gt = table(2, GROUP_ENTRY);
	const bt = table(3, BLOCK_DEVICE_ENTRY);
	const flags = minor >= EXPANDED_HEADER ? v.getUint32(h + 128, true) : 0;

	const groups: Group[] = [];
	for (let i = 0; i < gt.count; i++) {
		const e = gt.at + i * GROUP_ENTRY;
		groups.push({ name: cString(bytes, e, 36), maximumSize: u64(v, e + 40) });
	}
	const extents: Array<{ sectors: number; type: number; data: number; source: number }> = [];
	for (let i = 0; i < et.count; i++) {
		const e = et.at + i * EXTENT_ENTRY;
		extents.push({ sectors: u64(v, e), type: v.getUint32(e + 8, true), data: u64(v, e + 12), source: v.getUint32(e + 20, true) });
	}
	const partitions: Partition[] = [];
	for (let i = 0; i < pt.count; i++) {
		const e = pt.at + i * PARTITION_ENTRY;
		const attributes = v.getUint32(e + 36, true);
		const first = v.getUint32(e + 40, true);
		const count = v.getUint32(e + 44, true);
		const group = v.getUint32(e + 48, true);
		const valid = minor >= UPDATED_ATTR ? ATTR_MASK : ATTR_READONLY | ATTR_SLOT_SUFFIXED;
		if (attributes & ~valid) throw bad("partition attributes");
		if (group >= groups.length) throw bad("partition group");
		if (first + count > extents.length) throw bad("partition extents");
		const own = extents.slice(first, first + count);
		if (own.some((x) => x.type !== 0 || x.source !== 0)) throw bad("partition extents");
		partitions.push({ name: cString(bytes, e, 36), attributes, group: groups[group].name, extents: own.map((x) => ({ sectors: x.sectors, start: x.data })) });
	}
	const blockDevices: BlockDevice[] = [];
	for (let i = 0; i < bt.count; i++) {
		const e = bt.at + i * BLOCK_DEVICE_ENTRY;
		blockDevices.push({
			firstLogicalSector: u64(v, e),
			alignment: v.getUint32(e + 8, true),
			alignmentOffset: v.getUint32(e + 12, true),
			size: u64(v, e + 16),
			name: bytes.slice(e + 24, e + 60),
			flags: v.getUint32(e + 60, true),
		});
	}
	if (!blockDevices.length) throw bad("no block devices");
	return { geometry, minorVersion: minor, flags, partitions, groups, blockDevices, hasExtents: extents.length > 0 };
}

const alignTo = (n: number, alignment: number) => (alignment ? Math.ceil(n / alignment) * alignment : n);

/** MetadataBuilder::AlignSector: up to the device's alignment, in sectors. */
function alignSector(bd: BlockDevice, sector: number): number {
	return alignTo(alignTo(sector * SECTOR, bd.alignment), SECTOR) / SECTOR;
}

/**
 * SuperLayoutBuilder::Open and MetadataBuilder::ResizePartition for each image, in order: each
 * partition gets the first free space, as liblp lays it out on the host (no A/B halving there).
 */
function allocate(meta: LpMetadata, parts: Array<{ name: string; size: number }>): void {
	for (const p of meta.partitions) {
		if (p.attributes & ATTR_SLOT_SUFFIXED) throw new SuperLayoutError("retrofit dynamic partitions aren't supported");
		if (!(p.attributes & ATTR_READONLY)) throw new SuperLayoutError("writable dynamic partitions aren't supported");
	}
	if (meta.hasExtents) throw new SuperLayoutError("super_empty.img already places partitions");
	if (meta.blockDevices.length !== 1) throw new SuperLayoutError("only one super partition is supported");
	const bd = meta.blockDevices[0];
	const perBlock = meta.geometry.logicalBlockSize / SECTOR;
	const sizeOf = (p: Partition) => p.extents.reduce((n, e) => n + e.sectors * SECTOR, 0);

	for (const { name, size } of parts) {
		const p = meta.partitions.find((x) => x.name === name);
		if (!p) throw new SuperLayoutError(`super_empty.img has no ${name}`);
		const aligned = alignTo(size, meta.geometry.logicalBlockSize);
		const old = sizeOf(p);
		if (aligned <= old) {
			if (aligned < old) throw new SuperLayoutError(`${name} is written twice`);
			continue;
		}
		// ValidatePartitionSizeChange: the group's limit
		const group = meta.groups.find((g) => g.name === p.group)!;
		if (group.maximumSize > 0) {
			const used = meta.partitions.filter((x) => x.group === p.group).reduce((n, x) => n + sizeOf(x), 0);
			if (used >= group.maximumSize || group.maximumSize - used < aligned - old) {
				throw new SuperLayoutError(`the ${group.name} group has no room for ${name}`);
			}
		}
		// GetFreeRegions: the gaps between allocated extents, each start aligned
		const taken = meta.partitions.flatMap((x) => x.extents.map((e) => ({ start: e.start, end: e.start + e.sectors })));
		const last = bd.size / SECTOR;
		taken.push({ start: bd.firstLogicalSector, end: bd.firstLogicalSector }, { start: last, end: last });
		taken.sort((a, b) => a.start - b.start || a.end - b.end);
		const free: Array<{ start: number; end: number }> = [];
		for (let i = 1; i < taken.length; i++) {
			const start = alignSector(bd, taken[i - 1].end);
			if (start < taken[i].start) free.push({ start, end: taken[i].start });
		}
		// GrowPartition: first fit, whole blocks only
		let needed = (aligned - old) / SECTOR;
		const added: Extent[] = [];
		for (const r of free) {
			if (!needed) break;
			const len = Math.floor((r.end - r.start) / perBlock) * perBlock;
			if (!len) continue;
			const n = Math.min(needed, len);
			added.push({ sectors: n, start: r.start });
			needed -= n;
		}
		if (needed) throw new SuperLayoutError(`super has no room for ${name}`);
		// Partition::AddExtent merges an extent that carries on from the last one
		for (const e of added) {
			const prev = p.extents[p.extents.length - 1];
			if (prev && prev.start + prev.sectors === e.start) prev.sectors += e.sectors;
			else p.extents.push(e);
		}
	}
}

function geometryBlob(g: Geometry): Promise<Uint8Array> {
	const out = new Uint8Array(GEOMETRY_SIZE);
	const v = new DataView(out.buffer);
	v.setUint32(0, GEOMETRY_MAGIC, true);
	v.setUint32(4, GEOMETRY_STRUCT, true);
	v.setUint32(40, g.metadataMaxSize, true);
	v.setUint32(44, g.slotCount, true);
	v.setUint32(48, g.logicalBlockSize, true);
	return sha256(out.subarray(0, GEOMETRY_STRUCT)).then((sum) => {
		out.set(sum, 8);
		return out;
	});
}

/** MetadataBuilder::Export (as built from super_empty.img's metadata), then SerializeMetadata. */
async function metadataBlob(meta: LpMetadata): Promise<Uint8Array> {
	const enc = new TextEncoder();
	// MetadataBuilder::Init keeps the header flags only from an expanded (1.2) header
	let minor = meta.minorVersion >= EXPANDED_HEADER ? EXPANDED_HEADER : 0;
	const headerSize = minor >= EXPANDED_HEADER ? HEADER_V1_2 : HEADER_V1_0;
	const flags = minor >= EXPANDED_HEADER ? meta.flags : 0;
	const extents = meta.partitions.flatMap((p) => p.extents);
	const partitions = new Uint8Array(meta.partitions.length * PARTITION_ENTRY);
	const pv = new DataView(partitions.buffer);
	let first = 0;
	meta.partitions.forEach((p, i) => {
		const e = i * PARTITION_ENTRY;
		const name = enc.encode(p.name);
		if (name.byteLength > 36) throw new SuperLayoutError(`partition name ${p.name} is too long`);
		partitions.set(name, e);
		if (p.attributes & ATTR_MASK_V1) minor = Math.max(minor, UPDATED_ATTR);
		pv.setUint32(e + 36, p.attributes, true);
		pv.setUint32(e + 40, first, true);
		pv.setUint32(e + 44, p.extents.length, true);
		pv.setUint32(e + 48, meta.groups.findIndex((g) => g.name === p.group), true);
		first += p.extents.length;
	});
	const ext = new Uint8Array(extents.length * EXTENT_ENTRY);
	const ev = new DataView(ext.buffer);
	extents.forEach((x, i) => {
		ev.setBigUint64(i * EXTENT_ENTRY, BigInt(x.sectors), true);
		ev.setUint32(i * EXTENT_ENTRY + 8, 0, true); // LP_TARGET_TYPE_LINEAR
		ev.setBigUint64(i * EXTENT_ENTRY + 12, BigInt(x.start), true);
		ev.setUint32(i * EXTENT_ENTRY + 20, 0, true); // the one block device
	});
	const groups = new Uint8Array(meta.groups.length * GROUP_ENTRY);
	const gv = new DataView(groups.buffer);
	meta.groups.forEach((g, i) => {
		const name = enc.encode(g.name);
		if (name.byteLength > 36) throw new SuperLayoutError(`group name ${g.name} is too long`);
		groups.set(name, i * GROUP_ENTRY);
		gv.setUint32(i * GROUP_ENTRY + 36, 0, true); // flags: AddGroup keeps none
		gv.setBigUint64(i * GROUP_ENTRY + 40, BigInt(g.maximumSize), true);
	});
	const devices = new Uint8Array(meta.blockDevices.length * BLOCK_DEVICE_ENTRY);
	const dv = new DataView(devices.buffer);
	meta.blockDevices.forEach((b, i) => {
		const e = i * BLOCK_DEVICE_ENTRY;
		dv.setBigUint64(e, BigInt(b.firstLogicalSector), true);
		dv.setUint32(e + 8, b.alignment, true);
		dv.setUint32(e + 12, b.alignmentOffset, true);
		dv.setBigUint64(e + 16, BigInt(b.size), true);
		devices.set(b.name, e + 24);
		dv.setUint32(e + 60, b.flags, true);
	});
	const tables = new Uint8Array(partitions.byteLength + ext.byteLength + groups.byteLength + devices.byteLength);
	tables.set(partitions, 0);
	tables.set(ext, partitions.byteLength);
	tables.set(groups, partitions.byteLength + ext.byteLength);
	tables.set(devices, partitions.byteLength + ext.byteLength + groups.byteLength);

	const header = new Uint8Array(headerSize);
	const hv = new DataView(header.buffer);
	hv.setUint32(0, HEADER_MAGIC, true);
	hv.setUint16(4, 10, true);
	hv.setUint16(6, minor, true);
	hv.setUint32(8, headerSize, true);
	hv.setUint32(44, tables.byteLength, true);
	header.set(await sha256(tables), 48);
	const offsets = [0, partitions.byteLength, partitions.byteLength + ext.byteLength, partitions.byteLength + ext.byteLength + groups.byteLength];
	const counts = [meta.partitions.length, extents.length, meta.groups.length, meta.blockDevices.length];
	const sizes = [PARTITION_ENTRY, EXTENT_ENTRY, GROUP_ENTRY, BLOCK_DEVICE_ENTRY];
	for (let i = 0; i < 4; i++) {
		hv.setUint32(80 + i * 12, offsets[i], true);
		hv.setUint32(84 + i * 12, counts[i], true);
		hv.setUint32(88 + i * 12, sizes[i], true);
	}
	if (headerSize === HEADER_V1_2) hv.setUint32(128, flags, true);
	header.set(await sha256(header), 12);

	const out = new Uint8Array(alignTo(headerSize + tables.byteLength, SPARSE_ALIGNMENT));
	out.set(header, 0);
	out.set(tables, headerSize);
	return out;
}

export interface SuperImage {
	/** The super partition's name on the phone. */
	name: string;
	header: SparseHeader;
	chunks: Chunk[];
	/** Each partition written and where: its sectors in super. */
	layout: Array<{ partition: string; start: number; sectors: number }>;
}

/**
 * The sparse image of super that AOSP fastboot's optimized flash sends: super_empty.img's layout
 * with each image given its space, the geometry and metadata copies, and the images themselves.
 * @param parts the images to write, by partition name with its slot suffix ("system_a")
 * @param superSize the super partition's size on the phone (partition-size:super)
 */
export async function buildSuperImage(superEmpty: Uint8Array, parts: Array<{ name: string; blob: Blob }>, superName: string, superSize: number): Promise<SuperImage> {
	const meta = await readLpMetadata(superEmpty);
	for (const p of parts) {
		if (parseSparseHeader(new Uint8Array(await p.blob.slice(0, FILE_HEADER_SIZE).arrayBuffer()))) {
			throw new SuperLayoutError(`${p.name}'s image is sparse`);
		}
	}
	allocate(
		meta,
		parts.map((p) => ({ name: p.name, size: p.blob.size })),
	);
	const bd = meta.blockDevices[0];
	if (!(superSize > 0)) throw new SuperLayoutError("the phone didn't say how big super is");
	if (bd.size > superSize) throw new SuperLayoutError(`super_empty.img is for a super of ${bd.size} bytes, but the phone's is ${superSize}`);

	const g = meta.geometry;
	const geometry = await geometryBlob(g);
	const metadata = await metadataBlob(meta);
	if (metadata.byteLength > g.metadataMaxSize) throw new SuperLayoutError("the partition table is too big for its slot");

	// SuperLayoutBuilder::GetImageLayout: what goes where in super, by byte offset
	type Piece = { offset: number; size: number; fill?: true; data?: Array<Uint8Array | Blob> };
	const pieces: Piece[] = [
		{ offset: 0, size: RESERVED, fill: true },
		{ offset: RESERVED, size: GEOMETRY_SIZE, data: [geometry] },
		{ offset: RESERVED + GEOMETRY_SIZE, size: GEOMETRY_SIZE, data: [geometry] },
	];
	const slotsStart = RESERVED + 2 * GEOMETRY_SIZE;
	for (let i = 0; i < g.slotCount; i++) {
		pieces.push({ offset: slotsStart + g.metadataMaxSize * i, size: metadata.byteLength, data: [metadata] });
		pieces.push({ offset: slotsStart + g.metadataMaxSize * (g.slotCount + i), size: metadata.byteLength, data: [metadata] });
	}
	const layout: SuperImage["layout"] = [];
	for (const p of meta.partitions) {
		const blob = parts.find((x) => x.name === p.name)?.blob;
		if (!blob) continue;
		let at = 0;
		for (const e of p.extents) {
			const size = e.sectors * SECTOR;
			// An image that ends part way through its last block is padded with zeros
			const data: Array<Uint8Array | Blob> = [blob.slice(at, Math.min(at + size, blob.size))];
			const short = size - Math.max(0, Math.min(size, blob.size - at));
			if (short) data.push(new Uint8Array(short));
			pieces.push({ offset: e.start * SECTOR, size, data });
			layout.push({ partition: p.name, start: e.start, sectors: e.sectors });
			at += size;
		}
	}
	pieces.sort((a, b) => a.offset - b.offset);

	const bs = g.logicalBlockSize;
	const chunks: Chunk[] = [];
	let pos = 0;
	for (const p of pieces) {
		if (p.offset < pos) throw new SuperLayoutError("the super layout overlaps itself");
		if (p.offset % bs || p.size % bs) throw new SuperLayoutError("the super layout isn't block-aligned");
		if (p.offset > pos) chunks.push({ type: ChunkType.DontCare, blocks: (p.offset - pos) / bs, data: [], dataSize: 0 });
		if (p.fill) chunks.push({ type: ChunkType.Fill, blocks: p.size / bs, data: [new Uint8Array(4)], dataSize: 4 });
		else chunks.push({ type: ChunkType.Raw, blocks: p.size / bs, data: p.data!, dataSize: p.size });
		pos = p.offset + p.size;
	}
	if (pos > superSize) throw new SuperLayoutError("the images don't fit in super");
	const header: SparseHeader = { blockSize: bs, totalBlocks: pos / bs, totalChunks: chunks.length, fileHeaderSize: FILE_HEADER_SIZE, chunkHeaderSize: CHUNK_HEADER_SIZE };
	return { name: superName, header, chunks, layout };
}
