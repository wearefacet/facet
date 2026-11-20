<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RbacScopeSelect from './RbacScopeSelect.svelte';
	import HoverHint from '../../primitives/content/HoverHint.svelte';
	import { humanize } from '$lib/doctype/types.js';
	import type { DoctypeNode, ScopeValue } from './rbacModel.js';
	import * as m from '$lib/paraglide/messages';
	import {
		descendantCount,
		actionsFor,
		actionDescription,
		CORE_ACTIONS,
		ALL_SCOPE,
		scopeOptionsFor
	} from './rbacModel.js';

	let {
		node,
		state,
		onSet,
		expandable = false,
		expanded = false,
		onToggleExpand
	}: {
		node: DoctypeNode;
		state: Record<string, Partial<Record<string, ScopeValue[]>>>;
		/** Replace the scope selection for a (qualified, action) pair. */
		onSet: (qualified: string, action: string, value: ScopeValue[]) => void;
		/** Whether this node has children (so the accordion caret is rendered). */
		expandable?: boolean;
		/** Accordion open state for this node (only meaningful when expandable). */
		expanded?: boolean;
		/** Toggle the accordion state for this node. */
		onToggleExpand?: () => void;
	} = $props();

	const depthPx = $derived(node.depth * 18);
	const numDescendants = $derived(descendantCount(node));

	// Actions rendered as pickers in this row: the four canonical CRUD
	// actions followed by any custom (named) actions declared on the doctype,
	// alphabetically. Custom actions become real permissions in the wire
	// format (e.g. `{action: 'move_stage', on: 'crm.Deal'}`).
	const actions = $derived(actionsFor(node.def));

	// Custom-scope options declared on this doctype. Empty for doctypes
	// without a `scopes:` block — the picker's "Custom scopes" group is
	// omitted entirely in that case.
	const customScopes = $derived(scopeOptionsFor(node.def));

	// Per-action current scope selection. Falls back to an empty array
	// ("None") when no row exists for this doctype yet, or when the action
	// hasn't been set.
	function scopeOf(action: string): ScopeValue[] {
		return state[node.qualified]?.[action] ?? [];
	}

	// "Active" = at least one action grants access. Drives the row's accent
	// background + the doctype name color, so touched doctypes stand out at
	// a glance when scrolling through hundreds of rows.
	const rowState = $derived(state[node.qualified]);
	const activeActions = $derived(
		rowState ? actions.filter((a) => (rowState[a]?.length ?? 0) > 0) : []
	);
	const isActive = $derived(activeActions.length > 0);
	// Per-action status: 'none' | 'all' | 'custom'. Used to color each
	// picker's wrapper so the user sees the access type without opening it.
	function statusOf(action: string): 'none' | 'all' | 'custom' {
		const v = scopeOf(action);
		if (v.length === 0) return 'none';
		if (v.length === 1 && v[0] === ALL_SCOPE) return 'all';
		return 'custom';
	}
</script>

<div
	role="treeitem"
	aria-selected="false"
	aria-expanded={expandable ? expanded : undefined}
	class="node-row"
	class:node-active={isActive}
	class:node-root={node.depth === 0}
	style="--node-depth: {node.depth}; padding-left: {depthPx + 12}px"
>
	<div class="node-head">
		<button
			type="button"
			class="node-caret"
			class:caret-open={expanded}
			class:caret-hidden={!expandable}
			onclick={() => expandable && onToggleExpand?.()}
			aria-expanded={expandable ? expanded : undefined}
			aria-label={expanded ? m.admin_collapse_button() : m.admin_expand_button()}
			title={expanded ? m.admin_collapse_subtree_title() : m.admin_expand_subtree_title()}
			disabled={!expandable}
		></button>
		<span class="node-name" title={node.def.doctype}>{node.doctype}</span>
		{#if node.def.description}
			<HoverHint
				text={node.def.description}
				label={m.admin_doctype_hint_aria({ name: node.qualified })}
			/>
		{/if}
		<div class="node-spacer"></div>
		{#if isActive}
			<span
				class="node-active-badge"
				title={m.admin_active_badge_title({ count: activeActions.length })}
			>
				{m.admin_active_badge({ count: activeActions.length })}
			</span>
		{/if}
		{#if numDescendants > 0}
			<button
				type="button"
				class="node-cascade"
				class:caret-open={expanded}
				onclick={() => onToggleExpand?.()}
				aria-expanded={expanded}
				title={m.admin_cascade_title({ count: numDescendants })}
			>
				{expanded
					? m.admin_cascade_collapse({ count: numDescendants })
					: m.admin_cascade_expand({ count: numDescendants })}
			</button>
		{/if}
	</div>
	<div class="node-actions">
		{#each actions as action (action)}
			<div class="node-action" data-status={statusOf(action)}>
				<span
					class="node-action-label"
					class:node-action-custom={!CORE_ACTIONS.includes(action as (typeof CORE_ACTIONS)[number])}
				>
					{humanize(action)}
					<!-- Renders nothing without a description — CRUD labels stay bare. -->
					<HoverHint
						text={actionDescription(node.def, action)}
						label={m.admin_action_hint_aria({ action: humanize(action) })}
					/>
				</span>
				<RbacScopeSelect
					options={customScopes}
					selected={scopeOf(action)}
					onchange={(v) => onSet(node.qualified, action, v)}
				/>
			</div>
		{/each}
	</div>
</div>

<style>
	/* Alternating depth tint: even depths use surface, odd depths use
	   surface-2. Root rows get a slightly stronger surface-3 to visually
	   delimit aggregate roots across the tree. */
	.node-row {
		border-bottom: 1px solid var(--border);
		padding: 8px 12px 10px;
		display: flex;
		flex-direction: column;
		gap: 8px;
		background: var(--surface);
	}
	.node-row:last-child {
		border-bottom: none;
	}

	/* Zebra striping for non-root rows by depth parity. */
	.node-row:not(.node-root) {
		background: var(--surface-2);
	}

	/* Active row: tint the whole wrapper so touched doctypes are visible
	   at a glance when scrolling through hundreds of rows. */
	.node-row.node-active {
		background: color-mix(in srgb, var(--accent-weak) 60%, var(--surface));
	}
	.node-row.node-active:not(.node-root) {
		background: color-mix(in srgb, var(--accent-weak) 50%, var(--surface-2));
	}

	/* Stronger visual delimiter for aggregate roots (depth 0). */
	.node-row.node-root {
		border-top: 2px solid var(--border-strong);
	}
	.node-row.node-root:first-child {
		border-top: none;
	}

	.node-head {
		display: flex;
		align-items: center;
		gap: 8px;
		min-height: 24px;
	}

	.node-caret {
		width: 16px;
		height: 16px;
		flex-shrink: 0;
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		color: var(--text-2);
		font-size: 9px;
		line-height: 1;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		border-radius: var(--r-sm);
	}
	.node-caret::before {
		content: '▶';
		display: block;
		transition: transform 0.12s;
	}
	.node-caret.caret-open::before {
		transform: rotate(90deg);
	}
	.node-caret.caret-hidden {
		visibility: hidden;
	}
	.node-caret:disabled {
		cursor: default;
	}

	.node-name {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		white-space: nowrap;
	}
	.node-active .node-name {
		color: var(--accent-ink);
	}

	.node-spacer {
		flex: 1 1 auto;
	}

	.node-active-badge {
		font-family: var(--font-mono);
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid color-mix(in srgb, var(--accent-ink) 30%, transparent);
		padding: 1px 6px;
		border-radius: var(--r-pill);
		white-space: nowrap;
	}

	.node-cascade {
		font-family: var(--font-sans);
		font-size: 11px;
		font-weight: 500;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid color-mix(in srgb, var(--accent-ink) 30%, transparent);
		padding: 3px 8px;
		border-radius: var(--r-sm);
		white-space: nowrap;
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	.node-cascade:hover {
		background: color-mix(in srgb, var(--accent-weak) 80%, var(--surface));
		border-color: color-mix(in srgb, var(--accent-ink) 50%, transparent);
	}

	/* Grid: fixed 4-column layout. The canonical CRUD four fit on row one;
	   any custom (named) actions declared on the doctype wrap onto
	   subsequent rows of 4 — so a 3-custom-action doctype renders as
	   a 4-wide first row plus a 1-wide second row, instead of crushing
	   7 pickers into one row. */
	.node-actions {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 8px 12px;
	}

	.node-action {
		display: flex;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}
	.node-action-label {
		display: inline-flex;
		align-items: center;
		gap: 3px;
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
	}
	/* Color the label + Select trigger by picker status. */
	.node-action[data-status='all'] .node-action-label {
		color: var(--accent-ink);
	}
	.node-action[data-status='custom'] .node-action-label {
		color: var(--accent-ink);
	}
	/* `none` stays neutral gray via the global rule above. */

	/* Let the Select fill its grid cell, including the trigger button. */
	.node-action :global(.select-wrap) {
		width: 100%;
	}
	.node-action :global(.select-field-wrap) {
		width: 100%;
		padding: 6px 26px 6px 9px;
		font-size: 12px;
		border: 1px solid var(--border);
		background: var(--surface);
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	/* Status-tint the trigger itself so the access type is legible at a
	   glance without opening the dropdown. */
	.node-action[data-status='all'] :global(.select-field-wrap) {
		background: color-mix(in srgb, var(--accent-weak) 70%, var(--surface));
		border-color: color-mix(in srgb, var(--accent-ink) 30%, var(--border));
	}
	.node-action[data-status='custom'] :global(.select-field-wrap) {
		background: color-mix(in srgb, var(--accent-weak) 90%, var(--surface));
		border-color: color-mix(in srgb, var(--accent-ink) 45%, var(--border));
		font-weight: 600;
	}
	.node-action :global(.select-dropdown) {
		min-width: 200px;
		max-width: 320px;
	}

	@media (max-width: 720px) {
		.node-actions {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
</style>
