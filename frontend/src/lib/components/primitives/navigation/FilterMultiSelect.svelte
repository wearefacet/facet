<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Select } from 'bits-ui';
	import * as m from '$lib/paraglide/messages';

	/** One pickable value — the flat option shape the multi-select takes. */
	export type MultiOption = { value: string; label: string };

	/**
	 * FilterMultiSelect — the chip value control for the `in` operator.
	 *
	 * A compact multi-select over a field's enum options. Selections emit as
	 * a `string[]` (the `field__in` array; the wire form JSON-encodes it in
	 * `filterParams.ts`). Unchecked items disable once the selection reaches
	 * `max` — the backend `Util::FilterSet::MAX_IN_VALUES` bound, past which
	 * an `__in` array degrades to an always-false clause.
	 */
	let {
		options,
		selected = [],
		max,
		ariaLabel,
		placeholder = m.list_filter_pick_placeholder(),
		onchange
	}: {
		/** Pickable values (the field's enum options). */
		options: MultiOption[];
		/** Currently selected values (the `field__in` array). */
		selected?: string[];
		/** Selection cap — further picks disable at the limit. */
		max?: number;
		/** Accessible name for the trigger button. */
		ariaLabel: string;
		/** Trigger text while nothing is selected. */
		placeholder?: string;
		/** Fires with the new value array on every change. */
		onchange?: (next: string[]) => void;
	} = $props();

	// Bits UI multi-select keeps `value` as `string[]`. One-way sync with an
	// equality guard: the parent owns the filter map and reflects it back, so
	// an unguarded re-assign would ping-pong through `onValueChange` (the
	// writeback-effect trap in the workflow doc). The state starts empty and
	// the guard seeds it — reading `selected` into the initializer would
	// capture only the prop's initial value.
	let value = $state<string[]>([]);
	$effect(() => {
		const next = [...selected];
		if (value.length !== next.length || value.some((v, i) => v !== next[i])) {
			value = next;
		}
	});

	function handleChange(next: string[]): void {
		// De-duplicate; the disabled items gate the cap, so the array stays
		// within it without silently dropping a visible pick.
		const applied: string[] = [];
		for (const v of next) if (!applied.includes(v)) applied.push(v);
		value = applied;
		onchange?.([...applied]);
	}

	const atCap = $derived(max != null && value.length >= max);

	const displayText = $derived.by(() => {
		if (value.length === 0) return placeholder;
		return value.map((v) => options.find((o) => o.value === v)?.label ?? v).join(', ');
	});
</script>

<Select.Root type="multiple" bind:value onValueChange={handleChange}>
	<Select.Trigger class="fms-trigger" aria-label={ariaLabel}>
		<span class="fms-field" class:fms-placeholder={value.length === 0}>{displayText}</span>
		<span class="fms-caret" aria-hidden="true">▼</span>
	</Select.Trigger>
	<Select.Portal>
		<Select.Content class="fms-menu menu-surface" align="start" sideOffset={4}>
			<Select.Viewport>
				{#each options as opt (opt.value)}
					<Select.Item
						value={opt.value}
						class="fms-item menu-item"
						disabled={atCap && !value.includes(opt.value)}
					>
						{#snippet children({ selected: itemSelected })}
							<span class="fms-item-label" class:fms-on={itemSelected}>
								{opt.label}
							</span>
						{/snippet}
					</Select.Item>
				{/each}
			</Select.Viewport>
		</Select.Content>
	</Select.Portal>
</Select.Root>

<style>
	/* ── Trigger — :global because Bits UI renders the <button> ─────────── */
	:global(.fms-trigger) {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		max-width: 200px;
		border: none;
		background: none;
		padding: 0;
		font: inherit;
		font-size: 12.5px;
		color: var(--text);
		cursor: pointer;
	}

	:global(.fms-trigger:focus-visible) {
		outline: 1px solid var(--accent);
		border-radius: var(--r-sm);
	}

	.fms-field {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.fms-placeholder {
		color: var(--text-3);
	}

	.fms-caret {
		font-size: 0.6em;
		line-height: 1;
		opacity: 0.7;
		color: var(--text-3);
	}

	/* ── Menu — surface and item base come from the shared menu classes ── */
	:global(.fms-menu) {
		max-height: 240px;
		overflow-y: auto;
		z-index: 1100;
		min-width: 150px;
		font-size: 12.5px;
	}

	.fms-item-label {
		display: block;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.fms-item-label.fms-on::before {
		content: '✓ ';
		margin-right: 2px;
		color: var(--accent-ink);
	}

	.fms-item-label.fms-on {
		font-weight: 600;
		color: var(--accent-ink);
	}
</style>
