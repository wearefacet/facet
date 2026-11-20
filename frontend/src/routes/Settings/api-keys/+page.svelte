<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ApiKeyManager from '$lib/components/features/settings/ApiKeyManager.svelte';
	import * as m from '$lib/paraglide/messages';
</script>

<svelte:head>
	<title>{m.apikeys_page_title()}</title>
</svelte:head>

<div class="page-head">
	<h1>{m.apikeys_title()}</h1>
	<span class="head-sub">{m.apikeys_subtitle()}</span>
</div>

<ApiKeyManager />

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
