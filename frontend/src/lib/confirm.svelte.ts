// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Global confirmation dialog store — replaces native `confirm()`.
 *
 * Mirrors the pattern of `theme.svelte.ts` and `role.svelte.ts`: module-level
 * `$state`, getter/setter functions, no `setContext`. The dialog itself is
 * rendered by `ConfirmDialog.svelte`, mounted once in the root layout.
 *
 * Callers `await confirm({ title, message, ... })` and get a promise that
 * settles when the user picks a button (or dismisses the dialog with
 * Escape / an outside click). A second `confirm()` while one is pending
 * settles the first as cancelled — the dialog is a single, shared surface.
 *
 * `confirmWithText` is the variant that also captures one line of free
 * text (e.g. the reason behind a destructive operator action). The dialog
 * renders the input when the pending options carry a `prompt`.
 */

export interface ConfirmPrompt {
	/** Field label above the input. */
	label?: string;
	/** Placeholder inside the input. */
	placeholder?: string;
}

export interface ConfirmOptions {
	title: string;
	message?: string;
	confirmLabel?: string;
	cancelLabel?: string;
	/** `danger` paints the confirm button with the danger colour. */
	variant?: 'default' | 'danger';
	/** When set, the dialog renders one optional free-text input. */
	prompt?: ConfirmPrompt;
}

export interface ConfirmTextResult {
	ok: boolean;
	/** The captured text — `''` when cancelled or left empty. */
	text: string;
}

let pending = $state<ConfirmOptions | null>(null);
let resolver: ((value: boolean, text?: string) => void) | null = null;

/**
 * Open the confirmation dialog and resolve when the user answers.
 * On the server this resolves `false` immediately (no DOM, no dialog).
 */
export function confirm(options: ConfirmOptions): Promise<boolean> {
	if (typeof window === 'undefined') return Promise.resolve(false);
	return confirmWithText(options).then((result) => result.ok);
}

/**
 * Open the confirmation dialog and resolve with the button answer plus the
 * captured prompt text (empty when the dialog carries no `prompt`, the
 * input was left empty, or the dialog was cancelled).
 */
export function confirmWithText(options: ConfirmOptions): Promise<ConfirmTextResult> {
	if (typeof window === 'undefined') return Promise.resolve({ ok: false, text: '' });
	resolver?.(false);
	pending = options;
	return new Promise<ConfirmTextResult>((resolve) => {
		resolver = (ok, text) => resolve({ ok, text: text ?? '' });
	});
}

/** The current pending request — read by the `ConfirmDialog` host. */
export function getPendingConfirm(): ConfirmOptions | null {
	if (typeof window === 'undefined') return null;
	return pending;
}

/**
 * Settle the pending confirm (`true` = confirmed, `false` = dismissed).
 * `text` carries the captured prompt text; it is discarded when the
 * dialog was dismissed — a cancelled confirmation never leaks what was
 * typed into it. The boolean-only resolver ignores `text` entirely.
 */
export function settleConfirm(value: boolean, text?: string): void {
	if (typeof window === 'undefined') return;
	const resolve = resolver;
	resolver = null;
	pending = null;
	resolve?.(value, value ? text : undefined);
}
