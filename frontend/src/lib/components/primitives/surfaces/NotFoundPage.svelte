<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { History, Search, FileX, ServerCrash } from '@lucide/svelte';
	import Button from '../actions/Button.svelte';

	let {
		status = '404',
		title,
		message,
		deleted = false,
		homeHref = '/',
		historyHref
	}: {
		/** HTTP status to show — `404` (not found) or `410` (gone/deleted). */
		status?: '404' | '410' | '500';
		/** Primary headline. When omitted, a default is derived from `status`/`deleted`. */
		title?: string;
		/** Optional secondary detail line (e.g. the id of the missing record). */
		message?: string;
		/** When true, renders the soft-deleted illustration and wording. */
		deleted?: boolean;
		/** Link for the primary action. Defaults to the dashboard. */
		homeHref?: string;
		/** When set on a deleted-document page, renders a secondary History action. */
		historyHref?: string;
	} = $props();

	const headline = $derived(
		title ??
			(deleted
				? m.errors_deleted_title()
				: status === '500'
					? m.errors_500_title()
					: m.errors_404_title())
	);
</script>

<div class="nfp" class:nfp-deleted={deleted}>
	<div class="nfp-illus" aria-hidden="true">
		{#if deleted}
			<FileX size={120} strokeWidth={1.5} />
		{:else if status === '500'}
			<ServerCrash size={120} strokeWidth={1.5} />
		{:else}
			<Search size={120} strokeWidth={1.5} />
		{/if}
	</div>

	<div class="nfp-code">{status}</div>
	<h1 class="nfp-title">{headline}</h1>
	{#if message}
		<p class="nfp-message">{message}</p>
	{/if}
	<div class="nfp-actions">
		<div class="nfp-actions-row">
			<Button href={homeHref} variant="primary" size="md">{m.common_back_to_dashboard()}</Button>
			{#if deleted && historyHref}
				<Button href={historyHref} variant="secondary" size="md">
					{#snippet iconLeft()}
						<History size={15} strokeWidth={2} aria-hidden="true" />
					{/snippet}
					{m.doc_history()}
				</Button>
			{/if}
		</div>
	</div>
</div>

<style>
	.nfp {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		text-align: center;
		gap: 10px;
		padding: 48px 24px;
		min-height: 100%;
		width: 100%;
		max-width: 560px;
		margin: 0 auto;
	}

	.nfp-illus {
		color: var(--accent-ink);
		margin-bottom: 6px;
	}

	.nfp-deleted .nfp-illus {
		color: var(--danger);
	}

	.nfp-code {
		font-family: var(--font-display);
		font-size: 56px;
		line-height: 1;
		font-weight: 700;
		letter-spacing: 0.02em;
		color: var(--text);
	}

	.nfp-title {
		font-family: var(--font-sans);
		font-size: 18px;
		font-weight: 600;
		margin: 0;
		color: var(--text-2);
	}

	.nfp-message {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-3);
		word-break: break-word;
		max-width: 440px;
	}

	.nfp-actions {
		margin-top: 14px;
	}

	.nfp-actions-row {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 10px;
		flex-wrap: wrap;
	}
</style>
