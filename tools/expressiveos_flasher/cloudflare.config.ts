import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./worker/index.ts" with { type: "cf-worker" };

// The ExpressiveOS web flasher: the page (Vite's build, as static assets) and a Worker that reads
// the release manifests and files flasher_publish.py puts in R2. Deploy with `npm run deploy`.
export default defineConfig({
	worker: {
		name: "expressiveos-flash",
		compatibilityDate: "2026-10-06",
		entrypoint,
		workersDev: true,
		assets: {
			// Every other path is the page (one page; the steps are in its own state)
			notFoundHandling: "single-page-application",
			runWorkerFirst: ["/api/*", "/dl/*"],
		},
		env: {
			// The same bucket the OTA mirror serves (tools/ota_mirror); this reads expressiveos/*/flasher* only
			RELEASES: bindings.r2({ name: "denson9874-ota" }),
		},
	},
});
