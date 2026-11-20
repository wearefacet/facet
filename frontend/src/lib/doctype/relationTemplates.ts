// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Template loader for relation surfaces.
 *
 * Loads the pieces a relation surface (the `relation` template node
 * renderer) needs for its rows: the relation doctype's definition and the
 * view template matching the render mode — `form` for editable relations,
 * `inline` (with a `quickView` fallback) for read mode. Capsule mode needs
 * neither.
 *
 * A `null` template means the load settled and found no stored view. The
 * renderer owns the next fallback: read rows degrade to capsules; editable
 * rows render a generic field walk over the child definition (the same
 * fallback the parent form uses for a doctype without a DVT).
 *
 * Pure loader — no reactive state. The caller owns the cache state and the
 * cancellation counter; this module decides which pieces are still missing
 * and fetches only those.
 */

import type { DataDriver } from '$lib/datasource/driver.js';
import type { TemplateNode } from '$lib/template-types.js';
import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
import { loadDoctypeViewByKind } from './loadDocumentView.js';
import { parseDoctypeDef, type DoctypeDef } from './types.js';

/** Cache state a relation surface holds across renders. */
export interface RelationTemplateCache {
	/** Relation doctype definition — `undefined` until resolved. */
	relationDef?: DoctypeDef;
	/** Child `form` template for editable mode. `undefined` = not loaded;
	 *  `null` = no stored `form` view — the renderer walks the definition. */
	formTemplate?: TemplateNode | null;
	/** Child `inline`/`quickView` template for read mode. `undefined` = not loaded. */
	inlineTemplate?: TemplateNode | null;
}

export interface RelationTemplateMode {
	/** Editable relations render the child `form` template. */
	editable: boolean;
}

/**
 * Load the cache pieces the current render still needs.
 *
 * Mock drivers expose `doctypeDefinitions` synchronously; HTTP drivers go
 * through the 60s-TTL `DoctypeRegistry.cached` snapshot. Inline read mode
 * prefers the dedicated `inline` kind and falls back to `quickView`
 * (mirroring `loadDoctypeView`'s view→quickView chain).
 *
 * Returns only the keys it resolved. A resolved key may carry `null` — that
 * is a settled "no stored view" result, not an absent key. Merge by key
 * presence (`if (update.formTemplate !== undefined) …`), never with `??`:
 * `null ?? undefined` folds the settled result back into "not loaded" and
 * the surface re-fetches forever. Throws on fetch failure; the caller decides the fallback (the
 * relation renderer nulls the template, so editable rows fall back to the
 * generic field walk and read rows fall back to capsules).
 */
export async function loadRelationTemplates(
	driver: DataDriver,
	qualifiedRelation: string,
	cache: RelationTemplateCache,
	mode: RelationTemplateMode
): Promise<Partial<RelationTemplateCache>> {
	const update: Partial<RelationTemplateCache> = {};

	if (!cache.relationDef) {
		const md = driver as unknown as {
			doctypeDefinitions?: Map<string, Record<string, unknown>>;
		};
		if (md.doctypeDefinitions instanceof Map) {
			const raw = md.doctypeDefinitions.get(qualifiedRelation);
			if (raw) update.relationDef = parseDoctypeDef(raw);
		} else {
			const reg = await DoctypeRegistry.cached(driver);
			const raw = reg.doctypeDefinitions.get(qualifiedRelation);
			if (raw) update.relationDef = parseDoctypeDef(raw);
		}
	}

	if (mode.editable) {
		if (cache.formTemplate === undefined) {
			const form = await loadDoctypeViewByKind(driver, qualifiedRelation, 'form');
			update.formTemplate = form.template;
		}
	} else if (cache.inlineTemplate === undefined) {
		const inline = await loadDoctypeViewByKind(driver, qualifiedRelation, 'inline');
		if (inline.template) {
			update.inlineTemplate = inline.template;
		} else {
			const quick = await loadDoctypeViewByKind(driver, qualifiedRelation, 'quickView');
			update.inlineTemplate = quick.template ?? null;
		}
	}

	return update;
}
