// What a bootloader does with a sparse image (no Node APIs: the browser tests use it too).

/**
 * Writes a sparse image onto a partition's bytes, as a bootloader does; blocks it doesn't cover
 * are left as they were. Returns the block indexes written.
 */
export function applySparse(img: Uint8Array, target: Uint8Array): number[] {
	const v = new DataView(img.buffer, img.byteOffset, img.byteLength);
	if (v.getUint32(0, true) !== 0xed26ff3a) throw new Error("not sparse");
	const fhs = v.getUint16(8, true);
	const chs = v.getUint16(10, true);
	const bs = v.getUint32(12, true);
	const total = v.getUint32(16, true);
	const count = v.getUint32(20, true);
	if (total * bs > target.byteLength) throw new Error(`image of ${total * bs} bytes doesn't fit ${target.byteLength}`);
	let p = fhs;
	let block = 0;
	const written: number[] = [];
	for (let i = 0; i < count; i++) {
		const type = v.getUint16(p, true);
		const blocks = v.getUint32(p + 4, true);
		const size = v.getUint32(p + 8, true);
		const data = p + chs;
		if (type === 0xcac1) {
			if (size - chs !== blocks * bs) throw new Error("raw chunk size");
			target.set(img.subarray(data, data + blocks * bs), block * bs);
			for (let b = 0; b < blocks; b++) written.push(block + b);
			block += blocks;
		} else if (type === 0xcac2) {
			const fill = img.subarray(data, data + 4);
			for (let b = 0; b < blocks; b++) {
				for (let k = 0; k < bs; k += 4) target.set(fill, (block + b) * bs + k);
				written.push(block + b);
			}
			block += blocks;
		} else if (type === 0xcac3) {
			block += blocks;
		} else if (type !== 0xcac4) {
			throw new Error(`bad chunk ${type.toString(16)}`);
		}
		p += size;
	}
	if (p !== img.byteLength) throw new Error(`sparse image has ${img.byteLength - p} bytes left over`);
	if (block !== total) throw new Error(`chunks cover ${block} blocks, header says ${total}`);
	return written;
}
