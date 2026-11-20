// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type {
	BackrefsParams,
	BackrefsResponse,
	DocumentResponse,
	HistoryParams,
	HistoryResponse,
	ListParams,
	ListResponse,
	RollbackResponse
} from './types.js';

/**
 * A reference to a single document within a {@link DataSource}.
 *
 * Carries the document identity so you can perform document-level operations
 * (show, update, delete, action) and navigate to child collections without
 * fetching the parent first.
 */
export interface DocumentRef<T = Record<string, unknown>> {
	/** Fetch the full document projection. */
	show(): Promise<DocumentResponse<T>>;

	/** Apply an incremental update (JsonDiff format). */
	update(diff: unknown): Promise<DocumentResponse<T>>;

	/** Soft-delete the document. */
	delete(): Promise<void>;

	/** Execute a named action defined on the doctype. */
	action(actionName: string, args?: Record<string, unknown>): Promise<DocumentResponse<T>>;

	/**
	 * Drop any cached projection of this document.
	 *
	 * Call after the document was mutated through a path that bypassed this
	 * ref — a bespoke endpoint (e.g. the IAM credential routes) rather than
	 * `update` / `delete` / `action`, which invalidate their own cached reads.
	 * The next `show()` refetches instead of serving the stale cached body.
	 * Synchronous, no network call.
	 */
	invalidate(): void;

	/**
	 * List the mutation history for this document.
	 *
	 * Returns an append-only audit trail of `create`, `update`, `delete`,
	 * and `snapshot` mutations, newest first by default.
	 */
	history(params?: HistoryParams): Promise<HistoryResponse>;

	/**
	 * Rollback the document to the state it had at the given mutation.
	 *
	 * The backend replays mutations forward from the nearest snapshot to the
	 * target ULID and writes a new `snapshot` mutation — the document is not
	 * destroyed; the audit trail remains intact.
	 *
	 * @param mutationId  ULID of the mutation to roll back to.
	 */
	rollback(mutationId: string): Promise<RollbackResponse>;

	/**
	 * Restore a deleted (tombstoned) document.
	 *
	 * The backend resolves the mutation immediately before the document's
	 * most recent `delete` and rolls back to it — the replay skips the delete
	 * and the resulting snapshot restores the live content. Gated by the
	 * `update` RBAC action, like any other write.
	 *
	 * Rejects with {@link DataSourceError} `409` when the document is not
	 * deleted (a safe no-op — the caller should refresh instead of retrying).
	 */
	restore(): Promise<RollbackResponse>;

	/**
	 * List the live documents that reference this document (backlinks).
	 *
	 * Served by the `links` column's partial GIN index: the referrer side
	 * skips doctypes the caller cannot read and applies each readable
	 * doctype's list scope, so unreadable referrers never appear. A missing,
	 * tombstoned, or denied target rejects with {@link DataSourceError} `404`
	 * (non-disclosing).
	 */
	backrefs(params?: BackrefsParams): Promise<BackrefsResponse>;

	/**
	 * Navigate to a child collection.
	 *
	 * Returns a new `DataSource` scoped to the child relationship, so you can
	 * list, create, and further navigate.
	 */
	children<C = Record<string, unknown>>(relName: string): DataSource<C>;

	/**
	 * Navigate to a sidecar collection attached to this document.
	 * Same shape as children(); the backend serves both under
	 * /Api/:domain/:doctype/:id/:segment. Semantically distinct at call
	 * sites: mock drivers filter sidecar records by the sidecar's column
	 * reference pointing at the host, not by parent_id.
	 */
	sidecars<C = Record<string, unknown>>(segment: string): DataSource<C>;
}

/**
 * A DataSource represents a doctype collection.
 *
 * Collection-level operations (list, create) live here.
 * Document-level operations (show, update, delete, action) and child
 * navigation are accessed via {@link DataSource.doc}.
 */
export interface DataSource<T = Record<string, unknown>> {
	/** List documents with pagination, filtering, and sorting. */
	list(params?: ListParams): Promise<ListResponse<T>>;

	/** Create a new document in this collection. */
	create(content: T): Promise<DocumentResponse<T>>;

	/**
	 * Navigate to a single document by ID.
	 *
	 * Returns a lightweight {@link DocumentRef} — no network call is made
	 * until you call `.show()`, `.update()`, etc.
	 */
	doc(id: string): DocumentRef<T>;
}
