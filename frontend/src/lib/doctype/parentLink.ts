// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Composition parent resolution for child create forms.
 *
 * A `member_of` child document is created through the parent's nested route
 * (`POST /Api/:domain/:parent/:id/:rel`) — the backend stamps the
 * system-managed `meta.parent_id` and rejects the flat create with a 422.
 * The relation key (`rel`) lives only on the PARENT definition's `children`
 * map; the child definition carries just `member_of` (the parent doctype
 * name). This module resolves the key from the parent's raw `core.DocType`
 * record so the create form can address the nested route.
 */

/**
 * Find the parent's `children` entry whose target is `childDoctype` and
 * return its relation key.
 *
 * Entry targets are bare doctype names (`Part`). A child always lives in
 * the parent's domain. Authoring rejects a qualified target (`domain.Name`):
 * `ChildrenDefinition.from_json` and `Doctype::Validation` both answer 422.
 * The qualified form belongs to the sidecar grammar, not to the children
 * grammar.
 *
 * The matching below still strips a `domain.` prefix. The backend never
 * stores such definitions; this tolerance covers a malformed raw record
 * only. When several entries target the same doctype, the first one in
 * definition order wins. The create surface stays ambiguous either way,
 * and `Doctype::Check` does not flag duplicate targets, so this is a
 * best-effort resolution.
 *
 * Returns `null` when the parent declares no `children` map, or no entry
 * matches — a composition reciprocity break (`Doctype::Check` diagnostic
 * `:composition`), which the caller surfaces as a form error.
 */
export function resolveParentRel(
	parentDef: Record<string, unknown>,
	childDoctype: string
): string | null {
	const children = parentDef['children'];
	if (!children || typeof children !== 'object' || Array.isArray(children)) return null;
	for (const [rel, entry] of Object.entries(children as Record<string, unknown>)) {
		if (!entry || typeof entry !== 'object') continue;
		const target = (entry as Record<string, unknown>)['doctype'];
		if (typeof target !== 'string') continue;
		const bare = target.includes('.') ? target.slice(target.indexOf('.') + 1) : target;
		if (bare === childDoctype) return rel;
	}
	return null;
}
