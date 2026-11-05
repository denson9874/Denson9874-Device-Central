// GitHub -> Telegram: closing or labelling a logged issue answers its post, and a "/reply <text>"
// comment from a REPLY_LOGINS login is posted as a reply. Each answer goes out once.

import { GitHub, Telegram } from "./clients.ts";
import { type BotEnv, type Link, getJSON, putJSON, sameSecret } from "./env.ts";
import { dueDay, parseMarker } from "./format.ts";
import * as say from "./messages.ts";

interface IssuePayload {
	number: number;
	body: string | null;
	state_reason?: string | null;
	labels?: { name: string }[];
	milestone?: { title: string; due_on?: string | null } | null;
	pull_request?: unknown;
}
interface Payload {
	action?: string;
	repository?: { full_name?: string };
	issue?: IssuePayload;
	label?: { name: string };
	comment?: { id: number; body: string; user?: { login?: string } };
}

async function signature(secret: string, body: string): Promise<string> {
	const enc = new TextEncoder();
	const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
	return `sha256=${[...mac].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

export async function handleGitHub(request: Request, env: BotEnv): Promise<Response> {
	const raw = await request.text();
	if (!sameSecret(request.headers.get("X-Hub-Signature-256") ?? "", await signature(env.GITHUB_WEBHOOK_SECRET, raw))) {
		return new Response("Unauthorized", { status: 401 });
	}
	const event = request.headers.get("X-GitHub-Event") ?? "";
	const payload = JSON.parse(raw) as Payload;
	if (event === "ping") return new Response("pong");
	if (payload.repository?.full_name?.toLowerCase() !== env.GITHUB_REPO.toLowerCase()) return new Response("ignored");
	try {
		await handleEvent(event, payload, env);
	} catch (e) {
		// GitHub doesn't resend on its own; the delivery shows as failed under the repo's webhook settings
		console.error(`${event} ${payload.action}:`, String(e));
		return new Response("failed", { status: 500 });
	}
	return new Response("ok");
}

async function handleEvent(event: string, payload: Payload, env: BotEnv): Promise<void> {
	const issue = payload.issue;
	if (!issue || issue.pull_request) return;
	const marker = parseMarker(issue.body);
	if (!marker || String(marker.c) !== env.CHAT_ID) return;
	const tg = new Telegram(env.TELEGRAM_BOT_TOKEN);
	const link: Link = { i: issue.number, k: marker.k, t: marker.t, r: marker.m };
	const milestone = issue.milestone ? { title: issue.milestone.title, due: dueDay(issue.milestone.due_on) } : undefined;

	/** Sends text as a reply to the issue's post, once per key. */
	const send = async (once: string, text: string): Promise<void> => {
		const key = `s/${issue.number}/${once}`;
		if (await getJSON(env.STATE, key)) return;
		const sent = await tg.reply(marker.c, marker.t, marker.m, text);
		await putJSON(env.STATE, key, sent);
		await putJSON(env.STATE, `m/${marker.c}/${sent}`, link); // replies to it join the issue
	};

	if (event === "issue_comment" && payload.action === "created" && payload.comment) {
		const comment = payload.comment;
		const reply = /^\/reply\s+([\s\S]+)$/.exec(comment.body.trim());
		const allowed = env.REPLY_LOGINS.toLowerCase().split(/[\s,]+/).includes((comment.user?.login ?? "").toLowerCase());
		if (!reply || !allowed) return;
		const gh = new GitHub(env.GITHUB_TOKEN, env.GITHUB_REPO);
		try {
			await send(`comment-${comment.id}`, reply[1].trim());
		} catch (e) {
			await gh.reactToComment(comment.id, "confused").catch(() => {});
			throw e;
		}
		await gh.reactToComment(comment.id, "rocket").catch((e) => console.warn(String(e)));
		return;
	}

	if (event !== "issues" || issue.labels?.some((l) => l.name === "no-reply")) return;
	if (payload.action === "closed" && issue.state_reason === "completed") {
		await send("fixed", say.fixed(marker.k, milestone));
	} else if (payload.action === "labeled" && payload.label?.name === "planned") {
		await send("planned", say.planned(marker.k, milestone));
	} else if (payload.action === "labeled" && payload.label?.name === "needs-logs") {
		await send("needs-logs", say.NEEDS_LOGS);
	}
}
