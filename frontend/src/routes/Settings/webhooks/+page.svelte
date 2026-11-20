<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import WebhookManager from '$lib/components/features/settings/WebhookManager.svelte';
	import * as m from '$lib/paraglide/messages';

	// Webhooks bind to the creating account (`account_id` stamped at create),
	// so the manager narrows the list to the caller's own rows — the same
	// self-service model as the API keys page.
	const accountId = $derived(page.data.account?.id ?? '');
</script>

<svelte:head>
	<title>{m.webhooks_page_title()}</title>
</svelte:head>

<div class="page-head">
	<h1>{m.webhooks_title()}</h1>
	<span class="head-sub">{m.webhooks_subtitle()}</span>
</div>

<WebhookManager accountId={accountId || undefined} />

<style>
	.page-head {
		display: flex;
		align-items: baseline;
		gap: 12px;
		padding: 8px 32px 16px;
	}

	h1 {
		font-family: var(--font-display);
		font-size: 20px;
		font-weight: 600;
		margin: 0;
	}

	.head-sub {
		font-size: 13px;
		color: var(--text-3);
	}
</style>
