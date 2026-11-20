<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
</script>

<!--
	Landing empty state for /Builder.

	The guidance names the sidebar's "New domain" button, so it renders only
	for roles that hold the same `core.Domain` create grant that button is
	gated on. Other roles see the neutral line instead.
-->
<Can doctype="core.Domain" action="create">
	<p class="empty-line">
		{m.builder_landing_empty_pre()}<strong>{m.dashboard_new_domain_title()}</strong
		>{m.builder_landing_empty_mid()}<strong>{m.builder_edit_existing()}</strong>.
	</p>
	{#snippet fallback()}
		<p class="empty-line">{m.configure_domains_drafts_empty()}</p>
	{/snippet}
</Can>

<style>
	.empty-line {
		font-size: 13.5px;
		color: var(--text-3);
		line-height: 1.5;
	}

	.empty-line strong {
		color: var(--text);
	}
</style>
