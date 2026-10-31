import { defineConfig } from "vitest/config";

// The unit tests run in Node, without the Cloudflare plugin (vite.config.ts is for the site)
export default defineConfig({
	test: {
		include: ["test/**/*.test.ts"],
		environment: "node",
		testTimeout: 30_000,
	},
});
