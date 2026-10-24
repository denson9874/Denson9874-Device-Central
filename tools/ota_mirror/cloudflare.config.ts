import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "ota-mirror",
		compatibilityDate: "2026-10-06",
		entrypoint,
		workersDev: true,
		env: {
			OTA: bindings.r2({ name: "denson9874-ota" }),
		},
	},
});
