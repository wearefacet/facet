// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Frontend shapes for `app.App` documents and grants.
 *
 * These mirror the backend `app.App` definition
 * (`data/seeds/app.App/definition.yml`) and the grants shape documented in
 * `doc/frontend/app-configure.md`. They describe the wire format exchanged
 * with the Document API — the frontend never invents fields beyond those
 * the doctype schema declares.
 */

/**
 * One action declaration inside a grant. Mirrors the backend
 * `{ name, required }` object.
 *
 * - `name` — `read`, `write`, `delete`, or a named action declared on the
 *   target doctype. `write` is an alias that covers create and update.
 * - `required` — when `true`, a role that lacks this action is rejected;
 *   when `false`, the action contributes to the effective scope only when
 *   the role grants it.
 */
export type AppGrantAction = {
	name: string;
	required: boolean;
};

/**
 * A single grant entry. The `target` is either a qualified `domain.Doctype`
 * (e.g. `crm.Contact`) or a domain wildcard `domain.*` (e.g. `crm.*`).
 */
export type AppGrant = {
	target: string;
	actions: AppGrantAction[];
};

/**
 * A row in the doctype catalogue consumed by the grants picker. Built
 * from `core.DocType` list rows by `loadDoctypeCatalogue`. Only the
 * fields the picker reads are kept; the full projection is dropped.
 */
export type DoctypeCatalogueEntry = {
	/** Qualified `domain.Doctype` string, e.g. `crm.Contact`. */
	target: string;
	/** Doctype name (CamelCase, e.g. `Contact`). */
	label: string;
	/** Human-readable description shown under the doctype label. */
	description: string;
	/** Domain name (used to group the picker). */
	domain: string;
	/** Named actions declared on the doctype, shown as "Extra abilities". */
	namedActions?: { name: string; label: string }[];
	/**
	 * Human plural noun for the doctype (e.g. `contacts`, `company
	 * memberships`). Sourced from `core.DocType.plural_label`; when absent,
	 * `loadDoctypeCatalogue` fills in `appGrantsMapping.fallbackPlural` so the
	 * field is always present on a loaded catalogue.
	 */
	pluralLabel: string;
	/**
	 * Doctype-level sensitivity flag from `core.DocType.sensitive`. When
	 * true, the grants picker shows a lock icon and the consent preview notes
	 * that access is logged.
	 */
	sensitive?: boolean;
	/**
	 * Qualified parent target (`domain.ParentDoctype`) when this doctype is a
	 * child (i.e. `core.DocType.member_of` is set). `undefined` for aggregate
	 * roots. Used by the grants picker to nest children under their parent and
	 * to compute inheritance.
	 */
	parentTarget?: string;
	/** Icon name from `core.DocType.icon`, when declared. */
	icon?: string;
	/** Visual colour from `core.DocType.color`, when declared. */
	color?: string;
};

/**
 * Content of an `app.App` document. Carried in the `data` field of a
 * Document API response. Only fields the frontend reads or writes are
 * typed here; the backend doctype schema is the source of truth.
 */
export type AppContent = {
	slug: string;
	name: string;
	description?: string;
	client_id?: string;
	client_type?: 'public' | 'confidential';
	redirect_uris?: string[];
	allowed_origins?: string[];
	status?: 'draft' | 'active' | 'disabled';
	compatible_roles?: string[];
	owner_id?: string;
	grants?: AppGrant[];
	/**
	 * Qualified `iam.Roles` id the app's service account authenticates as.
	 * Set on backend (`confidential`) apps by the API-key issuance path.
	 */
	service_role_id?: string;
	/**
	 * `iam.Account` id of the app's service account. Created at first key
	 * issuance and linked back here; `undefined` until a key exists.
	 */
	service_account_id?: string;
	/**
	 * When true, the app never appears in the dashboard launcher. Headless
	 * registrations (the CLI tool) are reached through their client.
	 */
	no_launcher?: boolean;
	/**
	 * When true, the app is not a deploy target: the deploy route refuses
	 * it and it never gains a host.
	 */
	no_asset?: boolean;
	/**
	 * When true, the app may open assistant conversations through the chat
	 * package. The backend gate reads this field live on every create and
	 * every streamed message, so a flip applies on the next message.
	 */
	assistant_enabled?: boolean;
	/**
	 * The app's own assistant instructions, appended to the system prompt
	 * as the `App instructions` block. Optional — an empty value appends
	 * nothing. Baked into each conversation at creation, so a change
	 * reaches only new conversations.
	 */
	assistant_prompt?: string;
	/**
	 * Exact hostname Facet serves this app's active deployment at
	 * (e.g. `hr.app.company.tld`). Optional — an app without a host is
	 * never dispatched. Mirrors the backend `host` field.
	 */
	host?: string;
	/**
	 * Qualified `app.Deployment` id currently served at the app's host.
	 * Written by the deploy route's activate step; `undefined` until the
	 * first deploy.
	 */
	active_deployment?: string;
};

/** One entry of a deployment's files map: URL path + artifact id. */
export type DeploymentFileEntry = {
	/** Path relative to the app root, e.g. `index.html` or `assets/app.js`. */
	path: string;
	/** Artifact id; set by the deploy route's multipart intake. */
	file?: string;
};

/**
 * Content of an `app.Deployment` document — one uploaded build. Created
 * only by the deploy route (`POST /Api/app/:id/deploy`); the frontend
 * reads it for the deployment panel and history.
 */
export type DeploymentContent = {
	/** Qualified `app.App` id the build belongs to. */
	app_id?: string;
	/** Monotonically increasing per app (max + 1), computed by the deploy route. */
	revision?: number;
	/** Human label, e.g. "fix login bug". */
	note?: string;
	/** Unknown request paths fall back to `index.html` when true (default). */
	spa?: boolean;
	files?: DeploymentFileEntry[];
};
