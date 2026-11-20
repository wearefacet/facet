// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	bareId,
	buildThreads,
	flattenThreads,
	MAX_INDENT,
	DELETED_ID_PREFIX,
	type Comment,
	type ThreadNode
} from './commentThreads.js';

/** Author refs mapped to display names — a stand-in for the surface's ref resolution. */
const AUTHORS: Record<string, string> = {
	'iam.Account.account_kim': 'Kim Park',
	'iam.Account.account_rex': 'Rex Mundi'
};

const KIM = 'iam.Account.account_kim';
const REX = 'iam.Account.account_rex';

const authorNameOf = (ref: unknown): string => AUTHORS[String(ref)] ?? 'Unknown';

function rowOf(id: string, data: Record<string, unknown>): Comment {
	return { meta: { id, display_name: null, created_at: '2026-01-01T00:00:00Z' }, data };
}

/** Top-level comment: the data carries no `reply_to`. */
function topLevel(id: string, author: string): Comment {
	return rowOf(id, { author });
}

/** Reply to a comment id; `reply_to` uses the qualified form the backend stores. */
function reply(id: string, parentId: string, author: string): Comment {
	return rowOf(id, { author, reply_to: `core.Comment.${parentId}` });
}

function nodeOf(row: Comment, children: ThreadNode[], deleted = false): ThreadNode {
	return { row, parent: null, children, deleted };
}

describe('bareId', () => {
	it('strips the qualified core.Comment prefix', () => {
		expect(bareId('core.Comment.01J8')).toBe('01J8');
	});

	it('keeps an unqualified ULID unchanged', () => {
		expect(bareId('01J8')).toBe('01J8');
	});

	it('maps empty and nullish refs to the empty string', () => {
		expect(bareId('')).toBe('');
		expect(bareId(undefined)).toBe('');
		expect(bareId(null)).toBe('');
	});
});

describe('buildThreads', () => {
	it('nests replies under the comment named by reply_to', () => {
		const roots = buildThreads([
			topLevel('c1', KIM),
			reply('c2', 'c1', REX),
			reply('c3', 'c2', KIM)
		]);
		expect(roots).toHaveLength(1);
		expect(roots[0]!.row.meta.id).toBe('c1');
		expect(roots[0]!.deleted).toBe(false);
		const c2 = roots[0]!.children[0]!;
		expect(c2.row.meta.id).toBe('c2');
		expect(c2.parent).toBe(roots[0]!.row);
		const c3 = c2.children[0]!;
		expect(c3.row.meta.id).toBe('c3');
		expect(c3.parent).toBe(c2.row);
	});

	it('keeps roots and siblings in list order', () => {
		const roots = buildThreads([
			topLevel('c1', KIM),
			reply('c2', 'c1', REX),
			topLevel('c3', KIM),
			reply('c4', 'c1', REX)
		]);
		expect(roots.map((n) => n.row.meta.id)).toEqual(['c1', 'c3']);
		expect(roots[0]!.children.map((n) => n.row.meta.id)).toEqual(['c2', 'c4']);
	});

	it('stands one shared placeholder in for a tombstoned parent', () => {
		const roots = buildThreads([reply('c6', 'gone', REX), reply('c7', 'gone', KIM)]);
		expect(roots).toHaveLength(1);
		const placeholder = roots[0]!;
		expect(placeholder.deleted).toBe(true);
		expect(placeholder.row.meta.id).toBe(DELETED_ID_PREFIX + 'gone');
		expect(placeholder.row.meta).toEqual({
			id: 'deleted:gone',
			display_name: null,
			created_at: ''
		});
		expect(placeholder.row.data).toEqual({});
		expect(placeholder.children.map((n) => n.row.meta.id)).toEqual(['c6', 'c7']);
		expect(placeholder.children[0]!.parent).toBe(placeholder.row);
		expect(placeholder.children[1]!.parent).toBe(placeholder.row);
	});

	it('handles an empty list', () => {
		expect(buildThreads([])).toEqual([]);
		expect(flattenThreads([], {}, authorNameOf)).toEqual([]);
	});
});

describe('flattenThreads', () => {
	/** The NestedThread story fixture: a five-level chain plus two replies
	 * whose parent was tombstoned. */
	const storyRows = [
		topLevel('c1', KIM),
		reply('c2', 'c1', REX),
		reply('c3', 'c2', KIM),
		reply('c4', 'c3', REX),
		reply('c5', 'c4', KIM),
		reply('c6', 'deleted_parent', REX),
		reply('c7', 'deleted_parent', KIM)
	];

	it('emits depth-first entries and clamps past MAX_INDENT', () => {
		const entries = flattenThreads(buildThreads(storyRows), {}, authorNameOf);
		const depthOf = new Map(entries.map((e) => [e.row.meta.id, e.depth]));
		expect(depthOf.get('c1')).toBe(0);
		expect(depthOf.get('c2')).toBe(1);
		expect(depthOf.get('c3')).toBe(2);
		expect(depthOf.get('c4')).toBe(3);
		// Level four clamps into the last indent bucket.
		expect(depthOf.get('c5')).toBe(MAX_INDENT);
		expect(depthOf.get(DELETED_ID_PREFIX + 'deleted_parent')).toBe(0);
		expect(depthOf.get('c6')).toBe(1);
		expect(depthOf.get('c7')).toBe(1);
	});

	it('marks the placeholder entry as deleted at the root', () => {
		const entries = flattenThreads(buildThreads(storyRows), {}, authorNameOf);
		const phId = DELETED_ID_PREFIX + 'deleted_parent';
		const placeholder = entries.find((e) => e.row.meta.id === phId)!;
		expect(placeholder.deleted).toBe(true);
		expect(placeholder.replyToName).toBeNull();
	});

	it('names the parent author only on clamped entries', () => {
		const entries = flattenThreads(buildThreads(storyRows), {}, authorNameOf);
		const byId = new Map(entries.map((e) => [e.row.meta.id, e]));
		for (const id of ['c1', 'c2', 'c3', 'c4']) {
			expect(byId.get(id)!.replyToName).toBeNull();
		}
		// c5's parent is c4, authored by Rex Mundi.
		expect(byId.get('c5')!.replyToName).toBe('Rex Mundi');
	});

	it('counts all live descendants for the collapse toggle', () => {
		const entries = flattenThreads(buildThreads(storyRows), {}, authorNameOf);
		const byId = new Map(entries.map((e) => [e.row.meta.id, e]));
		expect(byId.get('c1')!.descendantCount).toBe(4);
		expect(byId.get('c2')!.descendantCount).toBe(3);
		expect(byId.get('c5')!.descendantCount).toBe(0);
		expect(byId.get(DELETED_ID_PREFIX + 'deleted_parent')!.descendantCount).toBe(2);
	});

	it('collapse hides the subtree but keeps the descendant count', () => {
		const tree = buildThreads([
			topLevel('c1', KIM),
			reply('c2', 'c1', REX),
			reply('c3', 'c2', KIM)
		]);
		const entries = flattenThreads(tree, { c1: true }, authorNameOf);
		expect(entries.map((e) => e.row.meta.id)).toEqual(['c1']);
		expect(entries[0]!.descendantCount).toBe(2);
		// Expanded (the default) the whole chain renders.
		const expanded = flattenThreads(tree, {}, authorNameOf).map((e) => e.row.meta.id);
		expect(expanded).toEqual(['c1', 'c2', 'c3']);
	});

	it('collapse stops at the flagged node only, and only for a true flag', () => {
		const tree = buildThreads([
			topLevel('c1', KIM),
			reply('c2', 'c1', REX),
			reply('c3', 'c2', KIM),
			reply('c4', 'c1', REX)
		]);
		// Collapsing c2 hides its subtree; the sibling c4 stays visible.
		const collapsed = flattenThreads(tree, { c2: true }, authorNameOf);
		expect(collapsed.map((e) => e.row.meta.id)).toEqual(['c1', 'c2', 'c4']);
		// A `false` flag does not collapse — the check is `=== true`.
		const unchecked = flattenThreads(tree, { c1: false }, authorNameOf);
		expect(unchecked.map((e) => e.row.meta.id)).toEqual(['c1', 'c2', 'c3', 'c4']);
	});

	it('a deleted stand-in below the cap never clamps and names no reply target', () => {
		// Not reachable from a flat list (placeholders are always roots) —
		// the tree is hand-built to exercise the `!node.deleted` guard.
		const a3Row = rowOf('a3', { author: KIM });
		const x = nodeOf(rowOf('x', { author: REX }), [], true);
		x.parent = a3Row;
		const y = nodeOf(rowOf('y', { author: KIM }), []);
		x.children.push(y);
		y.parent = x.row;
		const tree = nodeOf(rowOf('d0', {}), [
			nodeOf(rowOf('a1', {}), [nodeOf(rowOf('a2', {}), [nodeOf(a3Row, [x])])])
		]);

		const entries = flattenThreads([tree], {}, authorNameOf);
		const byId = new Map(entries.map((e) => [e.row.meta.id, e]));
		// x sits at depth 4: rendered depth clamps to 3, but a deleted node
		// never counts as clamped, so it names no reply target.
		expect(byId.get('x')!.deleted).toBe(true);
		expect(byId.get('x')!.depth).toBe(3);
		expect(byId.get('x')!.replyToName).toBeNull();
		// Its live child clamps and names the direct parent's author (x, Rex).
		expect(byId.get('y')!.depth).toBe(3);
		expect(byId.get('y')!.replyToName).toBe('Rex Mundi');
	});
});
