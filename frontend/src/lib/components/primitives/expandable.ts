// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { ActionReturn } from 'svelte/action';

export interface ExpandableOptions {
	/** Whether the fullscreen overlay is open. */
	active: boolean;
	/** Called when the user presses Escape while `active`. */
	onescape: () => void;
}

/**
 * `use:expandable` — closes a fullscreen overlay on Escape.
 *
 * Listens on `document` only while `active`; the event is stopped so
 * ancestor editors do not also react. Shared by `Markdown` and
 * `CodeEditor`.
 */
export function expandable(node: HTMLElement, options: ExpandableOptions): ActionReturn {
	let active = options.active;
	let onescape = options.onescape;

	const onKeyDown = (e: KeyboardEvent) => {
		if (e.key === 'Escape') {
			e.stopPropagation();
			onescape();
		}
	};
	const attach = () => document.addEventListener('keydown', onKeyDown);
	const detach = () => document.removeEventListener('keydown', onKeyDown);

	if (active) attach();

	return {
		update(next?: Partial<ExpandableOptions>) {
			if (!next) return;
			if (next.onescape) onescape = next.onescape;
			if (next.active && !active) {
				active = true;
				attach();
			} else if (!next.active && active) {
				active = false;
				detach();
			}
		},
		destroy: detach
	};
}
