<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';

	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { Snippet } from 'svelte';

	/**
	 * Schema-aware toolbar for {@link Table.svelte}.
	 *
	 * Renders the reusable {@link FilterBar} (search + "+ Add filter" menu +
	 * one chip per active filter) bound to the outbound filter map. It exists
	 * so the table keeps a stable public surface while the filter UI lives in
	 * one shared component (used by the calendar config as well).
	 *
	 * The optional `actions` snippet renders right-aligned action affordances
	 * (e.g. the import/export controls) beside the filters.
	 */
	let {
		doctype,
		filters = {},
		driver,
		onFilterChange,
		actions
	}: {
		/** Parsed doctype definition (fields with `operators`). When undefined, nothing renders. */
		doctype?: DoctypeDef;
		/** Active filters, keyed by `field__op`. */
		filters?: Record<string, unknown>;
		/** Driver used to resolve `reference` filters. When absent, references are offered as text. */
		driver?: DataDriver;
		/** Called with the new filter map on every change. */
		onFilterChange?: (filters: Record<string, unknown>) => void;
		/** Right-aligned action affordances rendered beside the filter bar. */
		actions?: Snippet;
	} = $props();

	/** Bound FilterBar instance — `focusSearch` forwards to it. */
	let filterBar = $state<{ focusSearch(): boolean } | undefined>(undefined);

	/**
	 * Focuses the search input. Returns `false` when this toolbar renders no
	 * search box (doctype without a `search` template) — the caller treats
	 * that as "not handled".
	 */
	export function focusSearch(): boolean {
		return filterBar?.focusSearch() ?? false;
	}
</script>

<div class="toolbar-row">
	<FilterBar bind:this={filterBar} {doctype} {driver} {filters} {onFilterChange} />
	{#if actions}
		<div class="toolbar-actions">{@render actions()}</div>
	{/if}
</div>

<style>
	.toolbar-row {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
	}

	.toolbar-actions {
		margin-left: auto;
	}
</style>
