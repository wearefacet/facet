<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import ExportMenu from './ExportMenu.svelte';
	import ImportDialog from './ImportDialog.svelte';
	import type { ViewExportItem } from '$lib/importExport/importExportClient.js';

	/**
	 * ImportExportActions — the table toolbar's export + import affordances
	 * for one doctype. The export menu enqueues immediately; the import
	 * dialog owns the file pick through the job report. `view` carries the
	 * table's current state for the "CSV — current view" export item;
	 * `null` (trash mode, or a surface with no view export) hides it.
	 */
	let {
		domain,
		doctype,
		view = null,
		onimported
	}: {
		domain: string;
		doctype: string;
		view?: ViewExportItem | null;
		/** Forwarded to the import dialog — the host refreshes its list on it. */
		onimported?: () => void;
	} = $props();

	let importOpen = $state(false);
</script>

<div class="ie-actions">
	<ExportMenu {domain} {doctype} {view} />
	<button class="ie-import-btn" type="button" onclick={() => (importOpen = true)}>
		{m.impex_import()}
	</button>
</div>

<ImportDialog bind:open={importOpen} {domain} {doctype} {onimported} />

<style>
	.ie-actions {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		margin-left: auto;
	}

	.ie-import-btn {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
		background: transparent;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		padding: 4px 10px;
		cursor: pointer;
	}

	.ie-import-btn:hover {
		background: var(--surface-2);
		color: var(--text);
	}

	.ie-import-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
