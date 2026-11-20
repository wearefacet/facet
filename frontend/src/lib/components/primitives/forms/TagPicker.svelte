<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * TagPicker — multi-select chip control for picking a subset of known options.
	 *
	 * Renders a list of toggleable tags. Selected tags are highlighted; clicking
	 * toggles membership. Intended for small, closed option sets (e.g. the fields
	 * of a doctype) where a full multi-select dropdown is heavier than needed.
	 */
	import * as m from '$lib/paraglide/messages';

	let {
		options,
		selected,
		disabled = false,
		label,
		ontoggle
	}: {
		/** Available tags. */
		options: { value: string; label?: string }[];
		/** Currently selected values. */
		selected: string[];
		/** Disable interaction (e.g. when a wildcard overrides the selection). */
		disabled?: boolean;
		/** Optional field label. */
		label?: string;
		/** Called with the new selection array whenever a tag is toggled. */
		ontoggle?: (next: string[]) => void;
	} = $props();

	const fieldId = $derived(label ? `tag-${label}` : undefined);

	function toggle(value: string): void {
		if (disabled) return;
		const next = selected.includes(value)
			? selected.filter((v) => v !== value)
			: [...selected, value];
		ontoggle?.(next);
	}
</script>

<div class="tag-wrap" id={fieldId} class:tag-disabled={disabled}>
	{#if options.length === 0}
		<span class="tag-empty">{m.common_options_empty()}</span>
	{:else}
		{#each options as opt (opt.value)}
			{@const on = selected.includes(opt.value)}
			<button
				type="button"
				class="tag"
				class:on
				{disabled}
				aria-pressed={on}
				onclick={() => toggle(opt.value)}
			>
				{opt.label ?? opt.value}
			</button>
		{/each}
	{/if}
</div>

<style>
	.tag-wrap {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		align-items: center;
		min-height: 32px;
	}

	.tag {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 3px 10px;
		border-radius: 999px;
		font: 400 12px/1 var(--font-sans);
		font-family: var(--font-mono);
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border-2);
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s,
			border-color 0.12s;
	}

	.tag:hover:not(:disabled) {
		border-color: var(--accent);
		color: var(--text-1);
	}

	.tag.on {
		background: var(--accent);
		color: var(--on-accent);
		border-color: var(--accent);
	}

	.tag:disabled {
		cursor: not-allowed;
		opacity: 0.45;
	}

	.tag-disabled .tag {
		cursor: not-allowed;
		opacity: 0.45;
	}

	.tag-empty {
		color: var(--text-3);
		font-size: 12px;
	}
</style>
