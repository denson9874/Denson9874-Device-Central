// Node module hooks for e2e/server.mjs, which runs the real Worker (worker/index.ts) in Node:
// its runtime module "cloudflare:workers" becomes the unit tests' stub, whose env the server
// gives a fixture-folder R2 bucket.

const STUB = new URL("../test/cloudflare-workers-stub.ts", import.meta.url).href;

export async function resolve(specifier, context, next) {
	if (specifier === "cloudflare:workers") return { url: STUB, shortCircuit: true };
	return next(specifier, context);
}
