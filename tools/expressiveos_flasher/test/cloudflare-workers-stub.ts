// "cloudflare:workers" for the unit tests, which run worker/index.ts in Node: vitest.config.ts
// aliases the module here, and tsconfig.test.json maps it here too. A test sets env's bindings
// (worker.test.ts gives it a fake R2 bucket) before it calls the Worker.

export const env = {} as { RELEASES: R2Bucket };
