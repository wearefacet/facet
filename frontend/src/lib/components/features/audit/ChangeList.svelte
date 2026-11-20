<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	ChangeList — the audited change rows shared by the document history
	(History) and the global audit detail (AuditDetail).

	Renders the normalized `ChangeEntry` list grouped by kind: one kind badge
	per group (`init` → `set` → `patch` → `unset` → `redacted`), then the
	mutated paths and values under it (scalar / JSON block / patch / removed
	note). A `redacted` entry shows a small hidden chip instead of a value;
	the hover title carries the reason. Values longer than
	`VALUE_PREVIEW_LIMIT` truncate with an ellipsis; the hover title carries
	the full text. `layout` picks the row arrangement: `side` (path |
	value grid, history drawer) or `stacked` (path line, value below, audit
	detail pane).
-->
<script lang="ts">
	import {
		formatValue,
		groupChanges,
		isScalar,
		kindLabel,
		truncateValue,
		VALUE_PREVIEW_LIMIT,
		type ChangeEntry
	} from './auditDiff.js';
	import * as messages from '$lib/paraglide/messages';

	let {
		changes,
		layout = 'side'
	}: {
		changes: ChangeEntry[];
		layout?: 'side' | 'stacked';
	} = $props();

	const groups = $derived(groupChanges(changes));

	/** Value text for a set/init entry, truncated at the preview limit. */
	function previewOf(c: ChangeEntry): string {
		if (c.value == null) return 'null';
		return truncateValue(isScalar(c.value) ? String(c.value) : formatValue(c.value));
	}

	/** Full value text for the hover title — only when truncation happened. */
	function fullOf(c: ChangeEntry): string | undefined {
		if (c.value == null) return undefined;
		const full = isScalar(c.value) ? String(c.value) : formatValue(c.value);
		return full.length > VALUE_PREVIEW_LIMIT ? full : undefined;
	}
</script>

<div class="changes" class:stacked={layout === 'stacked'}>
	{#each groups as g (g.kind)}
		<div class="change-group">
			<span class={`change-kind change-kind-${g.kind}`}>{kindLabel(g.kind)}</span>
			{#each g.entries as c (c.path + c.kind)}
				<div class="change">
					<span class="change-path">
						<code>{c.path}</code>
					</span>
					<span class="change-value">
						{#if c.kind === 'unset'}
							<span class="value-muted">{messages.audit_change_removed()}</span>
						{:else if c.kind === 'patch'}
							<span class="value-patch">{messages.audit_change_patch_applied()}</span>
						{:else if c.kind === 'redacted'}
							<span class="value-redacted" title={messages.audit_change_redacted_helper()}>
								{messages.audit_change_redacted()}
							</span>
						{:else if c.value == null}
							<span class="value-muted">null</span>
						{:else if isScalar(c.value)}
							<code class="value-scalar" title={fullOf(c)}>{previewOf(c)}</code>
						{:else}
							<pre class="value-block" title={fullOf(c)}><code>{previewOf(c)}</code></pre>
						{/if}
					</span>
				</div>
			{/each}
		</div>
	{/each}
</div>

<style>
	.changes {
		margin: 0;
		padding: 8px 0;
		display: flex;
		flex-direction: column;
	}

	.change-group {
		display: flex;
		flex-direction: column;
		padding: 10px 16px;
		border-bottom: 1px solid var(--border);
	}

	.change-group:last-child {
		border-bottom: none;
	}

	/* One badge per group, above the group's rows. */
	.change-kind {
		align-self: flex-start;
		font-family: var(--font-mono);
		font-size: 10px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		padding: 1px 6px;
		border-radius: var(--r-sm);
		color: var(--text-2);
		background: var(--sunken);
		margin-bottom: 4px;
	}

	.change-kind-set {
		color: var(--info);
		background: var(--info-weak);
	}

	.change-kind-patch {
		color: var(--text-2);
		background: var(--sunken);
	}

	.change-kind-unset {
		color: var(--danger);
		background: var(--danger-weak);
	}

	.change-kind-init {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.change {
		display: grid;
		grid-template-columns: minmax(120px, 0.8fr) minmax(0, 1.2fr);
		gap: 12px;
		padding: 8px 0;
		border-bottom: 1px solid var(--surface-2);
		align-items: start;
	}

	/* The group's bottom border owns the space after the last row. */
	.change:last-child {
		border-bottom: none;
		padding-bottom: 0;
	}

	.change-path {
		min-width: 0;
	}

	/* The path is the label of the pair — muted and medium-weight, per the
	   DvtField label/value hierarchy; the value carries the full ink. */
	.change-path code {
		font-family: var(--font-mono);
		font-size: 11.5px;
		font-weight: 500;
		color: var(--text-2);
		overflow-wrap: anywhere;
	}

	.change-value {
		margin: 0;
		min-width: 0;
	}

	/* Note slots — no rendered value: removals, patch placeholders, null. */
	.value-muted,
	.value-patch {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		font-style: italic;
	}

	/* Redacted value — the server hid it (field-tag visibility): a small
	   chip stands in for the value; the hover title carries the reason. */
	.value-redacted {
		display: inline-flex;
		align-items: center;
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 500;
		color: var(--text-3);
		background: var(--sunken);
		border: 1px dashed var(--border);
		border-radius: 999px;
		padding: 1px 8px;
		white-space: nowrap;
	}

	.value-scalar {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text);
		overflow-wrap: anywhere;
	}

	.value-block {
		margin: 0;
		padding: 8px 10px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		font-family: var(--font-mono);
		font-size: 11px;
		line-height: 1.5;
		color: var(--text);
		overflow-x: auto;
		white-space: pre;
	}

	.value-block code {
		font-family: inherit;
	}

	/* ── Stacked layout (audit detail pane) ───────────────────────────── */
	.stacked {
		margin: 16px 0 0;
		padding: 0;
		gap: 10px;
	}

	.stacked .change-group {
		padding: 0 0 12px;
		border-bottom: 1px solid var(--border);
	}

	.stacked .change-group:last-child {
		padding-bottom: 0;
	}

	.stacked .change-kind {
		font-size: 10.5px;
		border-radius: 999px;
		margin-bottom: 2px;
	}

	.stacked .change-kind-patch {
		color: var(--accent-ink);
		background: var(--accent-weak);
	}

	/* Spacing carries the hierarchy: a value hugs its key (4px), the next
	   key starts clearly lower (8px) — pairs read as units. */
	.stacked .change {
		display: block;
		padding: 8px 0 0;
	}

	.stacked .change-path code {
		font-size: 12px;
		font-weight: 500;
		color: var(--text-2);
	}

	.stacked .change-value {
		display: block;
		margin: 4px 0 0;
		word-break: break-all;
	}

	.stacked .value-muted,
	.stacked .value-patch {
		font-family: inherit;
		font-style: normal;
		font-size: 12px;
	}

	.stacked .value-redacted {
		font-family: inherit;
		font-size: 11px;
	}

	.stacked .value-scalar {
		font-size: 12px;
		background: var(--sunken);
		padding: 2px 5px;
		border-radius: 4px;
	}

	.stacked .value-block {
		padding: 8px;
		border: none;
		border-radius: 4px;
		max-height: 220px;
		overflow: auto;
	}

	.stacked .value-block code {
		font-size: 11.5px;
		white-space: pre-wrap;
	}
</style>
