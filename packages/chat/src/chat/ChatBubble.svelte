<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Markdown from '../markdown/Markdown.svelte';

	type Role = 'user' | 'agent';

	let {
		role,
		name,
		tag,
		content = '',
		streaming = false,
		children
	}: {
		/** Who sent the message. `user` renders a right-aligned bubble; `agent` renders flush-left with a name header. */
		role: Role;
		/** Agent display name (e.g. "Steve"). Ignored for `user` role. */
		name?: string;
		/** Optional agent tag pill (e.g. "schema agent"). Ignored for `user` role. */
		tag?: string;
		/** Markdown content. Re-compiled on every change so streaming works. */
		content?: string;
		/** When true, shows a blinking caret at the end of the content. */
		streaming?: boolean;
		/** Alternative to `content`: render arbitrary Svelte content inside the bubble. */
		children?: import('svelte').Snippet;
	} = $props();
</script>

{#if role === 'user'}
	<div class="row user">
		<div class="bubble">
			{#if children}
				{@render children()}
			{:else}
				<Markdown {content} {streaming} />
			{/if}
		</div>
	</div>
{:else}
	<div class="row agent">
		{#if name}
			<div class="who">
				<span class="who-name">{name}</span>
				{#if tag}<span class="who-tag">{tag}</span>{/if}
			</div>
		{/if}
		<div class="body">
			{#if children}
				{@render children()}
			{:else}
				<Markdown {content} {streaming} />
			{/if}
		</div>
	</div>
{/if}

<style>
	.row {
		display: flex;
	}

	/* ── User bubble — right-aligned, matches .user .ub ────────────────── */
	.user {
		justify-content: flex-end;
	}
	.user .bubble {
		background: var(--facet-surface-2);
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r-lg) var(--facet-r-lg) 4px var(--facet-r-lg);
		padding: 10px 14px;
		max-width: 84%;
	}

	/* ── Agent turn — flush left, no bubble, matches .agent ─────────────── */
	.agent {
		flex-direction: column;
	}
	.agent .who {
		font-size: 11.5px;
		font-weight: 700;
		letter-spacing: 0.02em;
		color: var(--facet-accent-ink);
		margin-bottom: 5px;
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.agent .who-name {
		font-family: var(--facet-font-display);
	}
	.agent .who-tag {
		font-family: var(--facet-font-mono);
		font-size: 9.5px;
		font-weight: 600;
		color: var(--facet-text-3);
		background: var(--facet-sunken);
		border-radius: var(--facet-r-pill);
		padding: 1px 7px;
	}
	.agent .body {
		color: var(--facet-text);
	}
</style>
