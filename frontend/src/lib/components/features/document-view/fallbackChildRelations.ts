// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { humanize } from '$lib/doctype/types.js';
import type { DoctypeDef } from '$lib/doctype/types.js';
import type { RelationNode } from '$lib/template-types';

/** One fallback children section — the `DvtRelation` node plus its identity. */
export interface FallbackChildRelation {
	/** The `children` entry key on the parent doctype. */
	rel: string;
	/** Section label — humanized entry key. */
	label: string;
	/** Qualified child doctype (`{domain}.{Doctype}`). */
	qualifiedDoctype: string;
	/** The `relation` node `DvtRelation` renders. */
	node: RelationNode;
}

/**
 * One relation section per `def.children` entry, built straight from the
 * definition — the no-template fallback both the form (editable, drafts
 * persisted through the values bag) and the show page (read-only display)
 * render through `DvtRelation`.
 */
export function buildFallbackChildRelations(
	def: DoctypeDef,
	editable: boolean
): FallbackChildRelation[] {
	return def.children.map((child) => {
		const node: RelationNode = {
			type: 'relation',
			label: humanize(child.key),
			doctype: `${def.domain}.${child.doctype}`,
			source: { kind: 'children', rel: child.key },
			editable
		};
		return { rel: child.key, label: node.label, qualifiedDoctype: node.doctype, node };
	});
}
