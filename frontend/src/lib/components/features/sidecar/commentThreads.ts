// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Thread assembly for the comment sidecar (`CommentSurface`).
 *
 * The flat list (oldest first) folds into a reply tree keyed by
 * `reply_to`. A data-level reply nests at any depth, but rendered
 * indentation caps at `MAX_INDENT` — deeper replies flatten into the
 * last indent bucket with a "replying to @author" note. The backend
 * accepts replies at any depth; the cap is presentation only.
 *
 * The list endpoint returns only live rows, so a tombstoned parent
 * leaves its replies without a parent row. `buildThreads` stands in a
 * synthetic `<deleted>` placeholder node at the root and nests the
 * live replies under it, so the chain below the break stays visible.
 */

import { untrack } from 'svelte';
import { SvelteMap } from 'svelte/reactivity';

/** One comment row as the sidecar list endpoint returns it. */
export type Comment = {
	meta: { id: string; display_name?: string | null; created_at: string };
	data: Record<string, unknown>;
};

/** Rendered depth cap — a reply deeper than this level flattens into the last bucket. */
export const MAX_INDENT = 3;

/** Synthetic id prefix for stand-in nodes whose parent row was
 * tombstoned. Real ids are ULIDs and never contain the prefix. */
export const DELETED_ID_PREFIX = 'deleted:';

export type ThreadNode = {
	row: Comment;
	parent: Comment | null;
	children: ThreadNode[];
	/** Stand-in for a tombstoned parent — synthesized, never a list row. */
	deleted: boolean;
};

export type ThreadEntry = {
	row: Comment;
	/** Rendered indent depth, clamped to `MAX_INDENT`. */
	depth: number;
	/** Set when the reply flattens past the indent cap — names the parent's author. */
	replyToName: string | null;
	/** Stand-in node rendering `<deleted>` in place of a tombstoned parent. */
	deleted: boolean;
	/** Live descendants; drives the collapse toggle. */
	descendantCount: number;
};

/** `reply_to` stores the qualified `core.Comment.<id>` form; ULIDs carry no dots. */
export function bareId(ref: unknown): string {
	const s = String(ref ?? '');
	return s ? s.slice(s.lastIndexOf('.') + 1) : '';
}

export function buildThreads(sorted: Comment[]): ThreadNode[] {
	// untrack: the caller runs this inside a `$derived` — a tracked read
	// plus the interleaved `set` write would self-dirty the map and loop
	// the derivation.
	const byId = untrack(() => {
		const map = new SvelteMap<string, ThreadNode>();
		for (const row of sorted) {
			map.set(row.meta.id, { row, parent: null, children: [], deleted: false });
		}
		const roots: ThreadNode[] = [];
		for (const row of sorted) {
			const node = map.get(row.meta.id)!;
			const parentId = bareId(row.data['reply_to']);
			const parent = parentId ? map.get(parentId) : undefined;
			if (parent) {
				node.parent = parent.row;
				parent.children.push(node);
			} else if (parentId) {
				// The parent is tombstoned and filtered from the list — stand in
				// a placeholder node so the replies keep their nesting. Replies
				// to the same deleted parent share one placeholder.
				const phId = DELETED_ID_PREFIX + parentId;
				let placeholder = map.get(phId);
				if (!placeholder) {
					placeholder = {
						row: { meta: { id: phId, display_name: null, created_at: '' }, data: {} },
						parent: null,
						children: [],
						deleted: true
					};
					map.set(phId, placeholder);
					roots.push(placeholder);
				}
				node.parent = placeholder.row;
				placeholder.children.push(node);
			} else {
				// True top-level comment.
				roots.push(node);
			}
		}
		return roots;
	});
	return byId;
}

function countDescendants(node: ThreadNode): number {
	let n = 0;
	for (const child of node.children) n += 1 + countDescendants(child);
	return n;
}

export function flattenThreads(
	roots: ThreadNode[],
	collapsedIds: Record<string, boolean>,
	authorNameOf: (ref: unknown) => string
): ThreadEntry[] {
	const out: ThreadEntry[] = [];
	const walk = (node: ThreadNode, depth: number): void => {
		const clamped = !node.deleted && depth > MAX_INDENT;
		out.push({
			row: node.row,
			depth: Math.min(depth, MAX_INDENT),
			replyToName: clamped && node.parent ? authorNameOf(node.parent.data['author']) : null,
			deleted: node.deleted,
			descendantCount: countDescendants(node)
		});
		if (collapsedIds[node.row.meta.id] === true) return;
		for (const child of node.children) walk(child, depth + 1);
	};
	for (const root of roots) walk(root, 0);
	return out;
}
