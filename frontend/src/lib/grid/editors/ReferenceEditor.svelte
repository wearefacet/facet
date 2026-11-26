<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The reference editor — mounts the platform's `ReferencePicker` in forced
	mode with the field's declared `filter` merged into the search (the
	kanban-lane pattern). The picker's own keys stay live: while its results
	menu is open, Enter picks the highlighted record and Escape only closes
	the menu — the wrapper steps aside by probing for the open menu. A
	picked record lands in the binding; a second Enter commits the cell.

	Without a driver the picker cannot search; the editor degrades to a bare
	text input over the stored token.
-->

<script lang="ts">
	import type { CellEditorProps } from './types.js';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';

	let { field, value, label, driver, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	let rootEl = $state<HTMLElement | null>(null);
	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the binding seeds from the stored token, then the
	// picker owns it.
	let draft = $state(typeof value === 'string' ? value : '');

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	$effect(() => {
		const v = draft;
		ondraft?.(v === '' ? null : v, true);
	});

	/** The picker's record menu is open — its own keys own the event. The
	 *  menu nodes always render; only the `ref-menu-show` class toggles. */
	function menuOpen(): boolean {
		return rootEl?.querySelector('.ref-menu-show') != null;
	}

	/** Mount action for the degrade input — focus it on open. */
	function focusInputAction(node: HTMLInputElement): void {
		node.focus();
	}

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter' || e.key === 'Tab') {
			if (driver && menuOpen()) return; // the picker picks the highlighted record
			e.preventDefault();
			oncommit(
				draft === '' ? null : draft,
				e.key === 'Enter' ? 'down' : e.shiftKey ? null : 'right'
			);
		} else if (e.key === 'Escape') {
			if (driver && menuOpen()) return; // the picker closes its menu first
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="ref-editor" bind:this={rootEl} onkeydown={handleKeydown}>
	{#if driver}
		<ReferencePicker
			bind:value={draft}
			doctype={field.doctype}
			filter={field.filter}
			{driver}
			placeholder={ariaLabel}
			hideType
		/>
	{:else}
		<input
			use:focusInputAction
			class="ref-plain"
			type="text"
			bind:value={draft}
			aria-label={ariaLabel}
		/>
	{/if}
</div>

<style>
	.ref-editor {
		flex: 1;
		min-width: 0;
		height: 100%;
		display: flex;
		align-items: center;
	}

	.ref-editor :global(.ref-wrap) {
		flex: 1;
		min-width: 0;
		border: none;
		background: none;
		padding: 0;
		box-shadow: none;
	}

	.ref-editor :global(.ref-input) {
		font-size: 13px;
		padding: 0;
		background: none;
		border: none;
		height: 100%;
	}

	.ref-editor :global(.ref-menu) {
		z-index: 45;
	}

	.ref-plain {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: none;
		background: none;
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		outline: none;
		padding: 0;
	}
</style>
