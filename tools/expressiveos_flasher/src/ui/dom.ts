// A small helper for building the page's DOM. Text always goes in as text, never as HTML.

export type Child = Node | string | number | null | undefined | false;

type Props = {
	class?: string;
	on?: { [K in keyof HTMLElementEventMap]?: (ev: HTMLElementEventMap[K]) => void };
	dataset?: Record<string, string>;
	[attr: string]: unknown;
};

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Props | null = null, ...children: Child[]): HTMLElementTagNameMap[K] {
	const e = document.createElement(tag);
	if (props) {
		for (const [k, v] of Object.entries(props)) {
			if (v === undefined || v === null || v === false) continue;
			if (k === "class") e.className = String(v);
			else if (k === "on") for (const [ev, fn] of Object.entries(v as object)) e.addEventListener(ev, fn as EventListener);
			else if (k === "dataset") Object.assign(e.dataset, v);
			else if (k in e && typeof v !== "string") (e as unknown as Record<string, unknown>)[k] = v;
			else e.setAttribute(k, v === true ? "" : String(v));
		}
	}
	append(e, children);
	return e;
}

export function append(parent: Element | DocumentFragment, children: Child[]) {
	for (const c of children) {
		if (c === null || c === undefined || c === false) continue;
		parent.append(c instanceof Node ? c : String(c));
	}
}

/** A notice box: info, ok, warn or danger. */
export function notice(kind: "info" | "ok" | "warn" | "danger", title: Child, ...body: Child[]): HTMLDivElement {
	const icon = { info: "i", ok: "✓", warn: "!", danger: "!" }[kind];
	return h(
		"div",
		{ class: `notice notice-${kind}`, role: kind === "danger" ? "alert" : null },
		h("span", { class: "notice-icon", "aria-hidden": "true" }, icon),
		h("div", { class: "notice-body" }, title ? h("strong", null, title) : null, ...body.map((b) => (typeof b === "string" ? h("p", null, b) : b))),
	);
}

export function link(href: string, text: string): HTMLAnchorElement {
	return h("a", { href, target: "_blank", rel: "noopener noreferrer" }, text);
}

/** A progress bar that screen readers can read as well as see; setBar moves it. */
export function progressBar(label: string): HTMLDivElement {
	return h("div", { class: "bar", role: "progressbar", "aria-label": label, "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": "0" }, h("span"));
}

/** Sets a progressBar to a fraction, with an optional reading of it (such as "2.1 GB of 6.0 GB"). */
export function setBar(bar: HTMLElement, fraction: number, text?: string) {
	const pct = Math.max(0, Math.min(1, fraction)) * 100;
	(bar.firstElementChild as HTMLElement).style.width = `${pct}%`;
	const now = String(Math.floor(pct));
	if (bar.getAttribute("aria-valuenow") !== now) bar.setAttribute("aria-valuenow", now);
	if (text) bar.setAttribute("aria-valuetext", `${now}%, ${text}`);
	else bar.removeAttribute("aria-valuetext");
}

/** Whether a node is inside root (and so on the page with it). */
export function inside(node: Node, root: Node): boolean {
	for (let n: Node | null = node; n; n = n.parentNode) if (n === root) return true;
	return false;
}

/** Whether the keyboard can go to an element inside root: there, not hidden, not disabled. */
export function canFocus(e: Element, root: Element): boolean {
	if ((e as HTMLButtonElement).disabled) return false;
	for (let n: Node | null = e; n; n = n.parentNode) {
		if (n === root) return true;
		if ((n as HTMLElement).hidden) return false;
	}
	return false;
}

/**
 * A name for a control that stays the same when the panel is drawn again, so the keyboard can
 * go back to it: its data-focus, a choice's group and value, or a button's text. Null for an
 * element that isn't a control.
 */
export function focusKey(e: Element): string | null {
	const el = e as HTMLElement;
	if (el.dataset?.focus) return el.dataset.focus;
	const tag = el.tagName.toLowerCase();
	if (tag === "input") return `input:${el.getAttribute("type")}:${el.getAttribute("name")}:${el.getAttribute("value")}`;
	if (tag === "button" || tag === "a" || tag === "summary" || el.getAttribute("tabindex") !== null) return `${tag}:${el.textContent}`;
	return null;
}
