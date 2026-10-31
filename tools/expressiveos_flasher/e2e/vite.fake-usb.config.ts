import { defineConfig } from "vite";

// Bundles e2e/fake-usb.ts into one script the browser tests inject before the page loads
export default defineConfig({
	configFile: false,
	publicDir: false,
	build: {
		lib: { entry: "e2e/fake-usb.ts", formats: ["iife"], name: "FakeUsb", fileName: () => "fake-usb.js" },
		outDir: "e2e/out",
		emptyOutDir: false,
		minify: false,
		sourcemap: false,
	},
});
