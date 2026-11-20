// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The document content shapes the Configure access pages read from
 * `iam.Account` and `iam.Roles`. One home instead of a private copy per
 * route file — the fields are optional because every consumer reads only
 * the slice it renders.
 */

/** Content of an `iam.Account` document (the fields the access pages read). */
export interface AccountContent {
	email?: string;
	name?: string;
	status?: string;
	roles?: string[];
	default_role?: string | null;
}

/**
 * The closed `connectivity` vocabulary — the programmatic channels an
 * `iam.Roles.connectivity` entry may name. Mirrors the backend hook and
 * `data/seeds/iam.Roles/definition.yml`.
 */
export const CONNECTIVITY_CHANNELS = ['mcp', 'webhook', 'api', 'assistant'] as const;

/** Content of an `iam.Roles` document (the fields the access pages read). */
export interface RoleContent {
	name?: string;
	/** Authority level (0–100); required by the doctype. */
	level?: number;
	description?: string;
	/** Field-tag visibility: a field is emitted to this role only when all its tags sit in this list. `["*"]` sees everything. */
	visible_tags?: string[];
	/** Programmatic channels the role may use (closed vocabulary: mcp, webhook, api, assistant). */
	connectivity?: string[];
	assistant_token_budget?: number | null;
}
