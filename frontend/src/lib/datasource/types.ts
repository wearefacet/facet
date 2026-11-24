// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Core document types that mirror the backend's HTTP response shapes.
 *
 * All single-document endpoints return a `{ data, meta }` response shape.
 * Collection endpoints return `{ data: [...], meta: { count, more } }`.
 * See `doc/http-layer.md` in the backend project for the full specification.
 */

/** Metadata for a single document, from the HTTP `meta` response field. */
export interface DocumentMeta {
	id: string;
	mid: string;
	domain: string;
	doc_type: string;
	version: number;
	schema_version: number;
	/** Human-readable label (null when the doctype has no display_name template). */
	display_name?: string | null;
	created_at: string;
	updated_at: string;
	/**
	 * Parent document id (`meta->>'parent_id'`) for child doctypes — e.g. a
	 * `core.CollectionView` projection whose parent is its `core.DocType`
	 * projection (the qualified doctype name, e.g. `"crm.Opportunity"`).
	 * Absent on aggregate-root documents.
	 */
	parent_id?: string;
}

/** Response from a single-document endpoint (GET /:id, POST, PATCH, action). */
export interface DocumentResponse<T = Record<string, unknown>> {
	data: T;
	meta: DocumentMeta;
	/** Present only on compound create responses with nested children. */
	children?: Record<string, DocumentResponse<unknown>[]>;
}

/** An item in a collection response — matches the backend's per-item `{ data, meta }` response shape. */
export type ListItem<T = Record<string, unknown>> = { data: T; meta: DocumentMeta };

/** Response from collection endpoints (GET /:doctype, child list).
 *
 * Field-aggregate requests (`aggregate: 'sum' | 'avg' | 'min' | 'max'` +
 * `field`) deviate from this shape: the body is
 * `{ data: { value }, meta: { count, more: false } }` — `value` is a JSON
 * number for `integer` / `duration` fields and a `{ ticker => amount }
 * bag (decimal strings) for `money` fields, grouped per currency
 * (src/document/list/aggregate.cr). Datasource callers normalize that
 * shape themselves (see `lib/grid/summary.ts`).
 */
export interface ListResponse<T = Record<string, unknown>> {
	/**
	 * Each item is `{ data, meta }` — the same shape as a single-document response.
	 * `data` holds the user-defined content fields; `meta` holds system metadata.
	 */
	data: ListItem<T>[];
	meta: {
		count: number;
		more: boolean;
	};
}

/** Parameters accepted by {@link DataSource.list}. */
export interface ListParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
	/**
	 * When set to `'count'`, the backend runs only the capped COUNT subquery
	 * and returns an empty `data` array with the full filtered count in `meta`
	 * (capped at 1000 — same as the normal list path, but from offset 0 so
	 * the caller learns how many match irrespective of pagination). `page` and
	 * `items` are ignored when this is set.
	 *
	 * `filters` and `sort` apply normally — RBAC scope clauses are honored.
	 * The response uses the same `ListResponse` shape, so callers can drop the
	 * parameter to switch back to a normal list without changing types.
	 */
	aggregate?: 'count' | 'sum' | 'avg' | 'min' | 'max';
	/**
	 * Target field for a field aggregate (`aggregate: 'sum' | 'avg' | 'min' |
	 * 'max'`). Required for field aggregates, ignored for `count`. The backend
	 * answers 422 when the field is dotted, unknown, hidden, or of a type
	 * without numeric aggregate semantics (`integer`, `duration`, and `money`
	 * only — `List::Aggregate.AGGREGATE_FIELD_TYPES`).
	 */
	field?: string;
	/**
	 * When true, the backend returns tombstones (`deleted_at IS NOT NULL`)
	 * instead of live rows — the trash listing. Same pagination, RBAC scoping,
	 * and response shape as the live list; tombstone rows carry the retained
	 * pre-delete payload plus the surviving `display_name` / `meta` /
	 * `version` / timestamps. Also honored by `aggregate: 'count'`.
	 */
	includeDeleted?: boolean;
}

/** History query parameters accepted by {@link DocumentRef.history}. */
export interface HistoryParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
	/**
	 * Aggregate mode — merge the readable child documents' mutations into the
	 * timeline (backend `?include=children`). Rows of child doctypes carry
	 * `display_name`; the caller needs read access on each child doctype.
	 */
	include?: 'children';
}

/**
 * A single mutation record from the audit log.
 *
 * Mirrors the backend `Audit::List::MutationRecord` row returned by
 * `GET /Api/:domain/:doctype/:id/history`.
 */
export interface MutationRecord {
	/** ULID — mutation identifier. */
	id: string;
	/** Domain the mutation belongs to. */
	domain: string;
	/** Doctype of the target document. */
	doc_type: string;
	/** The document this mutation applies to. */
	doc_id: string;
	/** Sequential per-document index (starts at 1). */
	idx: number;
	/** One of `create`, `update`, `delete`, `snapshot`. */
	action: string;
	/** Identity that performed the mutation. */
	actioner_id: string;
	/** Action-specific payload (content for create, diff for update, etc.). */
	arguments: Record<string, unknown>;
	/**
	 * Content paths (array of segments, same form as diff paths) whose values
	 * the server removed from `arguments` before sending, because the calling
	 * role cannot see those fields (field-tag visibility). A redacted
	 * `diff.set` entry keeps its `path` but loses `value`/`patch`.
	 */
	redacted?: string[][];
	/** Authentication surface: `session | oauth_app | app_api_key | api_key | mcp | internal`. */
	channel: string;
	/** `app.App` projection id when the mutation came from an app token or an app-owned API key; `null` otherwise. */
	app?: string | null;
	/** `api_keys.id` row ULID when the mutation came through an API key; `null` otherwise. */
	api_key?: string | null;
	/** Qualified id of the role that authorized the write (e.g. `iam.Roles.admin`); `null` for internal and preview writes. */
	acting_role?: string | null;
	/** Direct trigger kind: `request | action | hook_event | hook_schedule | replication | cascade | rollback | migration | periodic_snapshot | webhook_test | assistant | compaction | seed`. */
	cause_kind: string;
	/** Action name, hook id, or replication binding descriptor; `null` when not applicable. */
	cause_name?: string | null;
	/** Resolved event name (`hired`, `updated`, …); `null` when not applicable. */
	cause_event?: string | null;
	/** The document the cause ran on, as `domain.Doctype:id`; `null` when not applicable. */
	cause_source?: string | null;
	/** Mutation ULID of the direct trigger; `null` for root mutations. */
	cause_parent?: string | null;
	/** Mutation ULID of the root of the causal cluster. */
	cause_trace: string;
	/** When the mutation was recorded. */
	emitted_at: string;
	/**
	 * Target document's label, from its projection row. Populated only in
	 * aggregate mode (`include: 'children'`); plain history leaves it unset.
	 * Tombstones keep their label.
	 */
	display_name?: string | null;
}

/**
 * Response shape of `GET /Api/:domain/:doctype/:id/history`.
 *
 * Mirrors the document-list response shape: `data` is the array of mutation
 * records, `meta` carries the capped count and `more` flag (see
 * `Helpers.capped_count` in the backend HTTP layer).
 */
export interface HistoryResponse {
	data: MutationRecord[];
	meta: {
		count: number;
		more: boolean;
	};
}

/**
 * One referring document from the backlinks endpoint — a stub row in the
 * shape the relation surfaces already consume.
 */
export interface BackrefItem {
	id: string;
	domain: string;
	doc_type: string;
	/** Label from the referrer's projection row (null when its doctype
	 *  declares no display_name template). */
	display_name: string | null;
}

/**
 * Query parameters accepted by {@link DocumentRef.backrefs}.
 */
export interface BackrefsParams {
	/** Cap on the number of returned rows (server max 1000, default 100). */
	items?: number;
}

/**
 * Response shape of `GET /Api/:domain/:doctype/:id/backrefs`.
 *
 * `meta.target` is the canonical URN the query ran against, `meta.total` the
 * returned row count, and `meta.capped` reports that the result set reached
 * the `items` cap (there may be more referrers than returned).
 */
export interface BackrefsResponse {
	data: BackrefItem[];
	meta: {
		target: string;
		total: number;
		capped: boolean;
	};
}

/** Response shape of `POST /Api/:domain/:doctype/:id/rollback`. */
export interface RollbackResponse {
	/** The restored document id. */
	id: string;
	domain: string;
	doc_type: string;
	/** ULID of the snapshot mutation produced by the rollback. */
	mut_id: string;
	/** Restored document content. */
	content: Record<string, unknown>;
	/** Creation timestamp of the document (preserved across rollback). */
	created_at: string;
}

/**
 * A single structured validation error reported by a 422 response.
 *
 * Mirrors the backend's `details` array on POST/PATCH validation failures.
 * `field` is a dot-separated path, or null/absent for non-field-scoped
 * errors (script/RBAC/compute/schema).
 */
export interface ValidationError {
	/** Dot-separated field path, or null for non-field errors (script/RBAC/compute/schema). */
	field?: string | null;
	message: string;
	/**
	 * Machine-readable category: "required" | "invalid_type" | "unknown_field" |
	 * "read_only" | "reserved" | "unique" | "invalid_format" | "out_of_range" |
	 * "script" | "compute" | "compute_runtime" | "rbac" | "context_set" |
	 * "named_scope" | "schema" | "argument" | (string for forward-compat).
	 */
	code?: string | null;
	/**
	 * Structured interpolations for a templated `code` (standardized names:
	 * `value`, `expected`, `format`, `allowed`, `min`, `max`, `reason`).
	 * Present only when the backend producer stamps it; `renderValidationError`
	 * uses it to build catalogue text, with `message` as the fallback.
	 */
	params?: Record<string, string> | null;
}

/** A generic API error thrown by datasource methods. */
export class DataSourceError extends Error {
	constructor(
		public readonly status: number,
		message: string,
		public readonly details?: ValidationError[],
		/** Flat extra fields from the error body (e.g. tombstone metadata on a `410`). */
		public readonly meta?: Record<string, unknown>
	) {
		super(message);
		this.name = 'DataSourceError';
	}
}
