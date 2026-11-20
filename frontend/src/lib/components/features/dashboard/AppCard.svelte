<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import { Lock } from '@lucide/svelte';

	/**
	 * AppCard — one application card on the dashboard launcher.
	 *
	 * A usable app is a link to the app's Configure page. An app the active
	 * role cannot open renders as a muted, non-interactive card with a
	 * notice. The account sees the app and can ask for access.
	 */
	let {
		name,
		slug,
		usable = true
	}: {
		name: string;
		slug: string;
		usable?: boolean;
	} = $props();
</script>

{#if usable}
	<a class="card" href={resolve('/Configure/apps/[slug]', { slug })}>
		<span class="name">{name}</span>
	</a>
{:else}
	<div class="card locked" aria-disabled="true">
		<span class="name">{name}</span>
		<span class="notice-title">
			<Lock size={12} stroke-width={1.8} aria-hidden="true" />
			{m.apps_not_usable_title()}
		</span>
		<span class="notice-body">{m.apps_not_usable_body()}</span>
	</div>
{/if}

<style>
	.card {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 14px 16px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		text-decoration: none;
		color: inherit;
		transition:
			border-color 0.1s ease,
			background 0.1s ease;
	}

	a.card:hover {
		border-color: var(--accent);
		background: var(--sunken);
	}

	.name {
		font-family: var(--font-display);
		font-weight: 600;
		font-size: 13px;
		color: var(--text);
	}

	.locked {
		cursor: default;
	}

	.locked .name {
		color: var(--text-3);
	}

	.notice-title {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
	}

	.notice-body {
		font-size: 11.5px;
		line-height: 1.45;
		color: var(--text-3);
	}
</style>
