// The browser's private storage (OPFS, with sync access handles) and Web Locks, in memory, for
// the store's and the download worker's tests. Every "tab" of a test shares the one instance, as
// tabs of a site share the browser's.

type LockMode = "shared" | "exclusive";

/** navigator.locks: shared and exclusive locks by name, ifAvailable, and query(). */
export class FakeLocks {
	held: Array<{ name: string; mode: LockMode }> = [];
	private waiting: Array<{ name: string; mode: LockMode; can: () => boolean; grant: () => void }> = [];

	async request<T>(
		name: string,
		optsOrCb: { mode?: LockMode; ifAvailable?: boolean } | ((lock: { name: string; mode: LockMode } | null) => T | Promise<T>),
		maybeCb?: (lock: { name: string; mode: LockMode } | null) => T | Promise<T>,
	): Promise<T> {
		const opts = typeof optsOrCb === "function" ? {} : optsOrCb;
		const cb = typeof optsOrCb === "function" ? optsOrCb : maybeCb!;
		const mode = opts.mode ?? "exclusive";
		const can = () => !this.held.some((l) => l.name === name && (mode === "exclusive" || l.mode === "exclusive"));
		await Promise.resolve(); // the callback never runs inside request(), as in a browser
		if (!can()) {
			if (opts.ifAvailable) return cb(null);
			await new Promise<void>((grant) => this.waiting.push({ name, mode, can, grant }));
		}
		const lock = { name, mode };
		this.held.push(lock);
		try {
			return await cb(lock);
		} finally {
			this.held.splice(this.held.indexOf(lock), 1);
			for (const w of [...this.waiting]) {
				if (w.can()) {
					this.waiting.splice(this.waiting.indexOf(w), 1);
					w.grant();
				}
			}
		}
	}

	async query() {
		return { held: this.held.map((l) => ({ ...l })), pending: this.waiting.map(({ name, mode }) => ({ name, mode })) };
	}
}

const notFound = () => new DOMException("A requested file or directory could not be found.", "NotFoundError");

class FakeSyncHandle {
	closed = false;

	constructor(private readonly file: FakeFileHandle) {}

	getSize() {
		return this.file.data.byteLength;
	}

	read(buf: Uint8Array, opts: { at: number }) {
		this.file.onRead?.();
		const part = this.file.data.subarray(opts.at, opts.at + buf.byteLength);
		buf.set(part);
		return part.byteLength;
	}

	write(buf: Uint8Array, opts: { at: number }) {
		const end = opts.at + buf.byteLength;
		if (end > this.file.data.byteLength) {
			const grown = new Uint8Array(end);
			grown.set(this.file.data);
			this.file.data = grown;
		}
		this.file.data.set(buf, opts.at);
		return buf.byteLength;
	}

	truncate(n: number) {
		this.file.truncations.push(n);
		const next = new Uint8Array(n);
		next.set(this.file.data.subarray(0, n));
		this.file.data = next;
	}

	flush() {}

	close() {
		this.closed = true;
		this.file.sync = null;
	}
}

export class FakeFileHandle {
	readonly kind = "file";
	data: Uint8Array = new Uint8Array(0);
	sync: FakeSyncHandle | null = null;
	/** Every truncate(n) on it. */
	truncations: number[] = [];
	/** Called on each sync read (to make reads slow). */
	onRead?: () => void;

	constructor(readonly name: string) {}

	async getFile(): Promise<File> {
		return new File([this.data.slice()], this.name);
	}

	async createSyncAccessHandle(): Promise<FakeSyncHandle> {
		if (this.sync) throw new DOMException("Access Handles cannot be created if there is another open Access Handle", "NoModificationAllowedError");
		this.sync = new FakeSyncHandle(this);
		return this.sync;
	}
}

export class FakeDirectory {
	readonly kind = "directory";
	files = new Map<string, FakeFileHandle>();
	dirs = new Map<string, FakeDirectory>();

	async getDirectoryHandle(name: string, opts: { create?: boolean } = {}): Promise<FakeDirectory> {
		let d = this.dirs.get(name);
		if (!d) {
			if (!opts.create) throw notFound();
			d = new FakeDirectory();
			this.dirs.set(name, d);
		}
		return d;
	}

	async getFileHandle(name: string, opts: { create?: boolean } = {}): Promise<FakeFileHandle> {
		let f = this.files.get(name);
		if (!f) {
			if (!opts.create) throw notFound();
			f = new FakeFileHandle(name);
			this.files.set(name, f);
		}
		return f;
	}

	async removeEntry(name: string) {
		const f = this.files.get(name);
		if (!f) throw notFound();
		if (f.sync) throw new DOMException("An attempt was made to modify an object where modifications are not allowed.", "NoModificationAllowedError");
		this.files.delete(name);
	}

	async *entries(): AsyncIterable<[string, FakeFileHandle]> {
		for (const e of [...this.files.entries()]) yield e;
	}

	/** Puts a file in place, with a .ok marker when it's a finished download. */
	put(name: string, data: Uint8Array, complete: boolean) {
		const f = new FakeFileHandle(name);
		f.data = data;
		this.files.set(name, f);
		if (complete) this.files.set(`${name}.ok`, new FakeFileHandle(`${name}.ok`));
		return f;
	}
}

/** A navigator with the storage and locks above (and nothing else). */
export function fakeNavigator() {
	const root = new FakeDirectory();
	const locks = new FakeLocks();
	const navigator = {
		locks,
		storage: {
			getDirectory: async () => root,
			persist: async () => true,
			estimate: async () => ({ quota: 1e12, usage: 0 }),
		},
	};
	return { root, locks, navigator, releases: () => root.getDirectoryHandle("releases", { create: true }) };
}
