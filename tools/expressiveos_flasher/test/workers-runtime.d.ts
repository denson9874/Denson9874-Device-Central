// The Workers runtime types worker/index.ts uses, for the unit tests' program (tsconfig.test.json).
// tsconfig.worker.json checks the Worker against the real ones (.cloudflare/types, which
// `cf workers types` writes), but they can't be loaded beside src: they replace the DOM's globals.
// These are those declarations cut down to what the Worker touches, so that a Worker change using
// more of R2 fails here until test/worker.test.ts's fake bucket does it too.

interface R2Bucket {
	head(key: string): Promise<R2Object | null>;
	get(key: string, options?: R2GetOptions): Promise<R2ObjectBody | null>;
}

interface R2Object {
	readonly key: string;
	readonly size: number;
	readonly etag: string;
	readonly httpEtag: string;
	readonly uploaded: Date;
	readonly range?: R2Range;
	writeHttpMetadata(headers: Headers): void;
}

interface R2ObjectBody extends R2Object {
	get body(): ReadableStream;
	text(): Promise<string>;
}

type R2Range = { offset: number; length?: number } | { offset?: number; length: number } | { suffix: number };

interface R2Conditional {
	etagMatches?: string;
	etagDoesNotMatch?: string;
	uploadedBefore?: Date;
	uploadedAfter?: Date;
	secondsGranularity?: boolean;
}

interface R2GetOptions {
	onlyIf?: R2Conditional | Headers;
	range?: R2Range | Headers;
}

interface ExportedHandler {
	fetch?: (request: Request, env: unknown, ctx: unknown) => Response | Promise<Response>;
}
