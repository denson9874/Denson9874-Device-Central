import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import worker from "../src/index.ts";
import { BOT_ID, BUGS, CHAT, CONN, OWNER, ROM, World, dm, post, telegramRequest } from "./world.ts";

let world: World;
beforeEach(() => {
	world = new World().install();
});
afterEach(() => world.uninstall());

const send = (update: Record<string, unknown>, secret?: string, id?: number) => worker.fetch(telegramRequest(update, secret, id), world.env);
const sent = () => world.tg("sendMessage").map((c) => c.body);

test("a wrong webhook secret is refused and nothing is asked", async () => {
	const res = await send({ message: dm("How do I install?") }, "nope");
	assert.equal(res.status, 401);
	assert.equal(world.asked().length, 0);
});

test("a private question is answered with the instructions as system prompt", async () => {
	const res = await send({ message: dm("How do I install ExpressiveOS?") });
	assert.equal(res.status, 200);
	const req = world.asked()[0].body;
	assert.equal(req.model, "claude-sonnet-5-5");
	assert.match(req.system, /^You are Expressive Helpdesk/);
	assert.match(req.system, /A private chat between one person and you/);
	assert.deepEqual(req.messages, [{ role: "user", content: "How do I install ExpressiveOS?" }]);
	assert.equal(sent()[0].chat_id, 42);
	assert.equal(sent()[0].text, "Use the web installer.");
	assert.equal(sent()[0].link_preview_options.is_disabled, true);
});

test("the next private question carries the earlier turns", async () => {
	await send({ message: dm("How do I install ExpressiveOS?") });
	await send({ message: dm("And updates?") });
	assert.deepEqual(world.asked()[1].body.messages, [
		{ role: "user", content: "How do I install ExpressiveOS?" },
		{ role: "assistant", content: "Use the web installer." },
		{ role: "user", content: "And updates?" },
	]);
});

test("/start and a photo without words get fixed replies, without Claude", async () => {
	await send({ message: dm("/start") });
	await send({ message: dm(undefined, { photo: [{ file_id: "x" }] }) });
	assert.equal(world.asked().length, 0);
	assert.match(sent()[0].text, /automated helper/);
	assert.match(sent()[1].text, /only read text/);
});

test("a private SKIP or a refusal becomes the can't-help line and isn't remembered", async () => {
	world.claude = "SKIP";
	await send({ message: dm("What's the weather?") });
	world.stopReason = "refusal";
	await send({ message: dm("Something declined") });
	assert.match(sent()[0].text, /^I can't help with that one/);
	assert.match(sent()[1].text, /^I can't help with that one/);
	assert.equal(world.asked()[1].body.messages.length, 1);
});

test("a post in a support topic is answered in that topic, as a reply", async () => {
	const msg = post(ROM, "How do I switch to Pixel Launcher?");
	await send({ message: msg });
	assert.match(world.asked()[0].body.system, /A public support topic/);
	assert.deepEqual(
		{ chat: sent()[0].chat_id, topic: sent()[0].message_thread_id, reply: sent()[0].reply_parameters.message_id },
		{ chat: CHAT, topic: ROM, reply: msg.message_id },
	);
});

test("in a topic the bot says nothing when Claude answers SKIP", async () => {
	world.claude = "SKIP.";
	await send({ message: post(ROM, "thanks, that worked") });
	assert.equal(world.asked().length, 1);
	assert.equal(sent().length, 0);
});

test("posts the bot must not answer never reach Claude", async () => {
	const other = { message_id: 7, date: 1, chat: { id: CHAT, type: "supergroup" }, from: { id: 77 } };
	await send({ message: post(BUGS, "Wi-Fi calling is broken") }); // the feedback bot's topic
	await send({ message: post(ROM, "Try a reboot", { reply_to_message: other }) }); // people talking to each other
	await send({ message: post(ROM, "I'll look at it", { from: { id: OWNER } }) }); // an admin
	await send({ message: post(ROM, "Welcome!", { from: { id: 9, is_bot: true } }) }); // Rose
	await send({ message: post(ROM, "/rules") });
	await send({ message: post(ROM, "hi", { sender_chat: { id: CHAT, type: "supergroup" } }) }); // anonymous admin
	await send({ message: { ...post(ROM, "How do I install?"), chat: { id: -100999, type: "supergroup" } } }); // another group
	assert.equal(world.asked().length, 0);
	assert.equal(sent().length, 0);
});

test("a reply to the bot's own message continues the conversation", async () => {
	const mine = { message_id: 9000, date: 1, chat: { id: CHAT, type: "supergroup" }, from: { id: BOT_ID, is_bot: true } };
	await send({ message: post(ROM, "It still stops at the G logo", { reply_to_message: mine }) });
	assert.equal(world.asked().length, 1);
	assert.equal(sent().length, 1);
});

test("a message to Daryl's own account is answered from it, labelled as automated", async () => {
	const msg = dm("Does ExpressiveOS support the Pixel 8 Pro?", { business_connection_id: CONN });
	await send({ business_message: msg });
	assert.equal(world.tg("getBusinessConnection").length, 1);
	assert.match(world.asked()[0].body.system, /sent to Daryl's own Telegram account/);
	assert.equal(sent()[0].business_connection_id, CONN);
	assert.match(sent()[0].text, /^🤖 Automated reply from Expressive Helpdesk .*\n\nUse the web installer\.$/);
});

test("in Daryl's chats a SKIP sends nothing, and his own message quiets the bot there", async () => {
	world.claude = "SKIP";
	await send({ business_message: dm("Dinner at 7?", { business_connection_id: CONN }) });
	assert.equal(sent().length, 0);

	world.claude = "Use the web installer.";
	await send({ business_message: dm("I'll answer you myself", { business_connection_id: CONN, from: { id: OWNER } }) });
	await send({ business_message: dm("How do I install?", { business_connection_id: CONN }) });
	assert.equal(world.asked().length, 1);
	assert.equal(sent().length, 0);
});

test("a connection without the right to reply, or switched off, is left alone", async () => {
	await send({ business_connection: { id: "ro", user: { id: OWNER }, is_enabled: true, rights: {} } });
	await send({ business_connection: { id: "gone", user: { id: OWNER }, is_enabled: false, rights: { can_reply: true } } });
	await send({ business_message: dm("How do I install?", { business_connection_id: "ro" }) });
	await send({ business_message: dm("How do I install?", { business_connection_id: "gone" }) });
	assert.equal(world.asked().length, 0);
});

test("/helpdesk off from an admin silences everything until /helpdesk on; others can't use it", async () => {
	await send({ message: dm("/helpdesk off") }); // not an admin
	assert.equal(sent().length, 0);
	await send({ message: dm("/helpdesk off", { from: { id: OWNER }, chat: { id: OWNER, type: "private" } }) });
	assert.match(sent()[0].text, /Helpdesk is OFF/);
	await send({ message: dm("How do I install?") });
	await send({ message: post(ROM, "How do I install?") });
	await send({ business_message: dm("How do I install?", { business_connection_id: CONN }) });
	assert.equal(world.asked().length, 0);
	await send({ message: dm("/helpdesk on", { from: { id: OWNER }, chat: { id: OWNER, type: "private" } }) });
	await send({ message: dm("How do I install?") });
	assert.equal(world.asked().length, 1);
});

test("one person gets at most MAX_REPLIES_PER_USER_HOUR answers an hour", async () => {
	for (let i = 0; i < 5; i++) await send({ message: dm(`Question ${i}`) });
	assert.equal(world.asked().length, 3);
	assert.equal(sent().length, 3);
});

test("Telegram re-sending an update doesn't produce a second answer", async () => {
	const msg = dm("How do I install?");
	await send({ message: msg }, undefined, 777);
	await send({ message: msg }, undefined, 777);
	assert.equal(sent().length, 1);
});

test("a failing Claude call is retried once, then dropped without a reply", async () => {
	world.failing.add("claude");
	const msg = dm("How do I install?");
	assert.equal((await send({ message: msg }, undefined, 888)).status, 500);
	assert.equal((await send({ message: msg }, undefined, 888)).status, 200);
	assert.equal(sent().length, 0);
});

test("a very long answer is cut to fit one Telegram message", async () => {
	world.claude = "a".repeat(6000);
	await send({ message: dm("Tell me everything") });
	assert.equal(sent()[0].text.length, 3900);
});
