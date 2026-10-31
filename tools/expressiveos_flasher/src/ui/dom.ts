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
