// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataDriver } from '$lib/datasource/driver.js';
import { doctypeViewsCache } from '$lib/datasource/clientCache.js';
import type { TemplateNode } from '$lib/template-types.js';
import { VIEW_KINDS, type ViewKind } from '$lib/doctype/previewDocument.js';

/**
 * Loaded view template for a doctype, with metadata about which kind was used.
 *
 * {@link loadDoctypeView} resolves the best available template (preferring the
 * `view` kind for the full-page route, falling back to `quickView`). Callers
 * that only ever want one kind (e.g. the peek drawer) can use
 * {@link loadDoctypeViewByKind}.
 */
export interface LoadedView {
	/** The `kind` field of the `core.DocumentView` that was matched. */
	kind: string;
	/** The parsed template node, or `null` when no view document exists. */
	template: TemplateNode | null;
}

export interface RawDocumentView {
	kind?: string;
	template?: TemplateNode;
}

type DocumentViewChild = { data: RawDocumentView; meta: { id: string } };

/**
 * Every stored view of one doctype: the templates keyed by kind, plus the
 * `core.DocumentView` document id of each kind (the child id a PATCH targets).
 */
export interface DoctypeViews {
	templates: Partial<Record<ViewKind, TemplateNode | null>>;
	ids: Partial<Record<ViewKind, string>>;
}

/**
 * Fetch (with 60s browser TTL cache) the `core.DocumentView` children of a
 * `core.DocType` projection. The cache is keyed by the parent `core.DocType`
 * projection id, so a show-route load and a peek-drawer load for the same
 * doctype share one network round-trip.
 *
 * On the server there is no caching — `fetcher` is always invoked.
 */
/**
 * Fetch the `core.DocumentView` children of a `core.DocType` projection.
 *
 * With `{ fresh: true }` the cached entry is dropped first, so the fetch
 * re-runs even inside the TTL window. The result refills the cache.
 */
async function fetchDoctypeViews(
	driver: DataDriver,
	parentDocId: string,
	opts?: { fresh?: boolean }
): Promise<DocumentViewChild[]> {
	if (opts?.fresh) {
		// A route entry or an `invalidateAll()` re-run must see current data —
		// the cached list may be older than an external write. Drop the entry,
		// then re-fetch. The result refills the cache for the other surfaces.
		doctypeViewsCache.invalidate(parentDocId);
	}
	const cached = await doctypeViewsCache.get(parentDocId, async () => {
		// The nested child list route takes no `page` / `items` — it serves the
		// whole child collection (see `RestRoutes.render_child_list`).
		const res = await driver
			.domain('core')
			.doctype('DocType')
			.doc(parentDocId)
			.children<DocumentViewChild>('document_view')
			.list();
		return res.data;
	});
	return cached as DocumentViewChild[];
}

/**
 * Fetch the `core.DocumentView` children of a `core.DocType` projection and
 * return the first view matching `kind`, or `null` if none exists.
 *
 * Views are stored as `document_view` children of the `core.DocType`
 * projection identified by `parentDocId`. Each child's `data.kind` is one of
 * `view | form | inline | card | quickView` (see
 * `data/seeds/core.DocumentView/definition.yml`).
 *
 * Errors are swallowed — the caller renders a fallback UI when `template` is
 * null. This mirrors the original inline implementation in `ListView.svelte`.
 *
 * The children list is cached (see {@link fetchDoctypeViews}); callers asking
 * for different `kind`s of the same doctype share one fetch.
 */
export async function loadDoctypeViewByKind(
	driver: DataDriver,
	parentDocId: string,
	kind: string
): Promise<LoadedView> {
	try {
		const children = await fetchDoctypeViews(driver, parentDocId);
		const match = children.find((item) => item.data.kind === kind);
		return {
			kind,
			template: match?.data.template ?? null
		};
	} catch {
		return { kind, template: null };
	}
}

/**
 * Resolve the best full-page view template for a doctype.
 *
 * Tries the `view` kind first, then falls back to `quickView`. Returns
 * `{ kind, template: null }` when neither exists.
 */
export async function loadDoctypeView(
	driver: DataDriver,
	parentDocId: string
): Promise<LoadedView> {
	const view = await loadDoctypeViewByKind(driver, parentDocId, 'view');
	if (view.template) return view;
	return loadDoctypeViewByKind(driver, parentDocId, 'quickView');
}

/**
 * Fetch every `core.DocumentView` child of a `core.DocType` projection and
 * return the templates keyed by kind.
 *
 * A kind present in `VIEW_KINDS` but absent from the result has no stored
 * template (the builder preview renders a default fallback for it). Errors are
 * swallowed and an empty map returned — the caller renders fallbacks.
 *
 * Shares the same `doctypeViewsCache` as {@link loadDoctypeViewByKind}, so a
 * builder load and a show-route load for the same doctype share one fetch.
 *
 * The child ids are available through {@link loadDoctypeViewsWithIds} for the
 * callers that write the views back.
 */
export async function loadDoctypeViews(
	driver: DataDriver,
	parentDocId: string
): Promise<Partial<Record<ViewKind, TemplateNode | null>>> {
	return (await loadDoctypeViewsWithIds(driver, parentDocId)).templates;
}

/**
 * Same fetch as {@link loadDoctypeViews}, returning the `core.DocumentView`
 * document id of each kind alongside its template. The Views tab PATCHes the
 * stored child by that id; the preview only needs the templates.
 *
 * Shares the same `doctypeViewsCache` — the ids ride the cached children list,
 * so this costs no extra round-trip.
 *
 * Pass `{ fresh: true }` to skip the cache read: the fetch re-runs and refills
 * the cache. Use it where the caller needs current data — a fresh route entry
 * or an invalidation-driven re-run must not serve a list older than an
 * external write (a second tab, an assistant write).
 */
export async function loadDoctypeViewsWithIds(
	driver: DataDriver,
	parentDocId: string,
	opts?: { fresh?: boolean }
): Promise<DoctypeViews> {
	const templates: Partial<Record<ViewKind, TemplateNode | null>> = {};
	const ids: Partial<Record<ViewKind, string>> = {};
	try {
		const children = await fetchDoctypeViews(driver, parentDocId, opts);
		for (const child of children) {
			const kind = child.data.kind;
			if (kind && (VIEW_KINDS as readonly string[]).includes(kind)) {
				templates[kind as ViewKind] = child.data.template ?? null;
				ids[kind as ViewKind] = child.meta.id;
			}
		}
	} catch {
		return { templates: {}, ids: {} };
	}
	return { templates, ids };
}
