// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Schematic geometry — pure layout helpers.
 *
 * All functions here are pure and side-effect free, so they can be unit
 * tested without a DOM. They operate on the abstract {@link SchematicNode}
 * shape from `./types.ts`.
 *
 * Coordinate convention: a node's `x`/`y` is its top-left corner; `width`/
 * `height` extend rightward and downward.
 */
import type { SchematicNode } from './types.js';

/** Center of a node. */
export function center(n: SchematicNode): { x: number; y: number } {
	return { x: n.x + n.width / 2, y: n.y + n.height / 2 };
}

/**
 * Point where the line from node `a`'s center to node `b`'s center crosses
 * `a`'s border. Used to anchor edge endpoints on node borders rather than
 * centers, so arrows visually touch the box.
 */
export function borderPoint(a: SchematicNode, b: SchematicNode): { x: number; y: number } {
	const ca = center(a);
	const cb = center(b);
	return rayExit(a, ca, cb);
}

/**
 * Compute where a ray from `origin` toward `target` exits the rectangle
 * described by node `n`. Returns the origin itself if `target === origin`.
 */
function rayExit(
	n: SchematicNode,
	origin: { x: number; y: number },
	target: { x: number; y: number }
): { x: number; y: number } {
	const dx = target.x - origin.x;
	const dy = target.y - origin.y;
	if (dx === 0 && dy === 0) return origin;

	const hw = n.width / 2;
	const hh = n.height / 2;
	const cx = n.x + hw;
	const cy = n.y + hh;

	// Distance along the ray (in units of (dx,dy)) at which it crosses each
	// border plane. Take the smallest positive one — that's the exit point.
	const sx = dx !== 0 ? hw / Math.abs(dx) : Infinity;
	const sy = dy !== 0 ? hh / Math.abs(dy) : Infinity;
	const s = Math.min(sx, sy);

	return { x: cx + dx * s, y: cy + dy * s };
}

/**
 * Build a cubic-bezier path string (SVG `d`) from `from` to `to`, curving
 * horizontally away from the source. Matches the soft C-shape used in the
 * design mockup.
 */
export function bezierPath(from: SchematicNode, to: SchematicNode): string {
	const start = borderPoint(from, to);
	const end = borderPoint(to, from);
	const midX = (start.x + end.x) / 2;
	const c1x = start.x + (midX - start.x) * 0.5;
	const c2x = end.x + (midX - end.x) * 0.5;
	return `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} C ${c1x.toFixed(1)} ${start.y.toFixed(1)}, ${c2x.toFixed(1)} ${end.y.toFixed(1)}, ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
}

/**
 * Approximate the midpoint of a cubic bezier for label placement.
 * Good enough for short, mostly-horizontal edges used in the schematic.
 */
export function bezierMid(from: SchematicNode, to: SchematicNode): { x: number; y: number } {
	const start = borderPoint(from, to);
	const end = borderPoint(to, from);
	const midX = (start.x + end.x) / 2;
	const c1x = start.x + (midX - start.x) * 0.5;
	const c2x = end.x + (midX - end.x) * 0.5;
	// t = 0.5 on a cubic with P0=start, P1=(c1x,start.y), P2=(c2x,end.y), P3=end
	const t = 0.5;
	const omt = 1 - t;
	const x =
		omt * omt * omt * start.x + 3 * omt * omt * t * c1x + 3 * omt * t * t * c2x + t * t * t * end.x;
	const y =
		omt * omt * omt * start.y +
		3 * omt * omt * t * start.y +
		3 * omt * t * t * end.y +
		t * t * t * end.y;
	return { x, y };
}

/**
 * Compute a bounding box over all nodes with a small padding.
 * Returns `{ x, y, width, height }` suitable for an SVG `viewBox`.
 */
export function fitViewBox(
	nodes: SchematicNode[],
	padding = 24
): { x: number; y: number; width: number; height: number } {
	if (nodes.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
	const minX = Math.min(...nodes.map((n) => n.x)) - padding;
	const minY = Math.min(...nodes.map((n) => n.y)) - padding;
	const maxX = Math.max(...nodes.map((n) => n.x + n.width)) + padding;
	const maxY = Math.max(...nodes.map((n) => n.y + n.height)) + padding;
	return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}
