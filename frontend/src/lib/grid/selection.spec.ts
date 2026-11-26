// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { createSelection } from './selection.svelte.js';

/**
 * Unit tests for the grid's cell-selection model: collapsing clicks,
 * arrow moves with their clamping, shift-extends, refetch clamping, and
 * the range math the rendering and copy paths read.
 */

describe('grid selection', () => {
	it('setFocus collapses anchor and focus onto the clamped cell', () => {
		const sel = createSelection();
		sel.setFocus(2, 1, 4, 2);
		expect(sel.focus).toEqual({ row: 2, col: 1 });
		expect(sel.anchor).toEqual({ row: 2, col: 1 });
		expect(sel.range).toEqual({ rowStart: 2, rowEnd: 2, colStart: 1, colEnd: 1 });
		expect(sel.size(sel.range)).toBe(1);
	});

	it('setFocus clamps out-of-bounds cells', () => {
		const sel = createSelection();
		sel.setFocus(9, 9, 4, 2);
		expect(sel.focus).toEqual({ row: 4, col: 2 });
	});

	it('move without a selection lands on the first cell going down and the last row going up', () => {
		const sel = createSelection();
		sel.move(1, 0, false, 4, 2);
		expect(sel.focus).toEqual({ row: 0, col: 0 });
		sel.clear();
		sel.move(-1, 0, false, 4, 2);
		expect(sel.focus).toEqual({ row: 4, col: 0 });
	});

	it('move ignores an empty grid', () => {
		const sel = createSelection();
		sel.move(1, 0, false, -1, -1);
		expect(sel.focus).toBeNull();
		sel.setFocus(0, 0, 2, 2);
		sel.move(1, 0, false, -1, -1);
		expect(sel.focus).toEqual({ row: 0, col: 0 });
	});

	it('move walks and clamps at the bounds, collapsing the range when not extending', () => {
		const sel = createSelection();
		sel.setFocus(0, 0, 4, 2);
		sel.move(1, 1, false, 4, 2);
		expect(sel.focus).toEqual({ row: 1, col: 1 });
		sel.move(-5, -5, false, 4, 2);
		expect(sel.focus).toEqual({ row: 0, col: 0 });
		sel.move(99, 0, false, 4, 2);
		expect(sel.focus).toEqual({ row: 4, col: 0 });
		sel.move(0, 99, false, 4, 2);
		expect(sel.focus).toEqual({ row: 4, col: 2 });
	});

	it('move with extend keeps the anchor and grows the range', () => {
		const sel = createSelection();
		sel.setFocus(1, 1, 4, 2);
		sel.move(1, 0, true, 4, 2);
		sel.move(1, 1, true, 4, 2);
		expect(sel.anchor).toEqual({ row: 1, col: 1 });
		expect(sel.focus).toEqual({ row: 3, col: 2 });
		expect(sel.range).toEqual({ rowStart: 1, rowEnd: 3, colStart: 1, colEnd: 2 });
		expect(sel.size(sel.range)).toBe(6);
	});

	it('a non-extended move after an extend collapses back to one cell', () => {
		const sel = createSelection();
		sel.setFocus(1, 1, 4, 2);
		sel.move(1, 0, true, 4, 2);
		sel.move(0, 1, false, 4, 2);
		expect(sel.anchor).toEqual(sel.focus);
		expect(sel.size(sel.range)).toBe(1);
	});

	it('extendTo keeps the anchor on a shift-click', () => {
		const sel = createSelection();
		sel.setFocus(1, 1, 4, 2);
		sel.extendTo(0, 0, 4, 2);
		expect(sel.anchor).toEqual({ row: 1, col: 1 });
		expect(sel.range).toEqual({ rowStart: 0, rowEnd: 1, colStart: 0, colEnd: 1 });
	});

	it('extendTo without an anchor behaves like setFocus', () => {
		const sel = createSelection();
		sel.extendTo(2, 2, 4, 2);
		expect(sel.anchor).toEqual(sel.focus);
		expect(sel.focus).toEqual({ row: 2, col: 2 });
	});

	it('clampTo pulls the selection back after the data shrinks', () => {
		const sel = createSelection();
		sel.setFocus(0, 0, 9, 9);
		sel.extendTo(8, 8, 9, 9);
		sel.clampTo(3, 2);
		expect(sel.range).toEqual({ rowStart: 0, rowEnd: 3, colStart: 0, colEnd: 2 });
	});

	it('clear drops everything and inRange answers false', () => {
		const sel = createSelection();
		sel.setFocus(1, 1, 4, 2);
		sel.clear();
		expect(sel.focus).toBeNull();
		expect(sel.anchor).toBeNull();
		expect(sel.range).toBeNull();
		expect(sel.inRange(null, 1, 1)).toBe(false);
	});

	it('inRange answers inside and outside cells of a range', () => {
		const sel = createSelection();
		sel.setFocus(1, 1, 4, 2);
		sel.extendTo(2, 2, 4, 2);
		const r = sel.range!;
		expect(sel.inRange(r, 1, 1)).toBe(true);
		expect(sel.inRange(r, 2, 2)).toBe(true);
		expect(sel.inRange(r, 0, 0)).toBe(false);
		expect(sel.inRange(r, 3, 2)).toBe(false);
	});
});
