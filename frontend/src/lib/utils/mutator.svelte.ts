// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { errorMessage } from '$lib/datasource/bannerError.js';

/**
 * Busy/error scaffolding for one-shot record mutations (add / remove role
 * membership, revoke, regenerate). One `run(key, fn)` call replaces the
 * repeated set-busy / clear-error / try / catch-to-banner / finally-unbusy
 * block. `key` identifies the row or picker that owns the in-flight action,
 * so callers can render per-row spinners and disable sibling controls while
 * any action runs.
 *
 * Create it during component initialisation (it uses module runes).
 */
export function createMutator() {
	let busyId = $state<string | undefined>(undefined);
	let error = $state<string | undefined>(undefined);
	let running = 0;

	return {
		/** Key of the in-flight action, or `undefined` when idle. */
		get busyId(): string | undefined {
			return busyId;
		},
		/** True while any action is in flight — disables sibling controls. */
		get busy(): boolean {
			return running > 0;
		},
		/** Message from the last failed action; cleared on the next run or dismiss. */
		get error(): string | undefined {
			return error;
		},
		clearError(): void {
			error = undefined;
		},
		/**
		 * Run one mutating action under busy/error handling. Returns `false`
		 * immediately when another action is still in flight (the callers'
		 * precondition checks gate the rest).
		 */
		async run(key: string, fn: () => Promise<void>): Promise<boolean> {
			if (running > 0) return false;
			busyId = key;
			error = undefined;
			running += 1;
			try {
				await fn();
				return true;
			} catch (err) {
				error = errorMessage(err);
				return false;
			} finally {
				running -= 1;
				busyId = undefined;
			}
		}
	};
}
