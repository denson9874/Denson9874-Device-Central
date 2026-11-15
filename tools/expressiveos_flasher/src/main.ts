import "./ui/styles.css";
import { App } from "./ui/app.ts";
import { showWelcome } from "./ui/welcome.ts";

new App();
showWelcome();

// The background aura (three.js, shared with the 3D flower's chunk) after first paint: the CSS
// gradient is the background until then
requestAnimationFrame(() =>
	requestAnimationFrame(() => {
		void import("./ui/aura-scene.ts").then((m) => m.Aura.mount()).catch(() => {});
	}),
);
