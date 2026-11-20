// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure URL → navigation-state helpers for the root layout.
 *
 * Turns the current pathname into the top-bar crumbs, the active doctype
 * qualifier, and the BuilderModeBar status line. The layout keeps the
 * reactive reads (`page.url.pathname`, route flags, nav domains) and passes
 * them in; these functions stay free of SvelteKit and store imports so they
 * run in plain Vitest. `m.*` is allowed here (precedent: `loginFlow.ts`).
 */

import * as m from '$lib/paraglide/messages';
import type { Crumb } from '$lib/components/primitives/surfaces/Topbar.svelte';
import type { NavDomain, NavDoctype } from '$lib/navTypes';

/** Options for {@link buildCrumbs}. */
export interface BuildCrumbsOptions {
	/** True on any `/Builder` route — the domain segment is then segment 1. */
	isBuilderRoute: boolean;
	/** Resolves a domain id to its display label (falls back to the id). */
	labelFor: (domainId: string) => string;
	/**
	 * Resolves a document id to its display label (falls back to the id) —
	 * the same rule the show page uses: `meta.display_name ?? id`. When
	 * omitted, the id segment renders capitalized as before.
	 */
	docLabelFor?: (docId: string) => string;
}

/** The decoded `(domain, doctype, id)` parts of a live document route. */
export interface DocumentRef {
	domain: string;
	doctype: string;
	id: string;
}

/**
 * Splits a live document route into its decoded parts.
 *
 * Matches `/{domain}/{doctype}/{id}` and its `/edit` and `/history`
 * siblings. The create form at `/{domain}/{doctype}/new` is a static
 * sibling route — its third segment is the literal `new`, not an id, so
 * this returns `null` there. Builder routes host no document pages.
 * Returns `null` for every other shape, and for a segment that carries a
 * broken percent-escape.
 */
export function documentRefOf(pathname: string, isBuilderRoute: boolean): DocumentRef | null {
	if (isBuilderRoute) return null;
	const segs = pathname.split('/').filter(Boolean);
	if (segs.length < 3) return null;
	if (segs[2] === 'new') return null;
	try {
		return {
			domain: decodeURIComponent(segs[0]),
			doctype: decodeURIComponent(segs[1]),
			id: decodeURIComponent(segs[2])
		};
	} catch {
		return null;
	}
}

/**
 * Builds the top-bar crumbs from the pathname. The first segment of a live
 * route and the second segment of a builder route are domain ids — they
 * resolve through `labelFor`; every other segment renders capitalized. On a
 * live document route the id segment resolves through `docLabelFor` (when
 * given) and keeps the raw id in its `title` for copyability.
 */
export function buildCrumbs(pathname: string, opts: BuildCrumbsOptions): Crumb[] {
	const segs = pathname.split('/').filter(Boolean);
	if (segs.length === 0) return [{ label: m.nav_dashboard() }];
	const docLabelFor = opts.docLabelFor;
	const docRef = docLabelFor ? documentRefOf(pathname, opts.isBuilderRoute) : null;
	return segs.map((seg, i) => {
		// The domain segment carries the raw id, not a display label:
		//   live   /{domain}/...      → segment 0
		//   builder /Builder/{draft}/... → segment 1
		// Resolve it through the nav model so the navbar shows the human label
		// (e.g. "CRM" instead of "Crm").
		let label = seg.charAt(0).toUpperCase() + seg.slice(1);
		let title: string | undefined;
		if (opts.isBuilderRoute && i === 1) {
			label = opts.labelFor(seg);
		} else if (!opts.isBuilderRoute && i === 0) {
			label = opts.labelFor(seg);
		} else if (docRef !== null && docLabelFor !== undefined && i === 2) {
			// The document id segment: the label follows the show page's own
			// rule (`meta.display_name ?? id`); the raw id rides the title.
			label = docLabelFor(seg);
			title = seg;
		}
		const href = i < segs.length - 1 ? '/' + segs.slice(0, i + 1).join('/') : undefined;
		return { label, href, title };
	});
}

/**
 * Derives the active doctype qualifier ("domain.Doctype") from the URL.
 * Live: `/crm/Company` → "crm.Company"
 * Builder: `/Builder/_abc/Company/logic` → "_abc.Company"
 *
 * The label match walks the full nav tree — composition children nest under
 * their parent, so a child URL must resolve through the parent's subtree.
 *
 * Returns `undefined` when the URL names no doctype or the doctype is not in
 * the given nav model.
 */
export function resolveActiveDoctype(
	pathname: string,
	domains: readonly NavDomain[],
	isBuilderRoute: boolean
): string | undefined {
	const segs = pathname.split('/').filter(Boolean);
	if (segs.length < 2) return undefined;
	let domainId: string;
	let doctypeId: string;
	if (isBuilderRoute) {
		// /Builder/[draftDomain]/[doctype]/[[tab]]
		if (segs.length < 3) return undefined;
		domainId = segs[1];
		doctypeId = decodeURIComponent(segs[2]);
	} else {
		domainId = segs[0];
		doctypeId = decodeURIComponent(segs[1]);
	}
	const domain = domains.find((d) => d.id === domainId);
	if (!domain) return undefined;
	const walk = (list: readonly NavDoctype[]): string | undefined => {
		for (const dt of list) {
			if (dt.label === doctypeId) return dt.qualified;
			if (dt.children?.length) {
				const hit = walk(dt.children);
				if (hit) return hit;
			}
		}
		return undefined;
	};
	return walk(domain.doctypes);
}

/**
 * Status line for the BuilderModeBar — reflects the active draft domain.
 * Returns `undefined` off the builder routes.
 */
export function builderStatusLabel(
	isBuilderRoute: boolean,
	activeDomainId: string,
	domains: readonly NavDomain[]
): string | undefined {
	if (!isBuilderRoute) return undefined;
	const active = domains.find((d) => d.id === activeDomainId);
	return active ? m.builder_status_editing({ name: active.label }) : m.builder_status_no_draft();
}
