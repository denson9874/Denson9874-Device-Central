// android-info.txt: what a zip requires of the phone, checked before anything is written, with
// AOSP fastboot's rules (ParseRequirementLine and CheckRequirement in fastboot.cpp):
//   require board=cheetah            ("board" is the bootloader's "product")
//   require version-bootloader=a|b   (any of the values; a trailing * matches a prefix)
//   reject version-baseband=x
//   require-for-product:cheetah version-baseband=y
//   require partition-exists=vendor_kernel_boot

export interface Requirement {
	line: string;
	name: string;
	/** Only checked on this product (require-for-product:). */
	product: string;
	invert: boolean;
	options: string[];
}

export function parseRequirements(text: string): { requirements: Requirement[]; errors: string[] } {
	const requirements: Requirement[] = [];
	const errors: string[] = [];
	for (const raw of text.split("\n")) {
		const line = raw.replace(/\r$/, "");
		if (!line) continue;
		let m = /^(require\s+|reject\s+)?\s*(\S+)\s*=\s*(.*)$/.exec(line);
		let product = "";
		let invert = false;
		if (m) {
			invert = (m[1] ?? "").trim() === "reject";
		} else {
			m = /^require-for-product:\s*(\S+)\s+(\S+)\s*=\s*(.*)$/.exec(line);
			if (!m) {
				errors.push(line);
				continue;
			}
			product = m[1];
			m = [m[0], "", m[2], m[3]] as unknown as RegExpExecArray;
		}
		let name = m[2];
		if (name === "board") name = "product";
		const options = m[3].split("|").map((o) => o.trim());
		requirements.push({ line, name, product, invert, options });
	}
	return { requirements, errors };
}

/** Whether a value meets a requirement's options (before inversion). */
export function matches(options: string[], value: string): boolean {
	return options.some((o) => o === value || (o.endsWith("*") && value.startsWith(o.slice(0, -1))));
}

export interface RequirementResult {
	requirement: Requirement;
	ok: boolean;
	/** The phone's value; null when it has no such variable. */
	value: string | null;
	skipped?: boolean;
}

/** Checks each requirement against the phone; getVar returns null for a variable it lacks. */
export async function checkRequirements(
	requirements: Requirement[],
	getVar: (name: string) => Promise<string | null>,
): Promise<RequirementResult[]> {
	const product = (await getVar("product")) ?? "";
	const out: RequirementResult[] = [];
	for (const r of requirements) {
		if (r.product && r.product !== product) {
			out.push({ requirement: r, ok: true, value: null, skipped: true });
			continue;
		}
		if (r.name === "partition-exists") {
			const v = await getVar(`has-slot:${r.options[0]}`);
			out.push({ requirement: r, ok: v === "yes" || v === "no", value: v });
			continue;
		}
		const value = await getVar(r.name);
		if (value === null) {
			out.push({ requirement: r, ok: false, value });
			continue;
		}
		const ok = matches(r.options, value) !== r.invert;
		out.push({ requirement: r, ok, value });
	}
	return out;
}
