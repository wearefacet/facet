// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Save-button flash state shared by the doctype and domain editors.
 *
 * The editor's save button walks `idle → saving → saved` and flashes back
 * to `idle`, or lands on `error` with the failure message until the next
 * attempt. One module owns the state and the flash timer so the editors
 * cannot drift (different flash windows, one of them leaving "Saved" on
 * screen forever).
 */

export type SaveFlashStatus = 'idle' | 'saving' | 'saved' | 'error';

export interface SaveFlashState {
	status: SaveFlashStatus;
	message?: string;
}

/** How long the "Saved" state stays on the button before returning to idle. */
const FLASH_MS = 1500;

export function createSaveFlash(flashMs: number = FLASH_MS) {
	let state = $state<SaveFlashState>({ status: 'idle' });
	let timer: ReturnType<typeof setTimeout> | undefined;

	return {
		get status(): SaveFlashStatus {
			return state.status;
		},
		get message(): string | undefined {
			return state.message;
		},
		saving(): void {
			state = { status: 'saving' };
		},
		saved(): void {
			state = { status: 'saved' };
			clearTimeout(timer);
			timer = setTimeout(() => {
				state = { status: 'idle' };
			}, flashMs);
		},
		failed(message?: string): void {
			state = { status: 'error', message };
		},
		reset(): void {
			state = { status: 'idle' };
		}
	};
}
