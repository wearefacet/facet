// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure helpers for the role `visible_tags` editor.
 *
 * The backend write rule (`RBAC::RoleAuthority.tag_errors`): a new tag
 * must sit inside the union of the caller's own `visible_tags` and the
 * role's previous tags. The wildcard tag contains everything. Caller
 * tags of `null` — the permission store not yet hydrated — defer the
 * check to the backend, which stays the authority.
 */

/**
 * Returns the tags in `next` that sit outside the caller ∪ committed
 * union. Empty when every tag is allowed (or when the check cannot run
 * client-side).
 */
export function tagUnionOverflow(
	next: string[],
	committed: string[],
	callerTags: string[] | null
): string[] {
	if (callerTags === null) return [];
	const union = new Set([...callerTags, ...committed]);
	if (union.has('*')) return [];
	return next.filter((tag) => !union.has(tag));
}
