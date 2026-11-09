// super_empty.img: the dynamic partitions' metadata (liblp's format). Only the partition names
// are read, to know which images are logical (flashed from fastbootd, as AOSP fastboot does).

const GEOMETRY_MAGIC = 0x616c4467;
const GEOMETRY_SIZE = 4096;
const HEADER_MAGIC = 0x414c5030;
const PARTITION_ENTRY_MIN = 52;

/** The logical partitions super_empty.img lists (with their slot suffixes), or null if unreadable. */
export function logicalPartitions(bytes: Uint8Array): string[] | null {
	const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	// The image starts with the geometry block (ReadFromImageBlob); allow a reserved block first
	for (const geo of [0, 4096]) {
		if (geo + GEOMETRY_SIZE + 128 > bytes.byteLength) continue;
		if (v.getUint32(geo, true) !== GEOMETRY_MAGIC) continue;
		const h = geo + GEOMETRY_SIZE;
		if (v.getUint32(h, true) !== HEADER_MAGIC) return null;
		const major = v.getUint16(h + 4, true);
		const headerSize = v.getUint32(h + 8, true);
		if (major !== 10 || headerSize < 128) return null;
		const tables = h + headerSize;
		const offset = v.getUint32(h + 80, true);
		const count = v.getUint32(h + 84, true);
		const entrySize = v.getUint32(h + 88, true);
		if (entrySize < PARTITION_ENTRY_MIN || count > 4096) return null;
		const names: string[] = [];
		for (let i = 0; i < count; i++) {
			const e = tables + offset + i * entrySize;
			if (e + 36 > bytes.byteLength) return null;
			let name = "";
			for (let j = 0; j < 36; j++) {
				const c = bytes[e + j];
				if (c === 0) break;
				name += String.fromCharCode(c);
			}
			if (!/^[A-Za-z0-9_]+$/.test(name)) return null;
			names.push(name);
		}
		return names;
	}
	return null;
}

/** Whether a partition (base name, e.g. "system") is one of super_empty.img's logical partitions. */
export function isLogical(names: string[], partition: string): boolean {
	return names.some((n) => n === partition || n === `${partition}_a` || n === `${partition}_b`);
}
