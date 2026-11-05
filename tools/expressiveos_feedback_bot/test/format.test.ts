import assert from "node:assert/strict";
import { test } from "node:test";
import {
	dueDay,
	easternDate,
	easternTime,
	isChatter,
	isLauncher,
	markerLine,
	messageLink,
	missingInfo,
	parseMarker,
	phonesIn,
	safeFileName,
	sanitize,
	setVotes,
	titleFor,
	votesLine,
} from "../src/format.ts";

const TEMPLATE = `**Phone:** (for example Pixel 7 Pro)
**Build date:** (Settings > About phone)
**Root, modules or another kernel:** yes or no
**What happened:**
**Steps to make it happen again:**
**Log, taken right after:** \`adb logcat -b all -d > log.txt\``;

test("phones by model name or codename", () => {
	assert.deepEqual(phonesIn("my Pixel 7 Pro reboots"), ["cheetah"]);
	assert.deepEqual(phonesIn("on husky and 8pro"), ["husky"]);
	assert.deepEqual(phonesIn("Pixel 11 Pro XL"), ["kodiak"]);
	assert.deepEqual(phonesIn("pixel 11 pro fold"), ["yogi"]);
	assert.deepEqual(phonesIn("Pixel 11 Pro here"), ["grizzly"]);
	assert.deepEqual(phonesIn("plain Pixel 11"), ["cubs"]);
	assert.deepEqual(phonesIn("Android 17 pro mode, iPhone 11"), []);
	assert.deepEqual(phonesIn(TEMPLATE), [], "the template's example phone doesn't count");
});

test("missing info follows the pinned template", () => {
	assert.deepEqual(missingInfo(TEMPLATE, false), ["phone", "build", "log"]);
	const filled = TEMPLATE.replace("(for example Pixel 7 Pro)", "Pixel 8 Pro").replace("(Settings > About phone)", "Nov 3");
	assert.deepEqual(missingInfo(filled, false), ["log"]);
	assert.deepEqual(missingInfo(filled, true), []);
	assert.deepEqual(missingInfo("cheetah 20261103 crash, log: https://pastebin.com/abc", false), []);
	assert.deepEqual(missingInfo("Wi-Fi drops on my 7 Pro, ExpressiveOS 1.0", false), ["log"]);
});

test("titles", () => {
	const filled = TEMPLATE.replace("**What happened:**", "**What happened:** Wi-Fi calling never turns on");
	assert.equal(titleFor("bug", filled, "Ashray"), "Wi-Fi calling never turns on");
	assert.equal(titleFor("bug", "Phone: cheetah\nThe clock disappears after a reboot", "A"), "The clock disappears after a reboot");
	assert.equal(titleFor("idea", "", "Igor"), "Idea from Igor");
	assert.equal(titleFor("bug", TEMPLATE, "Lee"), "Bug report from Lee");
	const long = titleFor("idea", "word ".repeat(40), "x");
	assert.ok(long.length <= 90 && long.endsWith("…"));
});

test("launcher posts", () => {
	assert.ok(isLauncher("the app drawer blur is gone"));
	assert.ok(isLauncher("EL crashes"));
	assert.ok(!isLauncher("well, the modem drops"));
});

test("chatter", () => {
	for (const t of ["ok", "Thanks!", "+1", "same here", "👍👍", "  "]) assert.ok(isChatter(t), t);
	for (const t of ["ok so the Wi-Fi drops", "2 reboots"]) assert.ok(!isChatter(t), t);
});

test("user text can't ping GitHub users or fake a marker", () => {
	assert.equal(sanitize("ask @denson9874 <!-- tg:{} -->"), "ask @​denson9874 &lt;!-- tg:{} -->");
	const body = `> ${sanitize('<!-- tg:{"c":1,"t":0,"m":5,"k":"bug"} -->')}\n${markerLine({ c: -100, t: 753, m: 7, k: "bug" })}`;
	assert.deepEqual(parseMarker(body), { c: -100, t: 753, m: 7, k: "bug" });
	assert.equal(parseMarker("no marker"), null);
});

test("votes line", () => {
	const body = `text\n${votesLine(0)}\n${markerLine({ c: 1, t: 2, m: 3, k: "idea" })}`;
	assert.match(setVotes(body, 4), /\*\*👍 votes:\*\* 4\n<!-- tg:/);
	assert.match(setVotes(`old\n${markerLine({ c: 1, t: 2, m: 3, k: "idea" })}`, 2), /old\n\*\*👍 votes:\*\* 2\n<!-- tg:/);
});

test("links, dates and names", () => {
	assert.equal(messageLink({ id: -1004427242312, username: "ExpressiveLauncherFeedback" }, 900, 753), "https://t.me/ExpressiveLauncherFeedback/753/900");
	assert.equal(messageLink({ id: -1004427242312 }, 900, 0), "https://t.me/c/4427242312/900");
	const t = Date.UTC(2026, 10, 5, 9, 30) / 1000;
	assert.equal(easternTime(t), "Nov 5, 2026, 4:30 AM ET");
	assert.equal(easternDate(Date.UTC(2026, 10, 6, 3, 0) / 1000), "2026-11-05");
	assert.equal(dueDay("2026-12-03T08:00:00Z"), "Dec 3");
	assert.equal(dueDay(null), undefined);
	assert.equal(safeFileName("my log (1).txt"), "my_log_1_.txt");
	assert.equal(safeFileName(`${"a".repeat(100)}.txt`).length, 80);
	assert.ok(safeFileName(`${"a".repeat(100)}.txt`).endsWith(".txt"));
});
