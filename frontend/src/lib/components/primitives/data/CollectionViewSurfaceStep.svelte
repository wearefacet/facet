<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { CollectionSurface } from '$lib/collectionView/types.js';

	/**
	 * Step 1 of the create flow — the four-surface picker. `table`,
	 * `calendar`, and `kanban` are selectable (every doctype anchors a
	 * calendar on its `created_at` / `updated_at` meta keys when it declares
	 * no date fields of its own); `grid` renders disabled as a forward
	 * signal. The selection lives in the parent; this step only reports it.
	 */
	let {
		value,
		onselect
	}: {
		/** Currently selected surface. */
		value: CollectionSurface;
		/** Fired when the user picks a selectable surface. */
		onselect: (surface: CollectionSurface) => void;
	} = $props();
</script>

<p class="cve-step-label">{m.list_editor_choose_surface()}</p>
<div class="cve-surfaces">
	<button
		type="button"
		class="cve-surface"
		class:cve-surface-on={value === 'table'}
		aria-pressed={value === 'table'}
		onclick={() => onselect('table')}
	>
		<span class="cve-surface-glyph" aria-hidden="true">
			<svg
				viewBox="0 0 24 24"
				width="22"
				height="22"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
			>
				<rect x="3" y="4" width="18" height="16" rx="2" />
				<path d="M3 9h18M9 9v11" />
			</svg>
		</span>
		<span class="cve-surface-name">{m.list_editor_surface_table()}</span>
		<span class="cve-surface-desc">{m.list_editor_surface_table_desc()}</span>
	</button>
	<button
		type="button"
		class="cve-surface"
		class:cve-surface-on={value === 'calendar'}
		aria-pressed={value === 'calendar'}
		onclick={() => onselect('calendar')}
	>
		<span class="cve-surface-glyph" aria-hidden="true">
			<svg
				viewBox="0 0 24 24"
				width="22"
				height="22"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
			>
				<rect x="3" y="4" width="18" height="18" rx="2" />
				<path d="M16 2v4M8 2v4M3 10h18" />
			</svg>
		</span>
		<span class="cve-surface-name">{m.list_editor_surface_calendar()}</span>
		<span class="cve-surface-desc">{m.list_editor_surface_calendar_desc()}</span>
	</button>
	<button
		type="button"
		class="cve-surface"
		class:cve-surface-on={value === 'kanban'}
		aria-pressed={value === 'kanban'}
		onclick={() => onselect('kanban')}
	>
		<span class="cve-surface-glyph" aria-hidden="true">
			<svg
				viewBox="0 0 24 24"
				width="22"
				height="22"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
			>
				<rect x="3" y="4" width="6" height="16" rx="1" />
				<rect x="10" y="4" width="6" height="11" rx="1" />
				<rect x="17" y="4" width="4" height="8" rx="1" />
			</svg>
		</span>
		<span class="cve-surface-name">{m.list_editor_surface_kanban()}</span>
		<span class="cve-surface-desc">{m.list_editor_kanban_desc()}</span>
	</button>
	<div
		class="cve-surface cve-surface-disabled"
		aria-disabled="true"
		title={m.list_editor_coming_soon()}
	>
		<span class="cve-surface-glyph" aria-hidden="true">
			<svg
				viewBox="0 0 24 24"
				width="22"
				height="22"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
			>
				<rect x="3" y="4" width="8" height="8" rx="1" />
				<rect x="13" y="4" width="8" height="8" rx="1" />
				<rect x="3" y="14" width="8" height="6" rx="1" />
				<rect x="13" y="14" width="8" height="6" rx="1" />
			</svg>
		</span>
		<span class="cve-surface-name">{m.list_editor_surface_grid()}</span>
		<span class="cve-surface-desc">{m.list_editor_soon()}</span>
	</div>
</div>

<style>
	.cve-step-label {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 0 0 12px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		font-weight: 600;
	}

	.cve-surfaces {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 10px;
	}

	.cve-surface {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 16px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		cursor: pointer;
		text-align: left;
		color: var(--text);
		font: inherit;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.cve-surface:hover:not(.cve-surface-disabled) {
		border-color: var(--border-strong);
	}

	.cve-surface-on {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.cve-surface-disabled {
		opacity: 0.45;
		cursor: not-allowed;
	}

	.cve-surface-glyph {
		color: var(--text-3);
	}

	.cve-surface-on .cve-surface-glyph {
		color: var(--accent);
	}

	.cve-surface-name {
		font-weight: 600;
		font-size: 13.5px;
	}

	.cve-surface-desc {
		font-size: 11.5px;
		color: var(--text-3);
	}
</style>
