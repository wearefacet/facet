// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * `?view=` deep-link slugs for collection views.
 *
 * A view's URL token comes from its human-authored `name`: at runtime a
 * `core.CollectionView` id is an opaque ULID (the seed, the fixture import,
 * and the HTTP create all mint fresh ids), so the id carries no readable
 * slug. A view id that still follows the
 * `<qualified>.collection_view.<slug>` authoring convention (fixture
 * bundles, mock data) also answers to its id slug, so older links keep
 * working.
 */

/**
 * Fold a view name into a URL slug: lowercase, runs of non-alphanumeric
 * characters collapsed to one `_`, edges trimmed. `All Records` →
 * `all_records`, `By Probability` → `by_probability`. Returns `''` when
 * nothing alphanumeric survives.
 */
export function collectionViewSlug(name: string): string {
	return name
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '_')
		.replace(/^_+|_+$/g, '');
}

/**
 * The slug carried by a convention-following view id
 * (`crm.Deal.collection_view.open` → `open`), or `null` when the id does
 * not follow the convention (runtime views hold ULID ids).
 */
export function collectionViewIdSlug(viewId: string): string | null {
	const i = viewId.indexOf('collection_view.');
	if (i < 0) return null;
	return viewId.slice(i + 'collection_view.'.length) || null;
}

/**
 * Every slug a view answers to in a `?view=` deep link: the id slug first
 * (stable across renames for convention-authored views), then the name
 * slug (the only token a runtime ULID id carries). Deduplicated, non-empty.
 */
export function collectionViewDeepLinkSlugs(viewId: string, name: string): string[] {
	const out: string[] = [];
	for (const slug of [collectionViewIdSlug(viewId), collectionViewSlug(name)]) {
		if (slug && !out.includes(slug)) out.push(slug);
	}
	return out;
}
