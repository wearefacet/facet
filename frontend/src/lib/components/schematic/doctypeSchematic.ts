// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Doctype → schematic adapter.
 *
 * This is the only place that knows about Facet doctype definitions. It
 * reads a domain's doctype definitions from a {@link DataDriver}-shaped
 * registry and produces an abstract {@link Schematic} (nodes + edges) that
 * the generic `Schematic.svelte` component can render.
 *
 * Relationship encoding (mirrors the backend doctype system):
 *
 * - **Composition** (parent → child):
 *     - Declared on the root via `children: { <role>: { doctype, collection } }`.
 *     - Declared on the child via `member_of: <RootDoctype>`.
 *     - We union both directions, deduping by `(from, to)` so a child declared
 *       via `member_of` still draws one composition arrow from its root.
 * - **Reference** (root → referenced root):
 *     - Any field of `type: reference` whose target is an aggregate root that
 *       is *not* the same doctype and *not* a child of this doctype. We treat
 *       references to children as internal and skip them (they would be
 *       composition, already drawn).
 *
 * The layout is a simple deterministic column layout:
 *   column 0 = aggregate roots, column 1 = their children, with references
 *   routed between roots. It is good enough for the schematic overview and
 *   keeps the geometry pure and testable.
 */
import type { Schematic, SchematicEdge, SchematicNode } from './types.js';
import { mergePositions, type SchematicPositions } from './layout.js';
import { hashColor } from '$lib/utils/color.js';

/** Minimal driver surface this adapter needs — `MockDataDriver` satisfies it. */
export interface DoctypeRegistry {
	/** Map of `"domain.Doctype"` → definition record. */
	doctypeDefinitions: Map<string, Record<string, unknown>>;
}

/** Layout constants (schematic coordinate space, ~px). */
const NODE_W = 160;
const NODE_H = 56;
const COL_GAP = 220; // horizontal gap between columns
const ROW_GAP = 96; // vertical gap between rows
const PAD = 40;

/** Parsed view of a doctype definition relevant to the schematic. */
interface ParsedDoctype {
	qualified: string;
	domain: string;
	doctype: string;
	color?: string;
	icon?: string;
	aggregateRoot: boolean;
	memberOf?: string;
	/** `children` map: role → target doctype name (unqualified). */
	children: { role: string; doctype: string }[];
	/** Reference fields: role → qualified target doctype. */
	references: { role: string; target: string }[];
}

/**
 * Build a schematic for a single domain.
 *
 * @param registry  A driver with a `doctypeDefinitions` map (e.g. `MockDataDriver`).
 * @param domain    Domain name (e.g. `"hr"`, `"crm"`). Only doctypes whose
 *                  definition's `domain` field matches are included.
 * @param stored    Saved positions for this domain (`core.SchematicLayout`),
 *                  keyed by qualified doctype id. A node with a stored entry
 *                  keeps the saved corner; every other node keeps the
 *                  deterministic column position. Keys with no matching node
 *                  are ignored.
 */
export function buildDomainSchematic(
	registry: DoctypeRegistry,
	domain: string,
	stored?: SchematicPositions | null
): Schematic {
	const parsed = parseDomain(registry, domain);
	if (parsed.length === 0) return { nodes: [], edges: [] };

	const byName = new Map(parsed.map((p) => [p.doctype, p]));
	const byQualified = new Map(parsed.map((p) => [p.qualified, p]));

	// ── Nodes ─────────────────────────────────────────────────────────────
	// Roots in column 0, children in column 1.
	const roots = parsed.filter((p) => p.aggregateRoot);
	const children = parsed.filter((p) => !p.aggregateRoot);

	const nodes: SchematicNode[] = [];

	roots.forEach((r, i) => {
		nodes.push(toNode(r, PAD, PAD + i * (NODE_H + ROW_GAP), r.aggregateRoot ? 'root' : 'child'));
	});

	// Group children under their declared `member_of` root when possible;
	// otherwise stack them below the roots column.
	const childByRoot = new Map<string, ParsedDoctype[]>();
	for (const c of children) {
		const key = c.memberOf ?? '__orphan';
		const list = childByRoot.get(key) ?? [];
		list.push(c);
		childByRoot.set(key, list);
	}

	// Order children: those whose root exists first (grouped), then orphans.
	const orderedChildren: ParsedDoctype[] = [];
	for (const r of roots) {
		const list = childByRoot.get(r.doctype);
		if (list) orderedChildren.push(...list);
	}
	orderedChildren.push(...(childByRoot.get('__orphan') ?? []));

	orderedChildren.forEach((c, i) => {
		const rootLabel = c.memberOf ? `child of ${c.memberOf}` : 'child';
		nodes.push(toNode(c, PAD + COL_GAP, PAD + i * (NODE_H + ROW_GAP), 'child', rootLabel));
	});

	// Saved positions win over the computed column layout.
	if (stored) {
		const merged = mergePositions(nodes, stored);
		for (const n of nodes) {
			n.x = merged[n.id].x;
			n.y = merged[n.id].y;
		}
	}

	// ── Edges ────────────────────────────────────────────────────────────
	const edgeKey = (from: string, to: string, kind: string) => `${from}|${to}|${kind}`;
	const seen = new Set<string>();
	const edges: SchematicEdge[] = [];

	const addEdge = (e: SchematicEdge) => {
		const k = edgeKey(e.from, e.to, e.kind);
		if (seen.has(k)) return;
		seen.add(k);
		edges.push(e);
	};

	// Composition: from `children` declarations on roots.
	for (const r of roots) {
		for (const ch of r.children) {
			const target = byName.get(ch.doctype);
			if (!target) continue; // child not in this domain's registry
			addEdge({
				from: r.qualified,
				to: target.qualified,
				kind: 'composition',
				label: ch.role
			});
		}
	}
	// Composition: from `member_of` on children (dedup with above).
	for (const c of children) {
		if (!c.memberOf) continue;
		const root = byName.get(c.memberOf);
		if (!root) continue;
		addEdge({ from: root.qualified, to: c.qualified, kind: 'composition' });
	}

	// References: from `reference`-typed fields, only when target is a root
	// in the same domain and not a child of the source.
	for (const p of parsed) {
		for (const ref of p.references) {
			const target = byQualified.get(ref.target);
			if (!target) continue; // cross-domain reference — skip for now
			if (!target.aggregateRoot) continue; // internal to another aggregate
			if (target.qualified === p.qualified) continue;
			// Skip references that duplicate a composition edge.
			if (seen.has(edgeKey(p.qualified, target.qualified, 'composition'))) continue;
			addEdge({
				from: p.qualified,
				to: target.qualified,
				kind: 'reference',
				label: ref.role
			});
		}
	}

	return { nodes, edges };
}

/* ── helpers ─────────────────────────────────────────────────────────── */

function toNode(
	p: ParsedDoctype,
	x: number,
	y: number,
	taglineKind: 'root' | 'child',
	tagline?: string
): SchematicNode {
	return {
		id: p.qualified,
		label: p.doctype,
		color: p.color ?? hashColor(p.qualified),
		icon: p.icon,
		tagline: tagline ?? (taglineKind === 'root' ? 'aggregate root' : undefined),
		taglineKind,
		x,
		y,
		width: NODE_W,
		height: NODE_H
	};
}

function parseDomain(registry: DoctypeRegistry, domain: string): ParsedDoctype[] {
	const out: ParsedDoctype[] = [];
	for (const [qualified, def] of registry.doctypeDefinitions) {
		if (def['domain'] !== domain) continue;
		out.push(parseDoctype(qualified, def));
	}
	// Stable order by doctype name for deterministic layouts.
	return out.sort((a, b) => a.doctype.localeCompare(b.doctype));
}

function parseDoctype(qualified: string, def: Record<string, unknown>): ParsedDoctype {
	const doctype = str(def['doctype'], qualified.split('.').pop() ?? qualified);
	const domain = str(def['domain'], qualified.split('.')[0] ?? '');
	const color = def['color'] != null ? str(def['color'], undefined) : undefined;
	const icon = def['icon'] != null ? str(def['icon'], undefined) : undefined;
	const aggregateRoot = def['aggregate_root'] === true;
	const memberOf = def['member_of'] != null ? str(def['member_of'], undefined) : undefined;

	const children: { role: string; doctype: string }[] = [];
	const childrenMap = def['children'];
	if (childrenMap && typeof childrenMap === 'object') {
		for (const [role, entry] of Object.entries(childrenMap as Record<string, unknown>)) {
			if (entry && typeof entry === 'object') {
				const dt = (entry as Record<string, unknown>)['doctype'];
				if (typeof dt === 'string') children.push({ role, doctype: dt });
			}
		}
	}

	const references: { role: string; target: string }[] = [];
	const fields = def['fields'];
	if (fields && typeof fields === 'object') {
		for (const [role, field] of Object.entries(fields as Record<string, unknown>)) {
			if (!field || typeof field !== 'object') continue;
			const f = field as Record<string, unknown>;
			if (f['type'] === 'reference') {
				const target = f['doctype'];
				if (typeof target === 'string') references.push({ role, target });
			}
			// array of references — items.type === 'reference'
			if (f['type'] === 'array') {
				const items = f['items'];
				if (items && typeof items === 'object') {
					const it = items as Record<string, unknown>;
					if (it['type'] === 'reference' && typeof it['doctype'] === 'string') {
						references.push({ role, target: it['doctype'] as string });
					}
				}
			}
		}
	}

	return { qualified, domain, doctype, color, icon, aggregateRoot, memberOf, children, references };
}

function str(v: unknown, fallback: string | undefined): string {
	return typeof v === 'string' ? v : (fallback ?? '');
}
