// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Mocked driver data for the OAuth consent screen stories.
 *
 * These fixtures mirror the shapes returned by `GET /OAuth/authorize` and
 * the `ConsentError` payloads produced by `src/oauth/routes.cr`. They let the
 * Storybook stories exercise every consent and error branch without a backend.
 *
 * The grant/effective-scope entries reflect the backend's resolution semantics:
 * `write` is already expanded to `{create, update}`, wildcard targets are
 * de-wildcarded per entry, and `actions` are concrete (never `write`, never `*`).
 */
import type { ConsentError, ConsentScreen, MCPScreen, UsableRole } from './oauthTypes';

/** One role, single-domain effective scope — the simple happy path. */
export const consentAcmePortal: ConsentScreen = {
	app: {
		id: '01J5K8Q3M2N7P9R0S1T2U3V4W5',
		client_id: '01J5K8Q3M2N7P9R0S1T2U3V4W6',
		slug: 'acme-portal',
		display_name: 'Acme Records Portal',
		description:
			'External customer portal for Acme Records — read access to contacts and invoices.',
		redirect_uris: ['https://portal.acme.example/callback'],
		allowed_origins: ['https://portal.acme.example'],
		status: 'active'
	},
	roles: [
		{
			role_id: 'production_editor',
			display_name: 'Edit projects and tasks you own or are assigned',
			effective_scope: [
				{
					target: 'production.Project',
					domain: 'production',
					path: ['Project'],
					actions: ['read', 'update', 'delete']
				},
				{
					target: 'production.Task',
					domain: 'production',
					path: ['Task'],
					actions: ['read', 'update', 'delete']
				}
			]
		}
	],
	state: 'xyz789abc',
	requested_scope: 'records:read'
};

/** Two roles, different scope shapes — the user must elect one. */
export const consentMultipleRoles: ConsentScreen = {
	app: {
		id: '01J5K8Q3M2N7P9R0S1T2U3V4W5',
		client_id: '01J5K8Q3M2N7P9R0S1T2U3V4W6',
		slug: 'acme-portal',
		display_name: 'Acme Records Portal',
		description:
			'External customer portal for Acme Records — read and write access across doctypes.',
		redirect_uris: ['https://portal.acme.example/callback'],
		allowed_origins: ['https://portal.acme.example'],
		status: 'active'
	},
	roles: [
		{
			role_id: 'editor',
			display_name: 'Full read/write access across all doctypes',
			effective_scope: [
				{
					target: 'crm.Contact',
					domain: 'crm',
					path: ['Contact'],
					actions: ['read', 'create', 'update', 'delete']
				},
				{
					target: 'crm.Invoice',
					domain: 'crm',
					path: ['Invoice'],
					actions: ['read', 'create', 'update']
				},
				{
					target: 'hr.Employee',
					domain: 'hr',
					path: ['Employee'],
					actions: ['read']
				}
			]
		},
		{
			role_id: 'viewer',
			display_name: 'Read-only access to all doctypes',
			effective_scope: [
				{
					target: 'crm.*',
					domain: 'crm',
					path: [],
					actions: ['read']
				},
				{
					target: 'hr.*',
					domain: 'hr',
					path: [],
					actions: ['read']
				}
			]
		}
	],
	state: 'xyz789abc',
	requested_scope: 'records:read'
};

/** One role, multiple domains — stresses the grants list rendering. */
export const consentRichScope: ConsentScreen = {
	app: {
		id: '01J5LAUNCH00DEADBEEF0000A1',
		client_id: '01J5LAUNCH00DEADBEEF0000A2',
		slug: 'console-prod',
		display_name: 'Operations Console',
		description:
			'Internal operations console covering CRM, HR, and inventory domains. Read and limited write access.',
		redirect_uris: ['https://console.facet.internal/oauth/callback'],
		allowed_origins: ['https://console.facet.internal'],
		status: 'active'
	},
	roles: [
		{
			role_id: 'operations',
			display_name: 'Operations console operator',
			effective_scope: [
				{
					// The merged shape for a wildcard ceiling plus a specific
					// grant: one entry per resolved doctype (the backend merges
					// same-coordinate entries and unions their actions), and
					// the original wildcard target stays as display metadata.
					target: 'crm.*',
					domain: 'crm',
					path: ['Contact'],
					actions: ['read', 'create', 'update']
				},
				{
					target: 'crm.*',
					domain: 'crm',
					path: ['Invoice'],
					actions: ['read', 'update']
				},
				{
					target: 'hr.Employee',
					domain: 'hr',
					path: ['Employee'],
					actions: ['read', 'update']
				},
				{
					target: 'inventory.StockItem',
					domain: 'inventory',
					path: ['StockItem'],
					actions: ['read', 'create', 'update', 'delete']
				},
				{
					target: 'inventory.StockMovement',
					domain: 'inventory',
					path: ['StockMovement'],
					actions: ['read', 'create']
				}
			]
		}
	],
	state: null,
	requested_scope: 'ops:full'
};

/** Roles array empty — triggers the "no eligible role" branch. */
export const consentNoRoles: ConsentScreen = {
	app: {
		id: '01J5K8Q3M2N7P9R0S1T2U3V4W5',
		client_id: '01J5K8Q3M2N7P9R0S1T2U3V4W6',
		slug: 'acme-portal',
		display_name: 'Acme Records Portal',
		description:
			'External customer portal for Acme Records — read access to contacts and invoices.',
		redirect_uris: ['https://portal.acme.example/callback'],
		allowed_origins: ['https://portal.acme.example'],
		status: 'active'
	},
	roles: [],
	state: 'xyz789abc',
	requested_scope: 'records:read'
};

/** Unknown client_id — the app is not registered. */
export const errorInvalidClient: ConsentError = {
	error: 'invalid_client',
	error_description: 'No application is registered for client_id "01NOTREAL0000000000000000".'
};

/** Redirect URI not on the app allow-list. */
export const errorInvalidRedirect: ConsentError = {
	error: 'invalid_request',
	error_description:
		'The redirect_uri "https://evil.example/callback" does not match any value registered for this application.'
};

/** Application disabled by an administrator. */
export const errorUnauthorizedClient: ConsentError = {
	error: 'unauthorized_client',
	error_description:
		'The application "acme-portal" is currently disabled. Contact a Facet administrator.'
};

/** Malformed request — missing PKCE challenge or method. */
export const errorInvalidRequest: ConsentError = {
	error: 'invalid_request',
	error_description: 'The code_challenge_method must be "S256".'
};

/**
 * Zero usable roles at POST time — the server returns HTTP 200 with this
 * redirect-eligible body. The component treats it as an error branch that
 * still surfaces the redirect URI so the route page can follow it.
 */
export const errorAccessDenied: ConsentError = {
	error: 'access_denied',
	error_description: 'The user has no role that satisfies the application requirements.',
	redirect_uri: 'https://portal.acme.example/callback?error=access_denied',
	state: 'xyz789abc'
};

/**
 * Convenience: which mock role to preselect in the multiple-roles story.
 * Not part of the backend payload — driven by the component's
 * `preselectedRoleId` prop in the corresponding story.
 */
export const multipleRolesDefaultPick: UsableRole['role_id'] = 'viewer';

/** Tagline copy for the Branded story — mirrors `LoginScreen`'s tagline prop. */
export const brandedProduct = {
	product: 'Northwind CRM',
	tagline: 'your sales, on facet'
};

/**
 * MCP consent screen — a single pinned role. Mirrors `serialize_mcp_consent`
 * in `src/oauth/routes.cr`: no `app` block, a `resource` identifier, the
 * redirect origin the user approves, and the pinned role pre-elected.
 */
export const mcpConsentSingle: MCPScreen = {
	mcp: true,
	resource: 'https://facet.localhost:3443/Api/_mcp/editor',
	roles: [
		{
			role_id: 'iam.Roles.editor',
			display_name: 'Edit projects and tasks you own or are assigned',
			effective_scope: [
				{
					target: 'production.Project',
					domain: 'production',
					path: ['Project'],
					actions: ['read', 'update', 'delete']
				},
				{
					target: 'production.Task',
					domain: 'production',
					path: ['Task'],
					actions: ['read', 'update', 'delete']
				}
			]
		}
	],
	pinned_role: 'iam.Roles.editor',
	redirect_origin: 'http://localhost:4004',
	state: 'mcp-state-123',
	requested_scope: null
};

/**
 * MCP consent screen — multiple held roles, no pinned role, so the user must
 * elect one. The redirect origin is the local agent callback.
 */
export const mcpConsentMultiple: MCPScreen = {
	mcp: true,
	resource: 'https://facet.localhost:3443/Api/_mcp/support',
	roles: [
		{
			role_id: 'iam.Roles.editor',
			display_name: 'Full read/write access across all doctypes',
			effective_scope: [
				{
					target: 'crm.Contact',
					domain: 'crm',
					path: ['Contact'],
					actions: ['read', 'create', 'update', 'delete']
				}
			]
		},
		{
			role_id: 'iam.Roles.viewer',
			display_name: 'Read-only access to all doctypes',
			effective_scope: [
				{
					target: 'crm.*',
					domain: 'crm',
					path: [],
					actions: ['read']
				}
			]
		}
	],
	pinned_role: null,
	redirect_origin: 'http://localhost:4004',
	state: 'mcp-state-456',
	requested_scope: null
};

/**
 * MCP consent screen — the admin role with a global `*.*` wildcard
 * permission. Exercises the "All domains" / "All actions" friendly labels.
 */
export const mcpConsentAdmin: MCPScreen = {
	mcp: true,
	resource: 'https://facet.localhost:3443/Api/_mcp/admin',
	roles: [
		{
			role_id: 'iam.Roles.admin',
			display_name: 'Full administrative access to all resources',
			effective_scope: [
				{
					target: '*.*',
					domain: '*',
					path: ['*'],
					actions: ['*']
				}
			]
		}
	],
	pinned_role: 'iam.Roles.admin',
	redirect_origin: 'http://localhost:4004',
	state: 'mcp-state-admin',
	requested_scope: null
};

/** MCP consent screen — the user holds no role usable for the resource. */
export const mcpConsentNoRoles: MCPScreen = {
	mcp: true,
	resource: 'https://facet.localhost:3443/Api/_mcp/editor',
	roles: [],
	pinned_role: null,
	redirect_origin: 'http://localhost:4004',
	state: 'mcp-state-789',
	requested_scope: null
};
