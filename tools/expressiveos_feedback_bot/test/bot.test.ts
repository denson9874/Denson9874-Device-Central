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

test("a bug post with a log link becomes an issue, gets 👀, and an ask for missing build", async () => {
	const msg = post(BUGS, {
		caption: "Wi-Fi calling never turns on on my Pixel 7 Pro, log: https://pastebin.com/abc",
		photo: [{ file_id: "small" }, { file_id: "big", file_size: 2 }],
	});
	const res = await send({ message: msg });
	assert.equal(res.status, 200);

	const issue = world.issues.get(1)!;
	assert.equal(issue.title, "Wi-Fi calling never turns on on my Pixel 7 Pro, log: https://pastebin.com/abc");
	assert.deepEqual(issue.labels, ["bug", "phone:cheetah"]);
	assert.match(issue.body, /^> Wi-Fi calling never turns on/);
	assert.match(issue.body, /📎 \[photo\.jpg\]\(https:\/\/github\.com\/denson9874\/expressiveos-feedback\/blob\/HEAD\/attachments\/2026-11-05\/\d+-photo\.jpg\)/);
	assert.match(issue.body, /\*\*From:\*\* \*\*Ashray\*\* \(@​ashray\) · \[Open in Telegram\]\(https:\/\/t\.me\/ExpressiveLauncherFeedback\/753\/\d+\)/);
	assert.match(issue.body, /\*\*Posted:\*\* Nov 5, 2026, 4:30 AM ET/);
	assert.match(issue.body, /\*\*Missing from the post:\*\* build/);
	assert.match(issue.body, /<!-- tg:\{"c":-1004427242312,"t":753,"m":\d+,"k":"bug"\} -->$/);
	assert.equal(world.files.size, 1);
	assert.equal(world.tg("getFile")[0].body.file_id, "big");

	assert.deepEqual(world.tg("setMessageReaction")[0].body.reaction, [{ type: "emoji", emoji: "👀" }]);
	const ask = world.tg("sendMessage")[0].body;
	assert.equal(ask.message_thread_id, BUGS);
	assert.equal(ask.reply_parameters.message_id, msg.message_id);
	assert.match(ask.text, /^Thanks, logged as #1\. To fix it we also need:\n• your build date /);
	assert.doesNotMatch(ask.text, /phone model/);
});

test("bug posts without logs warn on strikes 1 & 2, skip GitHub issues, and mute 48h + reset on strike 3", async () => {
	// Strike 1 (even if they wrote 'no logcat' or attached a screenshot.png as a document)
	const m1 = post(BUGS, {
		text: "Wi-Fi calling broken on cheetah 1.3.1, sorry no logcat",
		document: { file_id: "img1", file_name: "screenshot.png", mime_type: "image/png" },
	});
	await send({ message: m1 });
	assert.equal(world.issues.size, 0, "no GitHub issue opened without a log");
	assert.equal(world.tg("restrictChatMember").length, 0);
	assert.match(world.tg("sendMessage")[0].body.text, /^⚠️ Warning 1\/3: Bug reports in this topic must include logs\./);

	// Strike 2
	const m2 = post(BUGS, { text: "Bluetooth stutters on cheetah 1.3.1" });
	await send({ message: m2 });
	assert.equal(world.issues.size, 0);
	assert.equal(world.tg("restrictChatMember").length, 0);
	assert.match(world.tg("sendMessage")[1].body.text, /^⚠️ Warning 2\/3:/);

	// Strike 3 -> 48h mute via restrictChatMember, strike count reset to 0
	const m3 = post(BUGS, { text: "SystemUI freezes when unlocking" });
	await send({ message: m3 });
	assert.equal(world.issues.size, 0);
	assert.equal(world.tg("restrictChatMember").length, 1);
	const mute = world.tg("restrictChatMember")[0].body;
	assert.equal(mute.chat_id, CHAT);
	assert.equal(mute.user_id, 42);
	assert.equal(mute.permissions.can_send_messages, false);
	assert.equal(mute.permissions.can_send_documents, false);
	assert.equal(mute.permissions.can_send_photos, false);
	const nowSec = Math.floor(Date.now() / 1000);
	assert.ok(mute.until_date >= nowSec + 48 * 3600 - 10 && mute.until_date <= nowSec + 48 * 3600 + 10);
	assert.match(world.tg("sendMessage")[2].body.text, /^🔇 Warning 3\/3: You reported 3 bugs without logs, so your posts have been muted for 48 hours\./);

	// After the 48h mute triggered, strikes reset to 0 so the next violation starts at 1/3
	await send({ message: post(BUGS, { text: "Another bug without logs later" }) });
	assert.match(world.tg("sendMessage")[3].body.text, /^⚠️ Warning 1\/3:/);
	assert.equal(world.tg("restrictChatMember").length, 1);
});

test("replying to a warned bug post (or the bot's warning) with a log promotes it into a GitHub issue", async () => {
	const first = post(BUGS, {
		caption: "the clock vanishes after a reboot on Pixel 8 Pro",
		photo: [{ file_id: "shot1", file_size: 2 }],
	});
	await send({ message: first });
	assert.equal(world.issues.size, 0);
	const warnMsgId = world.nextMessage - 1;

	// Replying without a log adds context to the held bug without adding a second strike
	await send({
		message: post(BUGS, {
			text: "Build 20261126",
			reply_to_message: { message_id: warnMsgId, chat: { id: CHAT } },
		}),
	});
	assert.equal(world.issues.size, 0);
	assert.equal(world.tg("sendMessage").length, 1, "no second strike on follow-up reply");

	// Replying with log.txt opens the issue with original photo + follow-up build + log.txt!
	const logReply = post(BUGS, {
		text: "here is the log",
		document: { file_id: "log1", file_name: "log.txt", file_size: 2 },
		reply_to_message: { message_id: warnMsgId, chat: { id: CHAT } },
	});
	await send({ message: logReply });
	assert.equal(world.issues.size, 1);
	const issue = world.issues.get(1)!;
	assert.deepEqual(issue.labels, ["bug", "phone:husky"]);
	assert.match(issue.body, /> the clock vanishes after a reboot on Pixel 8 Pro/);
	assert.match(issue.body, /photo\.jpg/);
	assert.match(issue.body, /> Build 20261126/);
	assert.match(issue.body, /log\.txt/);
	assert.doesNotMatch(issue.body, /Missing from the post/);
	assert.equal(world.tg("sendMessage").at(-1)!.body.text, "Thanks, logged as #1.");
});

test("admins are exempt from missing-log strikes, can /unwarn members, and support questions in Bugs are skipped", async () => {
	world.admins.add(1);
	// How-to question in Bugs -> ignored by Feedback bot (left to Helpdesk bot), 0 strikes, 0 issues
	await send({ message: post(BUGS, { text: "How do I take a logcat?" }) });
	assert.equal(world.issues.size, 0);
	assert.equal(world.tg("sendMessage").length, 0);

	// Member gets Strike 1
	const m1 = post(BUGS, { text: "Camera freezes on kodiak" });
	await send({ message: m1 });
	assert.match(world.tg("sendMessage").at(-1)!.body.text, /^⚠️ Warning 1\/3:/);

	// Admin clears member's warnings with /unwarn
	await send({
		message: post(BUGS, {
			text: "/unwarn",
			from: { id: 1, first_name: "Daryl" },
			reply_to_message: { message_id: m1.message_id, chat: { id: CHAT }, from: m1.from },
		}),
	});
	assert.equal(world.tg("sendMessage").at(-1)!.body.text, "Cleared missing-log warnings for Ashray.");

	// Next logless bug from Ashray starts at 1/3 again instead of 2/3
	await send({ message: post(BUGS, { text: "NFC broken on kodiak" }) });
	assert.match(world.tg("sendMessage").at(-1)!.body.text, /^⚠️ Warning 1\/3:/);

	// Admin posting in Bugs without a log opens an issue immediately with no strike
	await send({ message: post(BUGS, { text: "Reproduced status bar glitch on yogi 1.3.1", from: { id: 1, first_name: "Daryl" } }) });
	assert.equal(world.issues.size, 1);
	assert.equal(world.tg("restrictChatMember").length, 0);
});

test("a complete bug report gets no ask", async () => {
	await send({ message: post(BUGS, { text: "cheetah, Nov 3 build: Bluetooth audio stutters", document: { file_id: "log", file_name: "log.txt", file_size: 2 } }) });
	assert.equal(world.issues.size, 1);
	assert.equal(world.tg("sendMessage").length, 0);
});

test("replies, replies to the bot's ask, and album items join the same issue", async () => {
	const first = post(BUGS, {
		text: "the clock vanishes after a reboot, log: https://pastebin.com/log1",
		media_group_id: "album1",
		photo: [{ file_id: "p1", file_size: 2 }],
	});
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

test("GET /health reports whether the bot has can_restrict_members in Expressive Group Chat", async () => {
	world.admins.add(123);
	const res = await worker.fetch(new Request("https://bot.example/health"), world.env);
	assert.equal(res.status, 200);
	assert.deepEqual(await res.json(), {
		ok: true,
		bot: "@ExpressiveFeedbackBot",
		status: "administrator",
		can_restrict_members: true,
	});
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
