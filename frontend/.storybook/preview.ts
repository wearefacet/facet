// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import '$lib/styles/tokens.css';
import '$lib/styles/base.css';
import { createMockDriver } from '$lib/datasource/mock-seed.js';
import {
	currencyRowsFromMockDriver,
	seedCurrencies
} from '$lib/components/primitives/data/currencyStore.svelte.js';

import type { Preview } from '@storybook/sveltekit';

// ── Global MockDriver ──────────────────────────────────────────────────────────
//
// A single MockDataDriver is created at startup and pre-populated with all
// fixture and seed data (doctype definitions + documents). Stories can access
// it via `parameters.driver` or import it directly from this module.
//
// Because MockDataDriver shares a single document store across all domains
// and doctypes, stories can create cross-doctype relationships and look up
// doctype definitions at runtime.

export const mockDriver = createMockDriver();

// The currency store's rows seed before every story renders, so money
// surfaces (Money display, MoneyInput picker, DvtValue/Table money cells)
// read the `core.Currency` seed set without an API. The seeding runs as a
// project **loader** — loaders execute per story before the render, outside
// any Svelte reaction; a decorator would write the store's module state
// inside the render effect, which Svelte rejects (state_unsafe_mutation).
// A story that needs a different row set (empty store, an inactive row)
// calls `seedCurrencies` at the top of its play — plays run after the
// render, also outside any reaction — so the override wins.
const currencySeedRows = currencyRowsFromMockDriver(mockDriver);

const preview: Preview = {
	loaders: [
		() => {
			seedCurrencies(currencySeedRows);
		},
		// Bits UI modals leave `pointer-events: none` on <body> for a tick after
		// close (the restore timer is async, and pointer-events is inherited).
		// On the shared page (isolate: false) the previous story's close can
		// still be restoring when this story's first pointer interaction runs,
		// so wait it out here once for every story — see workflow.md →
		// Testing strategy → play conventions.
		async () => {
			for (
				let waited = 0;
				document.body?.style.pointerEvents === 'none' && waited < 500;
				waited += 25
			) {
				await new Promise((resolve) => setTimeout(resolve, 25));
			}
		}
	],

	parameters: {
		layout: 'fullscreen',
		controls: {
			matchers: {
				color: /(background|color)$/i,
				date: /Date$/i
			}
		},

		a11y: {
			// 'todo' - show a11y violations in the test UI only
			// 'error' - fail CI on a11y violations
			// 'off' - skip a11y checks entirely
			//
			// Runs in 'error' mode: a story with an axe violation fails its own
			// test, so new violations block a merge instead of growing a silent
			// backlog. Pre-existing violations carry an explicit per-story (or
			// per-meta) `a11y: { test: 'todo' }` override listing what to fix —
			// grep for `test: 'todo'` in `*.stories.svelte`. Clear those starting
			// with the primitives (`src/lib/components/primitives/`), then the
			// features; when the last override is gone this comment goes too.
			// See doc/frontend/workflow.md → Testing strategy.
			test: 'error',
			// Code regions are excluded because syntax highlighting is decorative —
			// meaning is carried by structure, not token colour, and forcing AA
			// contrast on every token destroys the syntax theme (which already
			// passes in dark mode). This also skips CodeMirror's internal a11y
			// quirks (gutter line-number divs); the field wrapper's label /
			// helper / error live outside these regions and are still audited.
			context: {
				exclude: ['.cm-content', '.cm-gutters', '.cm-line', 'pre', 'code', '.hljs']
			}
		},

		darkMode: {
			darkClass: 'dark',
			lightClass: 'light',
			stylePreview: true
		}
	}
};

export default preview;
