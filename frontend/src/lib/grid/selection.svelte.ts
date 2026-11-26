// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Cell selection for the grid surface — the active cell, the extended
 * range, and the moves behind them.
 *
 * The store owns no bounds: the grid passes its live row/column counts to
 * every move, so a refetch that shrinks the data clamps the next move
 * instead of leaving the store pointing past the end. One store instance
 * survives refetches; `clamp` (or an explicit `clear`) reconciles it after
 * the data changes.
 *
 * Everything here is plain data work on `$state` runes — no DOM, no
 * datasource — so the Vitest `server` project covers the model directly.
 */

/** A cell position, zero-indexed. */
export interface CellPos {
	row: number;
	col: number;
}

/** A normalized (start ≤ end, inclusive) rectangular cell range. */
export interface CellRange {
	rowStart: number;
	rowEnd: number;
	colStart: number;
	colEnd: number;
}

export function createSelection() {
	/** The range's fixed end — set on click, kept while extending. */
	let anchor = $state<CellPos | null>(null);
	/** The moving end — the cell arrows move, the cell the caret sits on. */
	let focus = $state<CellPos | null>(null);

	/** The normalized range, or `null` when nothing is selected. */
	const range = $derived.by<CellRange | null>(() => {
		if (!anchor || !focus) return null;
		return {
			rowStart: Math.min(anchor.row, focus.row),
			rowEnd: Math.max(anchor.row, focus.row),
			colStart: Math.min(anchor.col, focus.col),
			colEnd: Math.max(anchor.col, focus.col)
		};
	});

	/** Clamp a position into the current bounds. */
	function clamp(row: number, col: number, maxRow: number, maxCol: number): CellPos {
		return {
			row: Math.min(Math.max(0, row), Math.max(0, maxRow)),
			col: Math.min(Math.max(0, col), Math.max(0, maxCol))
		};
	}

	return {
		get anchor() {
			return anchor;
		},
		get focus() {
			return focus;
		},
		get range() {
			return range;
		},

		/** Collapse the selection onto one cell. */
		setFocus(row: number, col: number, maxRow: number, maxCol: number): void {
			const pos = clamp(row, col, maxRow, maxCol);
			anchor = pos;
			focus = pos;
		},

		/** Move the focus cell, keeping the anchor when `extend` (⇧+move). */
		move(dr: number, dc: number, extend: boolean, maxRow: number, maxCol: number): void {
			if (maxRow < 0 || maxCol < 0) return;
			if (!focus || !anchor) {
				// No selection yet — the first move lands where the table's
				// row navigation lands: ↓/→ on the first cell, ↑/← on the
				// last row's first cell.
				const startRow = dr < 0 ? maxRow : 0;
				const pos = clamp(startRow, 0, maxRow, maxCol);
				anchor = pos;
				focus = pos;
				return;
			}
			const next = clamp(focus.row + dr, focus.col + dc, maxRow, maxCol);
			focus = next;
			if (!extend) anchor = next;
		},

		/** Point the focus at an explicit cell, keeping the anchor (a
		 *  shift-click or a drag over the target). */
		extendTo(row: number, col: number, maxRow: number, maxCol: number): void {
			if (!anchor) {
				const pos = clamp(row, col, maxRow, maxCol);
				anchor = pos;
				focus = pos;
				return;
			}
			focus = clamp(row, col, maxRow, maxCol);
		},

		/** Pull the selection back inside the bounds — a refetch that
		 *  shrank the data calls this so nothing points past the end. */
		clampTo(maxRow: number, maxCol: number): void {
			if (!anchor || !focus) return;
			anchor = clamp(anchor.row, anchor.col, maxRow, maxCol);
			focus = clamp(focus.row, focus.col, maxRow, maxCol);
		},

		/** Drop the selection entirely. */
		clear(): void {
			anchor = null;
			focus = null;
		},

		/** Whether (row, col) sits inside the current range. */
		inRange(rangeValue: CellRange | null, row: number, col: number): boolean {
			if (!rangeValue) return false;
			return (
				row >= rangeValue.rowStart &&
				row <= rangeValue.rowEnd &&
				col >= rangeValue.colStart &&
				col <= rangeValue.colEnd
			);
		},

		/** Cell count the range covers (1 for a single active cell). */
		size(rangeValue: CellRange | null): number {
			if (!rangeValue) return 0;
			return (
				(rangeValue.rowEnd - rangeValue.rowStart + 1) *
				(rangeValue.colEnd - rangeValue.colStart + 1)
			);
		}
	};
}

export type GridSelection = ReturnType<typeof createSelection>;
