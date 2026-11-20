// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * OAuth Consent Screen — TypeScript types.
 *
 * These mirror the JSON serializers in `src/oauth/routes.cr`
 * (`serialize_consent`, `serialize_issued_code`, `serialize_effective_scope`)
 * and the `Authorize::App` / `Authorize::UsableRole` / `RBAC::EffectiveScope`
 * Crystal structs. Field names are verbatim from the backend serializers.
 *
 * The role and permission types already exist in
 * `frontend/src/lib/components/features/admin/rbacModel.ts` — this module
 * only declares the OAuth-specific shapes the consent surface needs.
 */

/** Application lifecycle status. Only `active` apps reach the consent screen. */
export type AppStatus = 'draft' | 'active' | 'disabled';

/**
 * The app subset returned by `GET /OAuth/authorize` — a 7-field projection
 * of `app.App.content`, NOT the full stored document. Grants, compatible_roles,
 * owner_id and client_type are intentionally absent; the effective
 * scope per role is precomputed server-side and exposed via
 * `UsableRole.effective_scope`.
 */
export interface ConsentApp {
	id: string;
	client_id: string;
	slug: string;
	display_name: string;
	description: string | null;
	redirect_uris: string[];
	allowed_origins: string[];
	status: AppStatus;
}

/**
 * One resolved entry of the grant ∩ role intersection.
 * `actions` already has `write` expanded to `{create, update}` by the backend.
 */
export interface EffectiveScopeEntry {
	/** Original grant target string, e.g. `"crm.*"` or `"crm.Contact"`. */
	target: string;
	/** De-wildcarded domain, e.g. `"crm"`. */
	domain: string;
	/** De-wildcarded doctype path, e.g. `["Contact"]` or `["Contact","Comment"]`. */
	path: string[];
	/** Concrete action names the role permits: `read`|`create`|`update`|`delete`|named. */
	actions: string[];
}

/** A role the user holds that is usable with this app + its resolved effective scope. */
export interface UsableRole {
	/** The `iam.Roles.name` (e.g. `"production_editor"`). */
	role_id: string;
	/** Sourced from `iam.Roles.description`. May be null when the role has no description. */
	display_name: string | null;
	effective_scope: EffectiveScopeEntry[];
}

/** `GET /OAuth/authorize` — 200 consent payload. */
export interface ConsentScreen {
	app: ConsentApp;
	/** Empty array means the user has no eligible role for this app. */
	roles: UsableRole[];
	/** Opaque client string, echoed from the request's `state` param. */
	state: string | null;
	/** Opaque client string, echoed from the request's `scope` param. The server does not parse it. */
	requested_scope: string | null;
}

/**
 * `GET /OAuth/authorize` — 200 MCP consent payload. Returned when the
 * request carries an RFC 8707 `resource` naming a per-role MCP identifier.
 * Mirrors `serialize_mcp_consent` in `src/oauth/routes.cr`. There is no `app`
 * block — MCP is not an app (decision D5).
 */
export interface MCPScreen {
	/** Always `true` — discriminator between the app and MCP shapes. */
	mcp: true;
	/** The RFC 8707 resource identifier the token will be minted for. */
	resource: string;
	/** Every role the user holds, each with its live effective scope. */
	roles: UsableRole[];
	/** When the request pins a role (the `:role_slug` from the MCP URL), its id. */
	pinned_role: string | null;
	/** The scheme+host+port of the redirect URI — what the user approves. */
	redirect_origin: string;
	/** Opaque client string, echoed from the request's `state` param. */
	state: string | null;
	/** Opaque client string, echoed from the request's `scope` param. */
	requested_scope: string | null;
}

/** `POST /OAuth/authorize` — 200 success body. Issued to the component caller. */
export interface IssuedCode {
	redirect_uri: string;
	/** 60-second, single-use authorization code. */
	code: string;
	state: string | null;
	app_id: string;
	role_id: string;
	/** RFC 9207 — the AS issuer; the page forwards it on the redirect so the client can verify the code origin. */
	iss: string;
}

/**
 * OAuth 2.0 error codes the consent route emits. See
 * `src/oauth/authorize.cr` — `invalid_request`, `invalid_client`,
 * `unauthorized_client` are 4xx; `access_denied` is HTTP 200 with a
 * redirect-eligible body.
 */
export type OAuthErrorCode =
	| 'invalid_request'
	| 'invalid_client'
	| 'unauthorized_client'
	| 'access_denied';

/** A structural error rendering instead of the consent form. */
export interface ConsentError {
	error: OAuthErrorCode;
	error_description: string;
	/** Present on `access_denied` — the redirect the app expects us to follow. */
	redirect_uri?: string;
	state?: string | null;
}

/** The role-election payload emitted by the component via `onconsent`. */
export interface ConsentChoice {
	role_id: string;
}
