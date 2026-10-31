// The downloads kept in the browser: a tab using one (installing from it, downloading it) holds it,
// so another tab can't remove it, and a Pause pressed before the download worker starts stops it.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { WorkerReply, WorkerRequest } from "../src/store/protocol.ts";
import { StoreError, downloadRelease, hashFile, listStored, openStored, removeStored } from "../src/store/store.ts";
import { type FakeDirectory, fakeNavigator } from "./fake-storage.ts";
import { bytes } from "./helpers.ts";

const NAME = `${"a".repeat(64)}.zip`;
const SIZE = 4096;

/** The download worker: writes the file through a sync access handle once `gate` opens. */
class FakeWorker {
	static made: FakeWorker[] = [];
	static gate: Promise<void> = Promise.resolve();
	static dir: FakeDirectory;
	onmessage: ((ev: MessageEvent<WorkerReply>) => void) | null = null;
	onerror: ((ev: ErrorEvent) => void) | null = null;
	private cancelled = false;

	constructor() {
		FakeWorker.made.push(this);
	}

	postMessage(m: WorkerRequest) {
		if (m.type === "cancel") this.cancelled = true;
		else if (m.type === "download") void this.download(m);
		else this.reply({ type: "done", sha256: "0".repeat(64) });
	}

	private async download(m: Extract<WorkerRequest, { type: "download" }>) {
		const fh = await FakeWorker.dir.getFileHandle(m.name, { create: true });
		const h = await fh.createSyncAccessHandle();
		await FakeWorker.gate;
		if (this.cancelled) {
			h.close();
			this.reply({ type: "error", code: "cancelled", message: "Cancelled" });
			return;
		}
		h.write(bytes(m.size, 5), { at: 0 });
		h.close();
		this.reply({ type: "done", sha256: m.sha256 });
	}

	private reply(m: WorkerReply) {
		setTimeout(() => this.onmessage?.({ data: m } as MessageEvent<WorkerReply>), 0);
	}

	terminate() {}
}

const until = async (cond: () => boolean) => {
	for (let i = 0; i < 200 && !cond(); i++) await new Promise((r) => setTimeout(r, 1));
	expect(cond()).toBe(true);
};

let env: ReturnType<typeof fakeNavigator>;
let dir: FakeDirectory;

beforeEach(async () => {
	env = fakeNavigator();
	dir = await env.releases();
	FakeWorker.made = [];
	FakeWorker.gate = Promise.resolve();
	FakeWorker.dir = dir;
	vi.stubGlobal("navigator", env.navigator);
	vi.stubGlobal("Worker", FakeWorker);
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe("a download another tab is using", () => {
	it("can't be removed while a tab installs from it, and isn't offered as an older download", async () => {
		dir.put(NAME, bytes(SIZE, 1), true);
		// Tab 1 installs from it
		const held = await openStored(NAME, SIZE);
		expect(held?.file.size).toBe(SIZE);
		// Tab 2 offers it as an older download, and tries to remove it
		expect((await listStored()).find((f) => f.name === NAME)).toMatchObject({ complete: true, inUse: true });
		expect(await removeStored(NAME)).toBe(false);
		expect(dir.files.has(NAME)).toBe(true);
		expect(dir.files.has(`${NAME}.ok`)).toBe(true);
		// Tab 1 is done with it
		await held!.release();
		expect((await listStored()).find((f) => f.name === NAME)?.inUse).toBe(false);
		expect(await removeStored(NAME)).toBe(true);
		expect(dir.files.has(NAME)).toBe(false);
		expect(dir.files.has(`${NAME}.ok`)).toBe(false);
	});

	it("is held while it downloads and once it's done, until the tab lets go", async () => {
		let open!: () => void;
		FakeWorker.gate = new Promise<void>((r) => (open = r));
		const p = downloadRelease("https://example.test/a.zip", NAME, SIZE, "b".repeat(64), () => {});
		await until(() => FakeWorker.made.length === 1);
		expect(await removeStored(NAME)).toBe(false);
		open();
		const held = await p;
		expect(held.file.size).toBe(SIZE);
		expect(await removeStored(NAME)).toBe(false);
		await held.release();
		expect(await removeStored(NAME)).toBe(true);
	});

	it("says so when the browser won't remove it (open for writing elsewhere)", async () => {
		const f = dir.put(NAME, bytes(SIZE, 1), false);
		const h = await f.createSyncAccessHandle();
		expect(await removeStored(NAME)).toBe(false);
		expect(dir.files.has(NAME)).toBe(true);
		h.close();
		expect(await removeStored(NAME)).toBe(true);
	});

	it("finds nothing to open when it isn't finished", async () => {
		dir.put(NAME, bytes(SIZE, 1), false);
		expect(await openStored(NAME, SIZE)).toBeNull();
		// and holds nothing then
		expect(env.locks.held).toEqual([]);
	});
});

describe("pausing", () => {
	it("stops a download paused before its worker starts", async () => {
		let persisted!: (v: boolean) => void;
		env.navigator.storage.persist = () => new Promise<boolean>((r) => (persisted = r));
		const ac = new AbortController();
		const p = downloadRelease("https://example.test/a.zip", NAME, SIZE, "b".repeat(64), () => {}, ac.signal);
		await until(() => persisted !== undefined);
		ac.abort(); // Pause, pressed right after Download
		persisted(true);
		const err = await p.catch((e) => e);
		expect(err).toBeInstanceOf(StoreError);
		expect((err as StoreError).code).toBe("cancelled");
		expect(FakeWorker.made).toEqual([]);
		// and lets go of the file
		expect(env.locks.held).toEqual([]);
	});

	it("doesn't start a check that was cancelled already", async () => {
		const ac = new AbortController();
		ac.abort();
		const err = await hashFile(new File([bytes(16, 1)], "x.zip"), () => {}, ac.signal).catch((e) => e);
		expect((err as StoreError).code).toBe("cancelled");
		expect(FakeWorker.made).toEqual([]);
	});
});
