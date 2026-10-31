import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// The unit tests run in Node, without the Cloudflare plugin (vite.config.ts is for the site)
export default defineConfig({
	resolve: {
		// worker/index.ts's runtime module, for test/worker.test.ts (tsconfig.test.json maps it the same way)
		alias: { "cloudflare:workers": fileURLToPath(new URL("./test/cloudflare-workers-stub.ts", import.meta.url)) },
	},
	test: {
		include: ["test/**/*.test.ts"],
		environment: "node",
		testTimeout: 30_000,
	},
});
