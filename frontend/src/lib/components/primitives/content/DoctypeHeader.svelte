<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import { doctypeTintForDomain } from '$lib/doctype/tint.js';

	let {
		title,
		color,
		icon,
		backHref,
		backLabel = 'Back',
		version,
		qualifiedName,
		actions
	}: {
		/** Header title text (document display name, doctype label, …). */
		title: string;
		/** Doctype accent color for the diamond mark. */
		color?: string;
		/** Optional doctype icon name — falls back to the diamond mark. */
		icon?: string | null;
		/** When provided, renders a back link to `backHref` labelled `backLabel`. */
		backHref?: string;
		backLabel?: string;
		/** When provided, renders the version pill (`v{n}`). */
		version?: number | string | null;
		/** When provided, renders a doctype capsule (e.g. `"crm.Contact"`). */
		qualifiedName?: string;
		/** Optional right-aligned action controls (buttons, menus). */
		actions?: import('svelte').Snippet;
	} = $props();

	const tint = $derived(
		qualifiedName ? doctypeTintForDomain(qualifiedName.split('.')[0] ?? '') : undefined
	);
</script>

<div class="doctype-head">
	<div class="doctype-head-main">
		{#if backHref}
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- backHref is a resolved pathname supplied by the host page; the rule cannot see through the prop. -->
			<a class="back" href={backHref} title={backLabel}>
				<svg
					viewBox="0 0 24 24"
					width="16"
					height="16"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					aria-hidden="true"
				>
					<path d="M15 18l-6-6 6-6" />
				</svg>
				{backLabel}
			</a>
		{/if}
		<DoctypeIcon {icon} {color} />
		<h1>{title}</h1>
		{#if qualifiedName}
			<Capsule doctype={tint} label={qualifiedName} />
		{/if}
		{#if version != null}
			<span class="head-version" title={m.doc_version_title()}>v{version}</span>
		{/if}
	</div>
	{#if actions}
		<div class="doctype-head-actions">
			{@render actions()}
		</div>
	{/if}
</div>

<style>
	.doctype-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 20px 24px 16px;
		flex-wrap: wrap;
		border-bottom: 1px solid var(--border);
	}

	.doctype-head-main {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		min-width: 0;
	}

	.doctype-head-actions {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}

	.back {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		color: var(--text-2);
		font-size: 13px;
		font-weight: 600;
		text-decoration: none;
		padding: 4px 8px;
		margin-left: -8px;
		border-radius: var(--r-sm);
		transition:
			background 0.12s,
			color 0.12s;
	}

	.back:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.doctype-head h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
		margin: 0;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		max-width: 100%;
	}

	.head-version {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		padding: 2px 6px;
		border-radius: var(--r-sm);
		background: var(--sunken);
	}

	@media (max-width: 720px) {
		.doctype-head {
			align-items: flex-start;
		}
		.doctype-head h1 {
			white-space: normal;
		}
	}
</style>
