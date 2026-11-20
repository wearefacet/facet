<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import Wrench from '@lucide/svelte/icons/wrench';
	import Search from '@lucide/svelte/icons/search';
	import Check from '@lucide/svelte/icons/check';
	import Loader from '@lucide/svelte/icons/loader';
	import AlertCircle from '@lucide/svelte/icons/alert-circle';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';

	type Status = 'running' | 'ok' | 'error';

	let {
		name,
		detail,
		result,
		status = 'ok'
	}: {
		/** Tool name, e.g. "inspect_domain". */
		name: string;
		/** Human-readable summary of what the tool did, e.g. "inspected domain crm — found Customer, Contact, Deal". */
		detail?: string;
		/**
		 * Full tool output (often JSON or long technical text). Rendered in a
		 * collapsible body below the header — never inline on the right — so
		 * long payloads scroll instead of overflowing the chat column.
		 */
		result?: string;
		/** Status of the tool call. */
		status?: Status;
	} = $props();

	const StatusIcon = $derived(
		status === 'running' ? Loader : status === 'error' ? AlertCircle : Check
	);
	const ToolIcon = $derived(
		name.startsWith('search') || name.startsWith('inspect') ? Search : Wrench
	);

	// A short inline label carried next to the status icon. Long results live
	// in the body, not here, so the header row never overflows.
	const statusLabel = $derived.by(() => {
		if (status === 'running') return m.assistant_tool_running();
		if (status === 'error') return m.assistant_tool_error();
		return m.assistant_tool_ok();
	});

	const hasResult = $derived(typeof result === 'string' && result.length > 0);
</script>

<details class="trace" data-status={status}>
	<summary class="trace-head">
		<span class="trace-icon" aria-hidden="true">
			<ToolIcon size={13} />
		</span>
		<span class="trace-name">{name}</span>
		{#if detail}
			<span class="trace-sep">—</span>
			<span class="trace-detail">{detail}</span>
		{/if}
		<span class="trace-spacer"></span>
		<span class="trace-status" data-status={status}>
			<span class="trace-status-icon" class:spin={status === 'running'} aria-hidden="true">
				<StatusIcon size={12} />
			</span>
			<span class="trace-status-label">{statusLabel}</span>
		</span>
		{#if hasResult}
			<span class="trace-chevron" aria-hidden="true">
				<ChevronRight size={13} stroke-width={1.9} />
			</span>
		{/if}
	</summary>
	{#if hasResult}
		<div class="trace-body">
			<pre class="trace-result"><code>{result}</code></pre>
		</div>
	{/if}
</details>

<style>
	/* ── ToolCallBar — matches .trace from agent-chat mockup ────────────── */
	.trace {
		display: block;
		font-family: var(--facet-font-mono);
		font-size: 11.5px;
		color: var(--facet-text-3);
		background: var(--facet-surface-2);
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
		margin-bottom: 9px;
		overflow: hidden;
	}

	.trace-head {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 6px 11px;
		list-style: none;
		cursor: pointer;
		user-select: none;
		transition: background 0.12s ease;
	}
	/* Suppress the default disclosure marker — we render our own chevron. */
	.trace-head::-webkit-details-marker {
		display: none;
	}
	.trace-head:hover {
		background: var(--facet-sunken);
	}

	.trace-icon {
		display: inline-flex;
		color: var(--facet-text-3);
		flex-shrink: 0;
	}

	.trace-name {
		color: var(--facet-text-2);
		font-weight: 600;
		flex-shrink: 0;
	}

	.trace-sep {
		color: var(--facet-text-3);
		opacity: 0.6;
		flex-shrink: 0;
	}

	.trace-detail {
		color: var(--facet-text-3);
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.trace-spacer {
		flex: 1;
	}

	.trace-status {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font-weight: 600;
		flex-shrink: 0;
	}

	.trace-status[data-status='ok'] {
		color: var(--facet-ok);
	}
	.trace-status[data-status='error'] {
		color: var(--facet-danger);
	}
	.trace-status[data-status='running'] {
		color: var(--facet-text-2);
	}

	.trace-status-icon {
		display: inline-flex;
	}

	.trace-status-icon.spin :global(svg) {
		animation: trace-spin 0.8s linear infinite;
	}

	.trace-chevron {
		flex-shrink: 0;
		color: var(--facet-text-3);
		transition: transform 0.12s ease;
	}
	.trace[open] .trace-chevron {
		transform: rotate(90deg);
	}

	/* ── Body — full tool output in a scrollable monospace block ────────── */
	.trace-body {
		border-top: 1px solid var(--facet-border);
		background: var(--facet-sunken);
	}

	.trace-result {
		margin: 0;
		padding: 10px 12px;
		overflow: auto;
		max-height: 240px;
		white-space: pre-wrap;
		word-break: break-word;
		font-family: var(--facet-font-mono);
		font-size: 11.5px;
		line-height: 1.5;
		color: var(--facet-text-2);
	}
	.trace-result code {
		font-family: inherit;
		white-space: inherit;
	}

	@keyframes trace-spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.trace-status-icon.spin :global(svg) {
			animation: none;
		}
		.trace-chevron {
			transition: none;
		}
	}
</style>
