// The check right before an install: the phone, read again, against the android-info.txt of the
// zip about to be written (whatever the Connect step showed), as fastboot's flashall does.

import { describe, expect, it } from "vitest";
import { Phone } from "../src/fastboot/device.ts";
import { type PhoneReport, checkBeforeInstall, inspectPhone, reportProblems } from "../src/flash/preflight.ts";
import { FakeConnector, FakePhone, type FakeOptions } from "./fake-phone.ts";

function phoneOf(o: FakeOptions = {}) {
	const fake = new FakePhone(o);
	const c = new FakeConnector(fake);
	return { fake, phone: new Phone(c.link(), c) };
}

describe("the check before an install", () => {
	it("passes the phone the build is for", async () => {
		const { fake, phone } = phoneOf();
		expect(await checkBeforeInstall(phone, "require board=cheetah\nrequire version-bootloader=cloudripper-16.4*\n", "cheetah")).toEqual([]);
		// It only reads
		expect(fake.commands.every((c) => c.startsWith("getvar:"))).toBe(true);
	});

	it("refuses another model, whatever was checked before", async () => {
		const { phone } = phoneOf({ product: "husky" });
		expect(await checkBeforeInstall(phone, "require board=cheetah\n", "cheetah")).toEqual([{ kind: "product", product: "husky" }]);
		// Even a zip with no board line is for the model that was chosen
		expect(await checkBeforeInstall(phone, "require version-bootloader=cloudripper-16.4*\n", "cheetah")).toEqual([{ kind: "product", product: "husky" }]);
	});

	it("refuses when the zip's android-info.txt needs other firmware", async () => {
		const { phone } = phoneOf();
		const problems = await checkBeforeInstall(phone, "require board=cheetah\nrequire version-bootloader=cloudripper-17.0*\n", "cheetah");
		expect(problems).toHaveLength(1);
		expect(problems[0]).toMatchObject({ kind: "requirement", result: { ok: false, value: "cloudripper-16.4-13506318" } });
	});

	it("goes on past a line it can't read, as fastboot's CheckRequirements does (images-2)", async () => {
		const { phone } = phoneOf();
		expect(await checkBeforeInstall(phone, "require board=cheetah\nnonsense\nrequire foo\n", "cheetah")).toEqual([]);
		// A requirement the phone fails still counts, beside a line that can't be read
		const problems = await checkBeforeInstall(phone, "require board=cheetah\nnonsense\nrequire version-bootloader=cloudripper-17.0*\n", "cheetah");
		expect(problems.map((p) => p.kind)).toEqual(["requirement"]);
		// The lines are kept in the report, for the warning
		const r = await inspectPhone(phone, "require board=cheetah\nnonsense\n");
		expect(r.requirementErrors).toEqual(["nonsense"]);
		expect(reportProblems(r, "cheetah")).toEqual([]);
	});

	it("refuses an answer for the model that isn't a model name (protocol-2)", async () => {
		for (const product of ["yes", "no", "", "0x10000000", "a", "Pixel 7"]) {
			const { phone } = phoneOf({ product });
			expect(await checkBeforeInstall(phone, "require board=cheetah\n", "cheetah"), product).toEqual([{ kind: "unexpected", product }]);
		}
		// A codename that's another phone's is another phone
		const { phone } = phoneOf({ product: "sdm845_64" });
		expect(await checkBeforeInstall(phone, "require board=cheetah\n", "cheetah")).toEqual([{ kind: "product", product: "sdm845_64" }]);
	});

	it("refuses a zip without android-info.txt, and a locked bootloader", async () => {
		const { phone } = phoneOf();
		expect(await checkBeforeInstall(phone, null, "cheetah")).toEqual([{ kind: "no-android-info" }]);
		const locked = phoneOf({ unlocked: false });
		expect(await checkBeforeInstall(locked.phone, "require board=cheetah\n", "cheetah")).toEqual([{ kind: "locked" }]);
	});

	it("skips lines for other products, as fastboot does", async () => {
		const { phone } = phoneOf();
		expect(await checkBeforeInstall(phone, "require board=cheetah\nrequire-for-product:husky version-bootloader=ripcurrent-17*\n", "cheetah")).toEqual([]);
	});
});

describe("a report's problems", () => {
	it("are judged against the model the build is for", async () => {
		const { phone } = phoneOf();
		const r: PhoneReport = await inspectPhone(phone, "require board=cheetah\n");
		expect(r.androidInfo).toBe(true);
		expect(reportProblems(r, "cheetah")).toEqual([]);
		expect(reportProblems(r, "husky")).toEqual([{ kind: "product", product: "cheetah" }]);
		expect(reportProblems({ ...r, androidInfo: false, requirements: [] }, "cheetah")).toEqual([{ kind: "no-android-info" }]);
	});
});
