import { cloudflare } from "@cloudflare/vite-plugin";
import { defineConfig } from "vite";

export default defineConfig({
	plugins: [cloudflare()],
	worker: { format: "es" },
	build: { target: "es2022", sourcemap: true },
});
