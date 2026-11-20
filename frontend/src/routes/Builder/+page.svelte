<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import BuilderLandingEmpty from '$lib/components/features/builder/BuilderLandingEmpty.svelte';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	let drafts = $derived(data.draftDomains);
</script>

<svelte:head>
	<title>{m.builder_page_title()}</title>
</svelte:head>

<div class="builder-home">
	<div class="dash-head">
		<span class="dt-mark" style="background: var(--accent)"></span>
		<h1>{m.builder_mode_title()}</h1>
	</div>

	{#if drafts.length === 0}
		<BuilderLandingEmpty />
	{:else}
		<div class="draft-grid">
			{#each drafts as d (d.id)}
				<a
					class="draft-card"
					href={resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: d.id })}
				>
					<span class="dot" style={`background:${d.color}`}></span>
					<span class="draft-name">{d.label}</span>
					<span class="draft-count">{m.common_doctypes_count({ count: d.doctypes.length })}</span>
					{#if d.check}
						<span
							class="issue-chip"
							class:warn={d.check.issue_count > 0}
							class:ok={d.check.issue_count === 0}
							title={d.check.issue_count > 0
								? m.common_issues_check_title({ count: d.check.issue_count })
								: m.common_check_ready_title()}
						>
							{#if d.check.issue_count > 0}
								{d.check.issue_count}⚠
							{:else}
								✓
							{/if}
						</span>
					{/if}
				</a>
			{/each}
		</div>
	{/if}
</div>

<style>
	.builder-home {
		padding: 24px;
		max-width: 960px;
	}

	.draft-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
		gap: 12px;
	}

	.draft-card {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 14px 16px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		text-decoration: none;
		transition:
			border-color 0.12s ease,
			background 0.12s ease;
	}

	.draft-card:hover {
		border-color: var(--accent);
		background: var(--surface-2, var(--surface));
	}

	.draft-card .dot {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	.draft-name {
		font-weight: 600;
		font-size: 13px;
		color: var(--text);
	}

	.draft-count {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.issue-chip {
		flex: none;
		margin-left: 8px;
		padding: 2px 7px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		border: 1px solid transparent;
		line-height: 1.4;
	}

	.issue-chip.warn {
		background: var(--warn-weak, rgba(217, 119, 6, 0.12));
		color: var(--warn);
		border-color: var(--warn);
	}

	.issue-chip.ok {
		background: var(--ok-weak, rgba(34, 197, 94, 0.08));
		color: var(--ok);
		border-color: var(--ok);
	}

	.dash-head {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 24px;
		flex-wrap: wrap;
	}

	.dt-mark {
		width: 10px;
		height: 10px;
		border-radius: 3px;
		transform: rotate(45deg);
		flex: none;
	}

	.dash-head h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
	}
</style>
