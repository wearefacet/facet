// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reactive active-role store for the frontend.
 *
 * The backend ships the user's active role id and the list of roles they are
 * assigned in every `/Api/iam/me`, login, and token-refresh response. The
 * layout load and the role-switch action feed this store so that the sidebar
 * footer (label) and the "Switch Role" submenu (available roles) re-render
 * when the active role changes.
 *
 * Role ids follow the convention `iam.Roles.{name}` (see
 * `data/seeds/iam.Roles/documents.yml`). The `name` — everything after the
 * last dot — is the human-facing label shown in the UI.
 */

import { humanizeRoleName } from './authorization/roleMembership.js';

let activeRole: string | null = $state(null);
let availableRoles: string[] | null = $state(null);

// Reads and writes are gated on the browser. Module-level state on the server
// would be shared across concurrent users doing SSR; during SSR the layout
// falls back to its per-request `data` snapshot instead. `availableRoles` starts
// as `null` (not yet hydrated) so callers can distinguish "unknown" from a
// genuinely empty role list and opt into the `data` snapshot as a fallback.
export function setRole(active: string | null, available: string[] | null | undefined): void {
	if (typeof window === 'undefined') return;
	activeRole = active ?? null;
	availableRoles = Array.isArray(available) ? available : [];
}

export function getActiveRole(): string | null {
	if (typeof window === 'undefined') return null;
	return activeRole;
}

/** Returns the user's assigned roles, or `null` before the layout hydrates it. */
export function getAvailableRoles(): string[] | null {
	if (typeof window === 'undefined') return null;
	return availableRoles;
}

/**
 * The human-facing label for a role id (`iam.Roles.admin` → `Admin`).
 * Returns a dash when no role is given.
 */
export function activeRoleLabel(role: string | null | undefined): string {
	if (!role) return '—';
	const i = role.lastIndexOf('.');
	return humanizeRoleName(i === -1 ? role : role.slice(i + 1));
}
