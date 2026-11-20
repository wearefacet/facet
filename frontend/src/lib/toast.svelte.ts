// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Global toast store — transient status messages with an optional link.
 *
 * Mirrors `confirm.svelte.ts`: module-level `$state`, push/dismiss under
 * exported functions, no `setContext`. The toasts render in `ToastHost`,
 * mounted once in the root layout. A toast auto-dismisses after its
 * `durationMs` (browser-only timer), and clicking its action link dismisses
 * it — navigation takes over.
 */

export interface ToastOptions {
	/** The primary message. One line. */
	message: string;
	/** `'ok'` tints the accent bar; `'error'` uses the danger colour. */
	variant?: 'ok' | 'error';
	/** Optional link label + href (e.g. the export download path). */
	action?: { label: string; href: string };
	/** Auto-dismiss window. Defaults to 6 s; errors stay for 9 s. */
	durationMs?: number;
}

export interface Toast extends ToastOptions {
	id: number;
}

let toasts = $state<Toast[]>([]);
let nextId = 1;

/** Shows one toast. On the server this is a no-op. */
export function toast(options: ToastOptions): void {
	if (typeof window === 'undefined') return;

	const id = nextId++;
	const item: Toast = { ...options, id };
	toasts.push(item);

	const duration = options.durationMs ?? (options.variant === 'error' ? 9_000 : 6_000);
	setTimeout(() => dismissToast(id), duration);
}

/** Removes one toast by id. */
export function dismissToast(id: number): void {
	toasts = toasts.filter((t) => t.id !== id);
}

/** The current toast list — read by the `ToastHost`. */
export function getToasts(): Toast[] {
	return toasts;
}
