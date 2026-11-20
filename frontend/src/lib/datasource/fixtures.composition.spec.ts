// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { createMockDriver } from './mock-seed.js';

// ── Composition consistency for fixture + seed doctype definitions ───────────
//
// Catches two classes of structural bug in the doctype schema graph:
//
// 1. member_of reciprocity — the system supports two valid spellings of
//    composition: the mutual form (parent declares `children:` AND child
//    declares `member_of`) and the children-only form (parent declares
//    `children:`, child has no `member_of` — e.g. crm.Contact, routed via
//    the parent's nested route). The one INVALID shape is a child that
//    declares `member_of` whose parent has no matching `children:` entry
//    — the parent wouldn't know it owns the child. This rule flags that.
// 2. No parent→child reference fields — a doctype must not declare a `reference`
//    (or array-of-reference) field whose target is one of its OWN composition
//    children. Such relationships should be modelled via `children:` instead.
//
// Both filters and seeds are loaded together via `createMockDriver()`.

interface ParsedDoctype {
	qualified: string;
	domain: string;
	doctype: string;
	memberOf?: string;
	children: { role: string; doctype: string }[];
	references: { field: string; target: string }[];
}

function qualify(domain: string, target: string): string {
	return target.includes('.') ? target : `${domain}.${target}`;
}

function parseDoctype(qualified: string, def: Record<string, unknown>): ParsedDoctype {
	const parts = qualified.split('.');
	const domain = typeof def['domain'] === 'string' ? (def['domain'] as string) : (parts[0] ?? '');
	const doctype =
		typeof def['doctype'] === 'string'
			? (def['doctype'] as string)
			: parts.slice(1).join('.') || qualified;
	const memberOf = typeof def['member_of'] === 'string' ? (def['member_of'] as string) : undefined;

	const children: { role: string; doctype: string }[] = [];
	const childrenMap = def['children'];
	if (childrenMap && typeof childrenMap === 'object') {
		for (const [role, entry] of Object.entries(childrenMap as Record<string, unknown>)) {
			if (entry && typeof entry === 'object') {
				const dt = (entry as Record<string, unknown>)['doctype'];
				if (typeof dt === 'string') children.push({ role, doctype: dt });
			}
		}
	}

	const references: { field: string; target: string }[] = [];
	const fields = def['fields'];
	if (fields && typeof fields === 'object') {
		for (const [field, fdef] of Object.entries(fields as Record<string, unknown>)) {
			if (!fdef || typeof fdef !== 'object') continue;
			const f = fdef as Record<string, unknown>;
			if (f['type'] === 'reference') {
				const target = f['doctype'];
				if (typeof target === 'string') references.push({ field, target });
			}
			if (f['type'] === 'array') {
				const items = f['items'];
				if (items && typeof items === 'object') {
					const it = items as Record<string, unknown>;
					if (it['type'] === 'reference' && typeof it['doctype'] === 'string') {
						references.push({ field, target: it['doctype'] as string });
					}
				}
			}
		}
	}

	return { qualified, domain, doctype, memberOf, children, references };
}

/**
 * Run both composition rules over the whole doctype registry.
 * Returns an array of human-readable error strings (empty = valid).
 */
function validateComposition(registry: Map<string, Record<string, unknown>>): string[] {
	const errors: string[] = [];

	// Parse every definition once.
	const parsed = new Map<string, ParsedDoctype>();
	for (const [qualified, def] of registry) {
		parsed.set(qualified, parseDoctype(qualified, def));
	}

	// Index, per domain, the set of parent doctype names declared via `children`.
	// domain → (parent unqualified doctype → set of child unqualified doctype)
	const childrenByDomain = new Map<string, Map<string, Set<string>>>();
	// domain → (child unqualified doctype → member_of parent unqualified name)
	const memberOfByDomain = new Map<string, Map<string, string>>();
	for (const p of parsed.values()) {
		let cb = childrenByDomain.get(p.domain);
		if (!cb) {
			cb = new Map();
			childrenByDomain.set(p.domain, cb);
		}
		let set = cb.get(p.doctype);
		if (!set) {
			set = new Set();
			cb.set(p.doctype, set);
		}
		for (const ch of p.children) set.add(ch.doctype);

		if (p.memberOf) {
			let mb = memberOfByDomain.get(p.domain);
			if (!mb) {
				mb = new Map();
				memberOfByDomain.set(p.domain, mb);
			}
			mb.set(p.doctype, p.memberOf);
		}
	}

	// ── Rule 1 — member_of reciprocity (one-directional) ────────────────────
	// A child declaring `member_of: P` requires the parent P to declare a
	// matching `children:` entry. The reverse is NOT required — the
	// children-only spelling (parent declares `children:`, child has no
	// `member_of`) is a valid pattern (e.g. crm.Contact), so a parent's
	// `children:` entry with a member_of-less child is not flagged.
	for (const p of parsed.values()) {
		const d = p.domain;

		if (p.memberOf) {
			const parentQualified = `${d}.${p.memberOf}`;
			const parentDef = parsed.get(parentQualified);
			if (!parentDef) {
				errors.push(
					`${d}.${p.doctype}: member_of ${p.memberOf} has no matching children declaration on ${parentQualified} (parent not found)`
				);
				continue;
			}
			const declaresChild = parentDef.children.some((c) => c.doctype === p.doctype);
			if (!declaresChild) {
				errors.push(
					`${d}.${p.doctype}: member_of ${p.memberOf} has no matching children declaration on ${parentQualified}`
				);
			}
		}
	}

	// ── Rule 2 — No reference field duplicating composition ────────────────
	for (const p of parsed.values()) {
		const d = p.domain;
		const cb = childrenByDomain.get(d)?.get(p.doctype);

		for (const ref of p.references) {
			const targetQualified = qualify(d, ref.target);
			if (targetQualified === p.qualified) continue; // self-reference — allowed
			const targetDef = parsed.get(targetQualified);
			if (!targetDef) continue; // cross-domain / unknown — skip

			// T is a composition child of A if EITHER:
			//   (a) T declares `member_of` equal to A's unqualified doctype name, OR
			//   (b) A declares a `children:` entry whose doctype equals T's
			//       unqualified doctype name.
			const isChildViaMemberOf = targetDef.domain === d && targetDef.memberOf === p.doctype;
			const isChildViaChildren = cb?.has(targetDef.doctype) === true;

			if (isChildViaMemberOf || isChildViaChildren) {
				errors.push(
					`${d}.${p.doctype}: field '${ref.field}' references ${targetQualified} which is a composition child (model via children: instead)`
				);
			}
		}
	}

	return errors;
}

describe('fixture & seed doctype composition consistency', () => {
	it('all doctype definitions reciprocate member_of with a parent children: declaration, and hold no parent→child reference fields', () => {
		const driver = createMockDriver();
		const errors = validateComposition(driver.doctypeDefinitions);

		expect(errors, errors.join('\n')).toEqual([]);
	});
});
