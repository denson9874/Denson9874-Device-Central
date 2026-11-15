import "./ui/styles.css";
import { App } from "./ui/app.ts";
import { Aura } from "./ui/aura.ts";
import { showWelcome } from "./ui/welcome.ts";

Aura.mount();
new App();
showWelcome();
