import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import worker from "../src/index.ts";
import { BUGS, CHAT, IDEAS, World, githubRequest, post, telegramRequest } from "./world.ts";

let world: World;
beforeEach(() => {
	world = new World().install();
});
afterEach(() => world.uninstall());

const send = (update: Record<string, unknown>, secret?: string, id?: number) => worker.fetch(telegramRequest(update, secret, id), world.env);
const hook = async (event: string, payload: Record<string, unknown>, secret?: string) => worker.fetch(await githubRequest(event, payload, secret), world.env);

test("a bug post becomes an issue, gets 👀, and an ask for what's missing", async () => {
	const msg = post(BUGS, { caption: "Wi-Fi calling never turns on on my Pixel 7 Pro", photo: [{ file_id: "small" }, { file_id: "big", file_size: 2 }] });
	const res = await send({ message: msg });
	assert.equal(res.status, 200);

	const issue = world.issues.get(1)!;
	assert.equal(issue.title, "Wi-Fi calling never turns on on my Pixel 7 Pro");
	assert.deepEqual(issue.labels, ["bug", "phone:cheetah"]);
	assert.match(issue.body, /^> Wi-Fi calling never turns on/);
	assert.match(issue.body, /📎 \[photo\.jpg\]\(https:\/\/github\.com\/denson9874\/expressiveos-feedback\/blob\/HEAD\/attachments\/2026-11-05\/\d+-photo\.jpg\)/);
	assert.match(issue.body, /\*\*From:\*\* \*\*Ashray\*\* \(@​ashray\) · \[Open in Telegram\]\(https:\/\/t\.me\/ExpressiveLauncherFeedback\/753\/\d+\)/);
	assert.match(issue.body, /\*\*Posted:\*\* Nov 5, 2026, 4:30 AM ET/);
	assert.match(issue.body, /\*\*Missing from the post:\*\* build, log/);
	assert.match(issue.body, /<!-- tg:\{"c":-1004427242312,"t":753,"m":\d+,"k":"bug"\} -->$/);
	assert.equal(world.files.size, 1);
	assert.equal(world.tg("getFile")[0].body.file_id, "big");

	assert.deepEqual(world.tg("setMessageReaction")[0].body.reaction, [{ type: "emoji", emoji: "👀" }]);
	const ask = world.tg("sendMessage")[0].body;
	assert.equal(ask.message_thread_id, BUGS);
	assert.equal(ask.reply_parameters.message_id, msg.message_id);
	assert.match(ask.text, /^Thanks, logged as #1\. To fix it we also need:\n• your build date .*\n• a log taken right after/);
	assert.doesNotMatch(ask.text, /phone model/);
});

test("a complete bug report gets no ask", async () => {
	await send({ message: post(BUGS, { text: "cheetah, Nov 3 build: Bluetooth audio stutters", document: { file_id: "log", file_name: "log.txt", file_size: 2 } }) });
	assert.equal(world.issues.size, 1);
	assert.equal(world.tg("sendMessage").length, 0);
});

test("replies, replies to the bot's ask, and album items join the same issue", async () => {
	const first = post(BUGS, { text: "the clock vanishes after a reboot", media_group_id: "album1", photo: [{ file_id: "p1", file_size: 2 }] });
	await send({ message: first });
	const askId = world.nextMessage - 1;

	await send({ message: post(BUGS, { media_group_id: "album1", photo: [{ file_id: "p2", file_size: 2 }] }) });
	await send({ message: post(BUGS, { text: "same here", from: { id: 7, first_name: "Igor" }, reply_to_message: { message_id: first.message_id, chat: { id: CHAT } } }) });
	await send({ message: post(BUGS, { text: "Pixel 8 Pro, 20261103", reply_to_message: { message_id: askId, chat: { id: CHAT } } }) });

	assert.equal(world.issues.size, 1);
	const comments = world.issues.get(1)!.comments;
	assert.equal(comments.length, 3);
	assert.match(comments[0], /^💬 \*\*Ashray\*\* .* added .*\n\n📎 \[photo\.jpg\]/);
	assert.match(comments[1], /^💬 \*\*Igor\*\* replied · \[Open in Telegram\]/);
	assert.match(comments[1], /\n\n> same here$/);
	assert.match(comments[2], /> Pixel 8 Pro, 20261103/);
});

test("a retried update isn't logged twice", async () => {
	world.failing.add("setMessageReaction"); // best effort, doesn't fail the update
	world.failing.add("POST issues");
	const update = { message: post(IDEAS, { text: "Add a battery percentage inside the icon" }) };
	assert.equal((await send(update, undefined, 777)).status, 500);
	world.failing.clear();
	assert.equal((await send(update, undefined, 777)).status, 200);
	assert.equal((await send(update, undefined, 777)).status, 200);
	assert.equal(world.issues.size, 1);
	assert.deepEqual(world.issues.get(1)!.labels, ["idea"]);
	assert.equal(world.tg("sendMessage").length, 0, "ideas get no ask");
});

test("a failing attachment is skipped from the third try, so the report still gets in", async () => {
	world.failing.add("getFile");
	const update = { message: post(BUGS, { text: "screen flickers", document: { file_id: "x", file_name: "log.txt", file_size: 2 } }) };
	assert.equal((await send(update, undefined, 778)).status, 500);
	assert.equal((await send(update, undefined, 778)).status, 500);
	assert.equal((await send(update, undefined, 778)).status, 200);
	assert.match(world.issues.get(1)!.body, /⚠️ The bot couldn't save log\.txt \(0\.00 MB\)\./);
});

test("too-big files are noted, not downloaded", async () => {
	await send({ message: post(BUGS, { text: "bugreport attached", document: { file_id: "a", file_name: "bugreport.zip", file_size: 30 * 1048576 } }) });
	await send({ message: post(BUGS, { text: "another", document: { file_id: "huge", file_name: "big.zip" } }) });
	assert.match(world.issues.get(1)!.body, /⚠️ bugreport\.zip \(30\.0 MB\) is too big for the bot: ask for a link\./);
	assert.match(world.issues.get(2)!.body, /⚠️ big\.zip is too big for the bot/);
	assert.equal(world.files.size, 0);
});

test("ignored: other topics, chatter, commands, bots, other chats, a bad secret", async () => {
	await send({ message: post(755, { text: "how do I flash this?" }) });
	await send({ message: post(BUGS, { text: "thanks!" }) });
	await send({ message: post(BUGS, { text: "/bug" }) });
	await send({ message: post(BUGS, { text: "a bot post", from: { id: 5, is_bot: true, first_name: "Rose" } }) });
	await send({ message: { ...post(BUGS, { text: "elsewhere" }), chat: { id: -1001, type: "supergroup" } } });
	assert.equal((await send({ message: post(BUGS, { text: "x" }) }, "wrong")).status, 401);
	assert.equal(world.issues.size, 0);
	assert.equal(world.calls.length, 0);
});

test("/track: admins log any message, others are ignored", async () => {
	world.admins.add(1);
	const target = post(755, { text: "Now Playing never finds songs on my 8 Pro", from: { id: 9, first_name: "Lee" } });
	const reply = { message_id: target.message_id, date: target.date, chat: target.chat, from: target.from, text: target.text };
	await send({ message: post(755, { text: "/track", from: { id: 2, first_name: "Member" }, reply_to_message: reply }) });
	assert.equal(world.issues.size, 0);

	await send({ message: post(755, { text: "/track@ExpressiveFeedbackBot", from: { id: 1, first_name: "Daryl" }, reply_to_message: reply }) });
	const issue = world.issues.get(1)!;
	assert.deepEqual(issue.labels, ["bug", "phone:husky"]);
	assert.match(issue.body, /\*\*From:\*\* \*\*Lee\*\*/);
	assert.match(issue.body, /\*\*Topic:\*\* topic 755/);
	assert.match(issue.body, /\*\*Logged by:\*\* \*\*Daryl\*\* with \/track/);
	assert.match(world.tg("sendMessage").at(-1)!.body.text, /^Logged as #1 \(bug\)\.$/);

	await send({ message: post(755, { text: "/track idea", from: { id: 1, first_name: "Daryl" }, reply_to_message: reply }) });
	assert.equal(world.issues.size, 1);
	assert.equal(world.tg("sendMessage").at(-1)!.body.text, "Already logged as #1.");
});

test("👍 on a logged idea counts as a vote", async () => {
	const idea = post(IDEAS, { text: "Material You icon shapes" });
	await send({ message: idea });
	const react = (old: string[], now: string[]) =>
		send({
			message_reaction: {
				chat: idea.chat,
				message_id: idea.message_id,
				user: { id: 3 },
				date: idea.date,
				old_reaction: old.map((emoji) => ({ type: "emoji", emoji })),
				new_reaction: now.map((emoji) => ({ type: "emoji", emoji })),
			},
		});
	await react([], ["👍"]);
	await react([], ["👍", "🔥"]);
	await react(["👍"], ["🔥"]);
	await react([], ["❤"]);
	assert.match(world.issues.get(1)!.body, /\*\*👍 votes:\*\* 1\n<!-- tg:/);
});

test("a private message gets a pointer to the chat", async () => {
	await send({ message: { message_id: 1, date: 0, chat: { id: 55, type: "private" }, from: { id: 55, first_name: "X" }, text: "/start" } });
	assert.match(world.tg("sendMessage")[0].body.text, /Bugs or Ideas topic of Expressive Group Chat/);
	assert.equal(world.issues.size, 0);
});

async function loggedBug(text = "Wi-Fi drops on my 7 Pro, build 1.0, log: https://pastebin.com/x") {
	const msg = post(BUGS, { text });
	await send({ message: msg });
	const issue = world.issues.get(1)!;
	world.calls = [];
	return { msg, payload: { number: 1, body: issue.body, labels: [{ name: "bug" }] } };
}

test("closing an issue as completed tells the post, once", async () => {
	const { msg, payload } = await loggedBug();
	const closed = { action: "closed", issue: { ...payload, state_reason: "completed", milestone: { title: "ExpressiveOS 1.1", due_on: "2026-12-03T08:00:00Z" } } };
	assert.equal((await hook("issues", closed)).status, 200);
	await hook("issues", closed);
	const sent = world.tg("sendMessage");
	assert.equal(sent.length, 1);
	assert.equal(sent[0].body.text, "✅ Fixed in ExpressiveOS 1.1, out Dec 3. Thanks for reporting it!");
	assert.equal(sent[0].body.reply_parameters.message_id, msg.message_id);
	assert.equal(sent[0].body.message_thread_id, BUGS);
	assert.ok(world.bucket.data.has(`m/${CHAT}/${world.nextMessage - 1}`), "replies to the notice join the issue");
});

test("labels planned and needs-logs; not_planned, duplicates and no-reply stay quiet", async () => {
	const { payload } = await loggedBug();
	await hook("issues", { action: "labeled", label: { name: "planned" }, issue: payload });
	await hook("issues", { action: "labeled", label: { name: "needs-logs" }, issue: payload });
	await hook("issues", { action: "closed", issue: { ...payload, state_reason: "not_planned" } });
	await hook("issues", { action: "closed", issue: { ...payload, state_reason: "completed", labels: [{ name: "no-reply" }] } });
	const texts = world.tg("sendMessage").map((c) => c.body.text);
	assert.deepEqual(texts, ["📌 We're on it: planned for an upcoming update.", texts[1]]);
	assert.match(texts[1], /^To track this down we need a log/);
});

test("/reply comments from Daryl go out, others don't", async () => {
	const { payload } = await loggedBug();
	await hook("issue_comment", { action: "created", issue: payload, comment: { id: 11, body: "/reply Try clearing the launcher's data.", user: { login: "someone" } } });
	assert.equal(world.tg("sendMessage").length, 0);
	await hook("issue_comment", { action: "created", issue: payload, comment: { id: 12, body: "/reply Try clearing the launcher's data.", user: { login: "denson9874" } } });
	await hook("issue_comment", { action: "created", issue: payload, comment: { id: 12, body: "/reply Try clearing the launcher's data.", user: { login: "denson9874" } } });
	await hook("issue_comment", { action: "created", issue: payload, comment: { id: 13, body: "just a note", user: { login: "denson9874" } } });
	await hook("issue_comment", {
		action: "created",
		issue: payload,
		comment: { id: 14, body: "/reply Fixed in tonight's test build.\nThanks!\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_", user: { login: "denson9874" } },
	});
	assert.deepEqual(
		world.tg("sendMessage").map((c) => c.body.text),
		["Try clearing the launcher's data.", "Fixed in tonight's test build.\nThanks!"],
	);
	assert.equal(world.gh("POST", /\/issues\/comments\/12\/reactions$/)[0].body.content, "rocket");
});

test("GitHub webhooks need the right signature and repo", async () => {
	const { payload } = await loggedBug();
	assert.equal((await hook("issues", { action: "closed", issue: { ...payload, state_reason: "completed" } }, "wrong")).status, 401);
	assert.equal((await hook("ping", { zen: "hi" })).status, 200);
	await worker.fetch(
		await githubRequest("issues", { repository: { full_name: "someone/else" }, action: "closed", issue: { ...payload, state_reason: "completed" } }),
		world.env,
	);
	assert.equal(world.tg("sendMessage").length, 0);
});
