<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { can } from '$lib/permissions.svelte';
	import { RotateCcw } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import { DataSourceError } from '$lib/datasource/types.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { DocumentRef } from '$lib/datasource/interface.js';

	let {
		doctype,
		doc,
		onRestored = null
	}: {
		/**
		 * Qualified doctype key, e.g. `"crm.Deal"`. Restore is gated by the
		 * existing `update` RBAC action (no dedicated `restore` permission) —
		 * the button renders disabled without it, mirroring the backend's
		 * `WriteEnforcer.authorize_update` gate.
		 */
		doctype: string;
		/** Ref to the tombstoned document to restore. */
		doc: DocumentRef;
		/**
		 * Called after the trash row leaves the listing: on a successful
		 * restore, and on a `409` no-op (the document was already restored
		 * elsewhere) so the owner refreshes instead of retrying.
		 */
		onRestored?: (() => void) | null;
	} = $props();

	let busy = $state(false);
	let message = $state<string | null>(null);

	const allowed = $derived(can(doctype, 'update'));

	async function restore(): Promise<void> {
		busy = true;
		message = null;
		try {
			await doc.restore();
			onRestored?.();
		} catch (e) {
			if (e instanceof DataSourceError && e.status === 409) {
				// Already live again (concurrent restore). A safe no-op — refresh
				// the listing so the row leaves the trash view.
				message = m.list_restore_not_deleted();
				onRestored?.();
			} else {
				message = errorMessage(e, m.list_restore_failed());
			}
		} finally {
			busy = false;
		}
	}
</script>

<span class="restore-cell">
	<Button
		variant="secondary"
		size="sm"
		disabled={!allowed || busy}
		loading={busy}
		title={allowed ? m.list_restore_title() : m.list_restore_permission_title()}
		onclick={restore}
	>
		{#snippet iconLeft()}
			<RotateCcw size={13} strokeWidth={2} aria-hidden="true" />
		{/snippet}
		{m.list_restore_button()}
	</Button>
	{#if message}
		<span class="restore-message" role="status">{message}</span>
	{/if}
</span>

<style>
	.restore-cell {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
	}

	.restore-message {
		font-size: 11.5px;
		color: var(--text-2);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
</style>
