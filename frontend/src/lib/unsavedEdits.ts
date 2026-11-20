// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Registry for surfaces that hold unsaved edits.
 *
 * The active owner (a page or an editor component) registers one gate —
 * a function that answers "do I hold unsaved edits?". Two consumers read
 * it: the role-detail layout asks the gate before a tab navigation, and
 * the shared `beforeunload` handler arms the browser's leave dialog for
 * close and refresh.
 *
 * One gate at a time: the last registration wins, and clearing compares
 * identity so a late cleanup from an unmounted owner cannot remove a
 * newer owner's gate.
 */

let gate: (() => boolean) | null = null;
let listening = false;

/** True when the active owner holds unsaved edits. */
export function hasUnsavedEdits(): boolean {
	return gate ? gate() : false;
}

/** Register the active gate (the last registration wins). */
export function setUnsavedEditsGate(isDirty: () => boolean): void {
	gate = isDirty;
	syncUnloadGuard();
}

/** Remove a previously registered gate — only when it is still active. */
export function clearUnsavedEditsGate(isDirty: () => boolean): void {
	if (gate !== isDirty) return;
	gate = null;
	syncUnloadGuard();
}

function syncUnloadGuard(): void {
	// SSR and node tests have no window — nothing to arm there.
	if (typeof window === 'undefined') return;
	if (gate !== null && !listening) {
		window.addEventListener('beforeunload', onBeforeUnload);
		listening = true;
	} else if (gate === null && listening) {
		window.removeEventListener('beforeunload', onBeforeUnload);
		listening = false;
	}
}

function onBeforeUnload(event: BeforeUnloadEvent): void {
	if (!hasUnsavedEdits()) return;
	// The browser renders its own leave dialog; the message is not
	// customizable. preventDefault plus the legacy returnValue arms it.
	event.preventDefault();
	event.returnValue = '';
}
