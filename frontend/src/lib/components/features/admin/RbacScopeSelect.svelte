<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Select } from 'bits-ui';
	import { ALL_SCOPE, NONE_SCOPE, type ScopeValue } from './rbacModel.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Available scope option (a named scope declared on the doctype).
	 * `value` is the wire alias (`$mine`); `label` is the human label.
	 */
	type ScopeOption = { value: string; label: string };

	let {
		options,
		selected = $bindable([]),
		onchange,
		placeholder = m.common_none()
	}: {
		/** Named-scope aliases declared on this doctype. Empty when none declared. */
		options: ScopeOption[];
		/** Currently-selected scope aliases (e.g. `['$mine', '$global']`). */
		selected?: ScopeValue[];
		/** Fires with the new selection on every change. */
		onchange?: (next: ScopeValue[]) => void;
		placeholder?: string;
	} = $props();

	// Bits UI's multi-select keeps `value` as `string[]`. Sentinels
	// `NONE_SCOPE` (`''`) and `ALL_SCOPE` (`'$all'`) are emitted as their
	// own pseudo-items at the top; we intercept them in `onValueChange` so
	// they replace the whole selection rather than toggling.
	let value = $state<string[]>([...selected]);

	// Sync external `selected` changes (e.g. role switch) into the picker.
	// Equality guard prevents the effect from running on every re-render of the
	// parent where the `selected` array identity changes but its contents don't;
	// otherwise assigning `value = [...selected]` would re-trigger `handleChange`
	// via the Bits UI `onValueChange` callback and Ping-Pong back to `selected`.
	$effect(() => {
		const next = [...selected];
		if (value.length !== next.length || value.some((v, i) => v !== next[i])) {
			value = next;
		}
	});

	function handleChange(next: string[]): void {
		// Picking "None" clears everything; picking "All" collapses to
		// unrestricted (matches the rbacModel's union rule that any `$all`
		// makes the permission unrestricted). A custom-scope click while "All"
		// is selected drops the sentinel (B-194) — the click must land instead
		// of silently refusing. Other selections are kept verbatim,
		// de-duplicated.
		//
		// Bits UI commits its toggle into the bound `value` before this
		// handler runs, so `value` already equals `next` here. Whether the
		// sentinel was on before this click comes from the last applied
		// selection (`selected`): when it held the sentinel, the click landed
		// on a custom scope — drop the sentinel; when it did not, the click
		// landed on "All" itself — collapse to it.
		let applied: string[];
		if (next.includes(NONE_SCOPE)) {
			applied = [];
		} else if (next.includes(ALL_SCOPE)) {
			applied = selected.includes(ALL_SCOPE)
				? dedupe(next.filter((v) => v !== ALL_SCOPE))
				: [ALL_SCOPE];
		} else {
			applied = dedupe(next);
		}
		value = applied;
		selected = [...applied];
		onchange?.([...applied]);
	}

	function dedupe(arr: string[]): string[] {
		const out: string[] = [];
		for (const v of arr) if (!out.includes(v)) out.push(v);
		return out;
	}

	const isAll = $derived(value.length === 1 && value[0] === ALL_SCOPE);
	const isEmpty = $derived(value.length === 0);

	const displayText = $derived.by(() => {
		if (isEmpty) return placeholder;
		if (isAll) return m.audit_filter_all_option();
		if (value.length === 1) {
			const opt = options.find((o) => o.value === value[0]);
			return opt ? opt.label : value[0];
		}
		return m.admin_scopes_count({ count: value.length });
	});

	const status = $derived(isEmpty ? 'none' : isAll ? 'all' : 'custom');
</script>

<div class="scope-select" data-status={status}>
	<Select.Root type="multiple" bind:value onValueChange={handleChange}>
		<Select.Trigger class="scope-select-trigger">
			<span class="scope-select-field" class:is-placeholder={isEmpty}>
				{displayText}
			</span>
			<span class="scope-select-chevron" aria-hidden="true">▼</span>
		</Select.Trigger>
		<Select.Portal>
			<Select.Content class="scope-select-dropdown" align="start" sideOffset={4}>
				<Select.Viewport>
					<!-- None: clears every selection. -->
					<Select.Item value={NONE_SCOPE} class="scope-select-item">
						{#snippet children({ highlighted, selected: itemSelected })}
							<span class="scope-select-item-label" class:highlighted class:selected={itemSelected}>
								{m.common_none()}
							</span>
						{/snippet}
					</Select.Item>
					<!-- All: explicit unrestricted (collapses other selections). -->
					<Select.Item value={ALL_SCOPE} class="scope-select-item">
						{#snippet children({ highlighted, selected: itemSelected })}
							<span class="scope-select-item-label" class:highlighted class:selected={itemSelected}>
								{m.audit_filter_all_option()}
							</span>
						{/snippet}
					</Select.Item>
					{#if options.length > 0}
						<Select.Group>
							<Select.GroupHeading class="scope-select-group-heading">
								{m.admin_custom_scopes_group()}
							</Select.GroupHeading>
							{#each options as opt (opt.value)}
								<Select.Item value={opt.value} class="scope-select-item">
									{#snippet children({ selected: itemSelected, highlighted })}
										<span
											class="scope-select-item-label"
											class:highlighted
											class:selected={itemSelected}
										>
											{opt.label}
										</span>
									{/snippet}
								</Select.Item>
							{/each}
						</Select.Group>
					{/if}
				</Select.Viewport>
			</Select.Content>
		</Select.Portal>
	</Select.Root>
</div>

<style>
	/* Trigger — :global because Bits UI renders the <button>. */
	:global(.scope-select-trigger) {
		position: relative;
		display: flex;
		align-items: center;
		width: 100%;
		font-family: var(--font-sans);
		font-size: 12.5px;
		line-height: 1.5;
		padding: 6px 24px 6px 9px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
		text-align: left;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}
	:global(.scope-select-trigger:hover) {
		background: var(--surface-2);
	}
	:global(.scope-select-trigger:focus-visible),
	:global(.scope-select-trigger[data-state='open']) {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.scope-select-field {
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.scope-select-field.is-placeholder {
		color: var(--text-3);
	}

	.scope-select-chevron {
		position: absolute;
		right: 8px;
		top: 50%;
		transform: translateY(-50%);
		font-size: 0.55em;
		color: var(--text-3);
		pointer-events: none;
		line-height: 1;
	}

	:global(.scope-select-dropdown) {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		max-height: 260px;
		overflow-y: auto;
		z-index: 1100;
		padding: 4px;
		min-width: var(--bits-select-trigger-width);
	}

	:global(.scope-select-item) {
		padding: 6px 8px;
		font-size: 13px;
		color: var(--text);
		border-radius: var(--r-sm);
		cursor: pointer;
		list-style: none;
		display: flex;
		align-items: center;
	}
	:global(.scope-select-item[data-highlighted]) {
		background: var(--accent-weak);
		outline: none;
	}
	:global(.scope-select-item[data-selected]) {
		font-weight: 600;
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.scope-select-item-label {
		display: block;
	}
	.scope-select-item-label.selected::before {
		content: '✓ ';
		margin-right: 2px;
		color: var(--accent-ink);
	}

	:global(.scope-select-group-heading) {
		padding: 6px 8px 2px;
		font-size: 10.5px;
		font-weight: 700;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.scope-select[data-status='all'] :global(.scope-select-trigger) {
		border-color: var(--accent);
	}
	.scope-select[data-status='custom'] :global(.scope-select-trigger) {
		border-color: color-mix(in srgb, var(--accent) 50%, var(--border));
	}
</style>
