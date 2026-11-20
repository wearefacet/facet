// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reset a dialog's local form state whenever it opens.
 *
 * Must be called during component initialisation — it wraps a `$effect`, which
 * subscribes on mount and unsubscribes on destroy. The effect reads only the
 * `open` accessor, so it fires on the open edge (and on mount when already
 * open); `reset` must not write the `open` state, or the effect would loop.
 *
 * A close-time reset (`onOpenChange` → `if (!v) reset()`) misses every
 * programmatic close: a successful submit or a Cancel sets `open = false`
 * directly, which does not fire Bits UI's `onOpenChange`. The previous entry
 * then leaks into the next open. Resetting on the open edge covers every close
 * path.
 *
 * @param open  Accessor for the dialog's two-way bound open state.
 * @param reset Called on each transition to open.
 */
export function resetOnOpen(open: () => boolean, reset: () => void): void {
	$effect(() => {
		if (open()) reset();
	});
}
