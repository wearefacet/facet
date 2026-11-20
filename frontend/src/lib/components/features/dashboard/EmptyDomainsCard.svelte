<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import NewDomainDialog from './NewDomainDialog.svelte';

	/**
	 * EmptyDomainsCard — the dashboard's empty-state call to action. Renders
	 * in place of the "No domains available" notice card when the account has
	 * no domains and may create them; it carries the same handoff as the
	 * welcome tour's final step. The
	 * backend re-checks the write — the caller's `can()` gate is a UI hint.
	 */

	let {
		/**
		 * Injectable draft-creation flow — returns `null` on success or an
		 * error message shown inline. The app wires `POST /Api/core/Domain/draft`
		 * + navigation to the new draft's Builder overview; stories a spy.
		 */
		oncreate = (_input: { name: string; label?: string }) => Promise.resolve(null)
	}: {
		oncreate?: (input: { name: string; label?: string }) => Promise<string | null>;
	} = $props();

	// The import dialog opens itself from this deep link (the domains page
	// accepts `?import=1` on mount) — the same destination the tour's
	// secondary CTA uses.
	const importHref = `${resolve('/Configure/domains')}?import=1`;

	let dialogOpen = $state(false);
</script>

<div class="empty-domains">
	<h2 class="ed-title">{m.dashboard_empty_domains_title()}</h2>
	<p class="ed-body">{m.dashboard_empty_domains_body()}</p>
	<div class="ed-actions">
		<Button variant="primary" size="md" onclick={() => (dialogOpen = true)}>
			{m.dashboard_empty_domains_new()}
		</Button>
		<Button variant="secondary" size="md" href={importHref}>
			{m.dashboard_empty_domains_import()}
		</Button>
	</div>

	<NewDomainDialog bind:open={dialogOpen} {oncreate} />
</div>

<style>
	.empty-domains {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 18px 20px;
	}

	.ed-title {
		font-family: var(--font-display);
		font-size: 14px;
		font-weight: 600;
		margin: 0 0 4px;
		color: var(--text);
	}

	.ed-body {
		font-size: 12.5px;
		color: var(--text-2);
		margin: 0 0 14px;
		line-height: 1.5;
	}

	.ed-actions {
		display: flex;
		align-items: center;
		gap: 8px;
	}
</style>
