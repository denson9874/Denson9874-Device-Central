// Messages between the page and the download worker.

export type WorkerRequest =
	| { type: "download"; url: string; name: string; size: number; sha256: string }
	| { type: "hash"; file: File }
	| { type: "crc"; file: File; entries: Array<{ name: string; offset: number; size: number; crc32: number }> }
	| { type: "cancel" };

export type WorkerPhase = "checking" | "downloading" | "verifying" | "hashing";

export type WorkerReply =
	| { type: "progress"; phase: WorkerPhase; done: number; total: number }
	| { type: "retrying"; attempt: number; reason: string }
	| { type: "done"; sha256?: string; bad?: string[] }
	| { type: "error"; code: "quota" | "network" | "mismatch" | "http" | "busy" | "cancelled" | "other"; message: string };
