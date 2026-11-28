// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Placement for the grid's inline floaters — the enum listbox, the
 * floating editor frame, the cell's failure label. The panels scroll with
 * the grid (the spreadsheet rule; nothing portals), so each one must fit
 * the scroll container's visible box instead of colliding with its edges.
 *
 * The action runs once at mount — the moment the panel takes its natural
 * spot below (and rightward of) its anchor — and flips it before the
 * first paint: upward when the box would cut its bottom and the room
 * above holds the whole panel, right-aligned when the box would cut its
 * right. `open-up` / `open-right` carry the flip; each panel's own
 * stylesheet defines what they mean, targeted through `:global` — the
 * classes never appear in a template.
 */

/** A cut smaller than this reads as a sliver — not worth the jump. */
const FLIP_OVERFLOW_MIN = 16;

export function placeFloater(node: HTMLElement): void {
	const scroller = node.closest('.grid-scroll');
	if (!scroller) return;
	const nr = node.getBoundingClientRect();
	const sr = scroller.getBoundingClientRect();
	// Cut at the box's bottom: flip above when the room above the anchor
	// (the node's natural top sits just under it) holds the whole panel.
	if (
		nr.bottom - sr.bottom > FLIP_OVERFLOW_MIN &&
		nr.top - sr.top > nr.height + FLIP_OVERFLOW_MIN
	) {
		node.classList.add('open-up');
	}
	// Cut at the box's right: right-align — the panel then grows leftward
	// from the anchor's right edge, which the box already shows.
	if (nr.right - sr.right > FLIP_OVERFLOW_MIN) {
		node.classList.add('open-right');
	}
}
