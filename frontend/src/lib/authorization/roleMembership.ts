// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Pure helpers for the role-assignment UI.
//
// `iam.Account.roles` is an array of role document ids of the form
// `iam.Roles.{name}` (e.g. `iam.Roles.admin`). These helpers compute the
// next array after an assignment change. They have no Svelte / DOM
// dependencies and are unit-tested in `roleMembership.spec.ts`.
//
// `iam.Account.default_role` references the same kind of id. When a role is
// removed from `roles` AND that role was the account's default, the
// `default_role` field becomes stale — at login time the backend falls back
// to "first assigned role" (see `src/iam/login.cr`), but the persisted field
// is not auto-maintained. The assignment mutation helpers return the
// corrected `default_role` together with the new `roles` array so the caller
// can PATCH both fields in a single mutation.

export type RolesField = string[];

export interface AccountMutation {
	/** New value for the `roles` array (always set, even when unchanged). */
	roles: RolesField;
	/** New value for `default_role` (`null` = clear). Returned only when it
	 *  differs from the current value; omitted otherwise so the caller can
	 *  PATCH only what changed. */
	defaultRole?: string | null;
}

/**
 * Collapse duplicate role ids, preserving first-occurrence order.
 *
 * The persisted `roles` array must not contain duplicates — a keyed `{#each}`
 * in the assignment UI would reject a duplicate key at runtime. Callers apply
 * this defensively so a stale duplicate collapses on the next read or write.
 */
export function dedupeRoleIds(roles: RolesField): RolesField {
	return [...new Set(roles)];
}

/**
 * Add a role to an account's `roles` array, ignoring duplicates.
 *
 * Returns the updated `roles` array. `default_role` is set when the account
 * had no roles yet (so the first assigned role becomes the default, mirroring
 * the backend's login-time fallback).
 */
export function assignRole(
	roles: RolesField,
	roleDocId: string,
	currentDefault?: string | null
): AccountMutation {
	roles = dedupeRoleIds(roles);
	if (roles.includes(roleDocId)) {
		// Already a member — no-op. `default_role` is unchanged, so omit it
		// so the caller PATCHes only what changed.
		return { roles };
	}
	const next = [...roles, roleDocId];
	const hadNoDefault = !currentDefault || currentDefault.length === 0;
	// First-ever assignment: make this role the default so login does not
	// fall through to "first assigned" later behaviour.
	if (hadNoDefault && next.length === 1) {
		return { roles: next, defaultRole: roleDocId };
	}
	// `default_role` unchanged — omit it so the caller PATCHes only `roles`.
	return { roles: next };
}

/**
 * Remove a role from an account's `roles` array.
 *
 * When the removed role was the account's `default_role`, the default is
 * re-pointed to the first remaining assigned role — or cleared (`null`) when
 * the account has no roles left. This keeps the persisted field consistent
 * with the `roles` array.
 */
export function unassignRole(
	roles: RolesField,
	roleDocId: string,
	currentDefault?: string | null
): AccountMutation {
	roles = dedupeRoleIds(roles);
	const next = roles.filter((r) => r !== roleDocId);
	if (!roles.includes(roleDocId)) {
		// Not assigned — no-op. `default_role` is unchanged, so omit it.
		return { roles };
	}
	const currentDef = currentDefault ?? null;
	let nextDefault: string | null = currentDef;
	if (currentDef === roleDocId) {
		// Default was the removed role. Re-point to the first remaining, or
		// clear when the account has no roles left.
		nextDefault = next.length > 0 ? next[0] : null;
	}
	if (nextDefault === currentDef) {
		return { roles: next };
	}
	return { roles: next, defaultRole: nextDefault };
}

/**
 * Derive the role's `name` from its document id.
 *
 * Role document ids follow the convention `iam.Roles.{name}` (see
 * `data/seeds/iam.Roles/documents.yml`). The `name` is everything after
 * the last dot. Returns the id unchanged if it has no dot.
 */
export function roleDocIdToName(roleDocId: string): string {
	const i = roleDocId.lastIndexOf('.');
	return i === -1 ? roleDocId : roleDocId.slice(i + 1);
}

/**
 * Human-friendly label for a role name (`production_editor` → `Production Editor`).
 *
 * Role `name` values are snake_case identifiers; this title-cases them for
 * display. Applied at every role-name display site so the UI reads the same
 * everywhere (sidebar, assignments, members, RBAC picker).
 */
export function humanizeRoleName(name: string): string {
	return name
		.split('_')
		.filter(Boolean)
		.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
		.join(' ');
}

/**
 * Stable, ordering-stable membership predicate. Returns true when the
 * account's `roles` array contains the role id.
 *
 * Defensive against non-array content (the field is optional on the
 * doctype).
 */
export function hasRole(roles: unknown, roleDocId: string): boolean {
	if (!Array.isArray(roles)) return false;
	return roles.some((r) => typeof r === 'string' && r === roleDocId);
}
