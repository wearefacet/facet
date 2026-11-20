// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * IdentityProps — the shared "who is signed in" prop block used by the
 * shell surfaces (`AppShell`, `NavPanel`, `SidebarShell`). One type keeps
 * the session fields identical across every shell that forwards them.
 */
export interface IdentityProps {
	/** Authenticated account (id + display name). */
	account?: { id: string; display_name: string } | null;
	/** Active role label from the session. */
	activeRole?: string | null;
	/** Roles the account is assigned; each can be activated via refresh. */
	availableRoles?: string[];
	/** The active role's connectivity channels (`me.connectivity`) — gates
	 * the affordances the channels govern (API keys, webhooks entries).
	 * Absent/empty = browser-only; the backend gates the channels. */
	connectivity?: string[];
	/** Called when the user picks a target role in the sidebar shell. */
	onSwitchRole?: (role: string) => Promise<void>;
}
