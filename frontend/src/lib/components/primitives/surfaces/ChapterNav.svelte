<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Component } from 'svelte';

	/**
	 * ChapterNav — the sticky chapter rail of a chaptered settings surface.
	 *
	 * Renders one button per chapter. The parent owns the scroll-spy and
	 * the active chapter; the rail shows the state and reports clicks
	 * through `onNavigate`. The parent then scrolls and holds the spy
	 * while the smooth scroll runs.
	 */

	export type Chapter = {
		id: string;
		label: string;
		/** The icon component, rendered before the label. */
		icon: Component;
	};

	let {
		chapters,
		activeId,
		onNavigate,
		label
	}: {
		/** The rail entries, in display order. */
		chapters: Chapter[];
		/** The active chapter id — drives the highlight and `aria-current`. */
		activeId: string;
		/** Reports a click. The parent scrolls to the chapter. */
		onNavigate: (id: string) => void;
		/** The accessible name of the nav landmark. */
		label: string;
	} = $props();
</script>

<nav class="chapter-nav" aria-label={label}>
	{#each chapters as chapter (chapter.id)}
		<button
			class="chapter-link"
			class:active={activeId === chapter.id}
			onclick={() => onNavigate(chapter.id)}
			aria-current={activeId === chapter.id ? 'true' : undefined}
		>
			<chapter.icon size={15} stroke-width={1.9} aria-hidden="true" />
			<span>{chapter.label}</span>
		</button>
	{/each}
</nav>

<style>
	.chapter-nav {
		position: sticky;
		top: 20px;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.chapter-link {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 7px 10px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 13px;
		cursor: pointer;
		width: 100%;
		text-align: left;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.chapter-link:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.chapter-link.active {
		background: var(--accent-weak);
		color: var(--accent-ink);
		font-weight: 600;
	}

	@media (max-width: 900px) {
		.chapter-nav {
			top: 0;
			z-index: 5;
			flex-direction: row;
			overflow-x: auto;
			gap: 6px;
			padding: 8px;
			background: var(--ground);
			border-bottom: 1px solid var(--border);
			border-radius: var(--r-sm);
		}

		.chapter-link {
			flex: none;
			width: auto;
		}
	}
</style>
