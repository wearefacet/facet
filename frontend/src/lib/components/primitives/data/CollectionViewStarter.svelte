<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { CollectionSurface } from '$lib/collectionView/types.js';
	import { can } from '$lib/permissions.svelte';

	/**
	 * Zero-views starter — the empty state the listing renders when a
	 * doctype has no saved collection view. Offers one card per surface
	 * (table, kanban, calendar); picking one opens the view editor with
	 * that surface preselected. Views created here default to **personal**
	 * (the editor's create default — always succeeds; the backend Lua hook
	 * force-binds `owner_id` for `$mine`-scoped creators).
	 *
	 * Without the `create` permission on `core.CollectionView` the cards
	 * are replaced by a note — there is nothing this viewer can do.
	 */
	let {
		/** Fired when the user picks a surface card. */
		oncreate
	}: {
		oncreate: (surface: CollectionSurface) => void;
	} = $props();

	const canCreate = $derived(can('core.CollectionView', 'create'));

	interface SurfaceCard {
		surface: CollectionSurface;
		name: string;
		desc: string;
		glyph: 'table' | 'calendar' | 'kanban';
	}

	const cards: SurfaceCard[] = [
		{
			surface: 'table',
			name: m.list_editor_surface_table(),
			desc: m.list_editor_surface_table_desc(),
			glyph: 'table'
		},
		{
			surface: 'kanban',
			name: m.list_editor_surface_kanban(),
			desc: m.list_editor_kanban_desc(),
			glyph: 'kanban'
		},
		{
			surface: 'calendar',
			name: m.list_editor_surface_calendar(),
			desc: m.list_editor_surface_calendar_desc(),
			glyph: 'calendar'
		}
	];
</script>

<div class="cvs" role="note" aria-label={m.list_view_starter_title()}>
	<div class="cvs-inner">
		<span class="cvs-glyph" aria-hidden="true">
			<svg
				viewBox="0 0 24 24"
				width="28"
				height="28"
				fill="none"
				stroke="currentColor"
				stroke-width="1.6"
			>
				<rect x="3" y="4" width="18" height="16" rx="2" />
				<path d="M3 9h18M9 13h6" />
			</svg>
		</span>
		<h2 class="cvs-title">{m.list_view_starter_title()}</h2>
		<p class="cvs-hint">{m.list_view_starter_hint()}</p>
		{#if canCreate}
			<div class="cvs-cards">
				{#each cards as card (card.surface)}
					<button type="button" class="cvs-card" onclick={() => oncreate(card.surface)}>
						<span class="cvs-card-glyph" aria-hidden="true">
							{#if card.glyph === 'calendar'}
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
							{:else if card.glyph === 'kanban'}
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
							{:else}
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
							{/if}
						</span>
						<span class="cvs-card-name">{card.name}</span>
						<span class="cvs-card-desc">{card.desc}</span>
					</button>
				{/each}
			</div>
		{:else}
			<p class="cvs-no-create">{m.list_view_starter_no_create()}</p>
		{/if}
	</div>
</div>

<style>
	.cvs {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 60%;
		height: 100%;
		padding: 32px 16px;
	}

	.cvs-inner {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
		max-width: 560px;
		text-align: center;
	}

	.cvs-glyph {
		color: var(--text-3);
		margin-bottom: 4px;
	}

	.cvs-title {
		margin: 0;
		font-size: 16px;
		font-weight: 600;
		color: var(--text);
	}

	.cvs-hint {
		margin: 0 0 12px;
		font-size: 13px;
		color: var(--text-3);
		max-width: 46ch;
	}

	.cvs-cards {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 10px;
		width: 100%;
	}

	.cvs-card {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		padding: 18px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		cursor: pointer;
		text-align: center;
		color: var(--text);
		font: inherit;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.cvs-card:hover {
		border-color: var(--border-strong);
	}

	.cvs-card:focus-visible {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.cvs-card-glyph {
		color: var(--text-3);
	}

	.cvs-card:hover .cvs-card-glyph,
	.cvs-card:focus-visible .cvs-card-glyph {
		color: var(--accent);
	}

	.cvs-card-name {
		font-weight: 600;
		font-size: 13.5px;
	}

	.cvs-card-desc {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cvs-no-create {
		margin: 0;
		font-size: 13px;
		color: var(--text-3);
		max-width: 46ch;
	}
</style>
