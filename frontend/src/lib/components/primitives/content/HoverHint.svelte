<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Tooltip } from 'bits-ui';
	import { HelpCircle } from '@lucide/svelte';
	import '../shared.css';

	/**
	 * HoverHint — a compact (?) affordance that reveals its `text` on hover
	 * and keyboard focus. Built on the Bits UI `Tooltip` so the hint is
	 * positioned, portalled and focus-managed like every other tooltip.
	 * Renders nothing when `text` is empty, so callers can pass an optional
	 * description through unconditionally.
	 *
	 * Used inline next to a label (e.g. a domain or doctype name) to surface
	 * a longer description without consuming layout space.
	 */

	let {
		text,
		label = 'Description',
		size = 13
	}: {
		/** Hint body. When empty, the component renders nothing. */
		text?: string;
		/** Accessible label for the trigger (defaults to "Description"). */
		label?: string;
		/** Icon size in pixels. */
		size?: number;
	} = $props();
</script>

{#if text}
	<span class="hover-hint">
		<Tooltip.Provider>
			<Tooltip.Root>
				<Tooltip.Trigger class="hover-hint-trigger" aria-label={label}>
					<HelpCircle {size} strokeWidth={1.9} aria-hidden="true" />
				</Tooltip.Trigger>
				<Tooltip.Portal>
					<Tooltip.Content class="tooltip-pop" sideOffset={6}>
						{text}
						<Tooltip.Arrow />
					</Tooltip.Content>
				</Tooltip.Portal>
			</Tooltip.Root>
		</Tooltip.Provider>
	</span>
{/if}

<style>
	.hover-hint {
		display: inline-flex;
	}

	/* Bits UI renders the trigger as a <button> — style it via :global. */
	:global(.hover-hint-trigger) {
		display: inline-flex;
		align-items: center;
		color: var(--text-3);
		cursor: help;
		background: none;
		border: none;
		padding: 1px;
		border-radius: var(--r-sm);
	}

	:global(.hover-hint-trigger:hover),
	:global(.hover-hint-trigger:focus-visible) {
		color: var(--text);
		outline: none;
	}
</style>
