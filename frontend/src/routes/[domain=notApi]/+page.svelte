<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DomainDashboard from '$lib/components/features/dashboard/DomainDashboard.svelte';
	import * as m from '$lib/paraglide/messages';

	let { data } = $props();
</script>

<svelte:head>
	<title>{m.dashboard_domain_page_title({ name: data.domain.label })}</title>
</svelte:head>

<div class="domain-overview">
	<DomainDashboard driver={data.driver} domain={data.domain} />
</div>

<style>
	.domain-overview {
		padding: 24px;
	}
</style>
