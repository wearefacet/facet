// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Abstract schematic model — blocks and arrows.
 *
 * This module is intentionally free of any doctype knowledge. A schematic is
 * just a set of labelled, coloured nodes positioned on a 2D plane and a set
 * of directed edges between them. The doctype adapter (see
 * `./doctypeSchematic.ts`) is the only place that translates Facet doctype
 * definitions into this shape; any other domain model that can be expressed
 * as "boxes and arrows" can reuse the same components.
 */

/** Visual kind of an edge — drives marker shape and stroke style. */
export type EdgeKind = 'composition' | 'reference';

/**
 * A single block in the schematic.
 *
 * Position (`x`, `y`) is the top-left corner, in schematic coordinate space.
 * `color` is any CSS color string (hex, `var(--dt-*)`, etc.) used for the
 * node's accent stripe and diamond marker.
 */
export interface SchematicNode {
	/** Stable unique id (e.g. `"hr.Candidate"`). */
	id: string;
	/** Label shown in the node header. */
	label: string;
	/** Accent color (CSS color string). */
	color: string;
	/** Optional Lucide icon name (kebab-case) shown in the node marker. */
	icon?: string;
	/** Optional short tagline rendered under the label (e.g. "aggregate root"). */
	tagline?: string;
	/** Optional tagline kind — drives tagline styling. */
	taglineKind?: 'root' | 'child' | 'neutral';
	/** Top-left X in schematic space. */
	x: number;
	/** Top-left Y in schematic space. */
	y: number;
	/** Node width in schematic space. */
	width: number;
	/** Node height in schematic space. */
	height: number;
}

/**
 * A directed edge between two nodes.
 *
 * Endpoints are computed from node geometry at render time; consumers only
 * need to declare `from`, `to`, `kind`, and an optional `label`.
 */
export interface SchematicEdge {
	/** Source node id. */
	from: string;
	/** Target node id. */
	to: string;
	/** Visual kind — composition (solid + filled diamond at the owner) or reference (dashed + open arrow). */
	kind: EdgeKind;
	/** Optional edge label (e.g. the relationship role name). */
	label?: string;
}

/** A complete schematic: nodes + edges. */
export interface Schematic {
	nodes: SchematicNode[];
	edges: SchematicEdge[];
}
