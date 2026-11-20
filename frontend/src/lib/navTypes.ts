// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Sidebar navigation types.
 *
 * `NavDomain` and `NavDoctype` describe the nav model that `NavPanel.svelte`
 * renders. They live here so lib modules and route loads import a type module,
 * not a component.
 */

/** A doctype entry rendered in the nav panel. */
export interface NavDoctype {
	/** Qualified name, e.g. `"crm.Company"`. */
	qualified: string;
	/** Display label, e.g. `"Company"`. */
	label: string;
	/** Hex color from the doctype definition. */
	color: string;
	/** Optional Lucide icon name (kebab-case) shown in the nav mark. */
	icon?: string | null;
	/** Composition children nested under this entry (same domain, `member_of`
	 *  targets this doctype). Absent when the doctype has no children. Order
	 *  follows the doctype registry. */
	children?: NavDoctype[];
	/** Document count in this doctype. `undefined` until the lazy count fetch
	 *  resolves; `0` means "fetched and empty". Filled lazily by
	 *  `navCounts.svelte.ts` when the doctype's domain becomes active. */
	count?: number;
	/** Whether the user pinned this doctype to the top of the sidebar. */
	pinned?: boolean;
}

/** A domain rendered in the nav panel. */
export interface NavDomain {
	/** Domain id, e.g. `"crm"`. */
	id: string;
	/** Display label, e.g. `"CRM"`. */
	label: string;
	/** Hex color from the domain document. */
	color: string;
	/** Top-level doctypes of this domain. Composition children hang off each
	 *  entry's `children` — flatten with {@link flattenNavDoctypes} for a flat
	 *  walk (counts, search, palette). */
	doctypes: NavDoctype[];
	/** ISO-8601 timestamp of the last mutation on this domain document. */
	updatedAt?: string;
}

/**
 * Flattens a nav doctype tree into a depth-first list (parents before their
 * children). Pure — consumers that cannot render a tree (counts, search,
 * palette, dashboards) walk the flat list instead.
 */
export function flattenNavDoctypes(doctypes: NavDoctype[]): NavDoctype[] {
	const out: NavDoctype[] = [];
	const walk = (list: NavDoctype[]) => {
		for (const dt of list) {
			out.push(dt);
			if (dt.children?.length) walk(dt.children);
		}
	};
	walk(doctypes);
	return out;
}
