<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import Markdown from '../markdown/Markdown.svelte';
	import ThoughtBlock from './ThoughtBlock.svelte';
	import ToolCallBar from './ToolCallBar.svelte';
	import RowsCard from './RowsCard.svelte';
	import StatsTile from './StatsTile.svelte';
	import CopyButton from './CopyButton.svelte';
	import type { AgentPart } from './tool-call-helpers.js';

	/**
	 * One assistant turn: the agent header (rendered once) followed by an
	 * ordered list of parts — text bubbles, tool-call bars, and the
	 * registry-tool surfaces (`rows`, `stats`) — rendered in the order they
	 * were emitted on the stream. Built on top of {@link Markdown} and
	 * {@link ToolCallBar}; driven by the `chunk` events produced by an
	 * `AssistantDriver.streamAsk` iteration — see {@link applyChunkToParts}.
	 *
	 * The app assistant mounts no UI tools, so `preview` and `documents`
	 * parts never arrive from the backend; if history ever carries one (a
	 * host pointing the panel at another kind's conversation), it renders as
	 * a muted unsupported note instead of a broken surface.
	 *
	 * The {@link ToolCallEntry} shape is re-declared here so components that
	 * construct parts by hand (e.g. tests) can import it from the panel.
	 */
	export interface ToolCallEntry {
		name: string;
		detail?: string;
		result?: string;
		status: 'running' | 'ok' | 'error';
	}

	let {
		name = 'Assistant',
		tag = '',
		parts = [],
		streaming = false,
		/** True while the whole turn is still being streamed, including
		 * between parts (e.g. before a tool call resolves, or while text after
		 * the reasoning is arriving). Used to keep the reasoning block open
		 * for the full duration of an in-flight turn. */
		streamActive = false
	}: {
		name?: string;
		tag?: string;
		parts?: AgentPart[];
		streaming?: boolean;
		streamActive?: boolean;
	} = $props();

	/** The streaming caret shows only on the trailing text part of an in-flight turn. */
	function isActive(part: AgentPart, i: number): boolean {
		return streaming && i === parts.length - 1 && part.type === 'text';
	}

	/** A reasoning block is still streaming only while it is the trailing part
	 * of an in-flight turn. The moment the next part (a tool call or text)
	 * is appended, or the turn ends, it is no longer trailing and folds away
	 * immediately — rather than staying open for the whole turn. */
	function isStreaming(part: AgentPart, i: number): boolean {
		return part.type === 'reasoning' && streamActive && i === parts.length - 1;
	}

	/** True when the turn has just been created and no parts have arrived yet. */
	const thinking = $derived(parts.length === 0 && streaming);

	/** The turn's answer — the joined text parts only. Copying it never
	 * carries the reasoning blocks, the tool trace, or the surfaces; those
	 * stay outside the clipboard on purpose. */
	const answer = $derived(
		parts
			.filter((p) => p.type === 'text')
			.map((p) => p.content)
			.join('\n\n')
	);
	/** The copy row appears once the turn is complete and has an answer; it
	 * sits at the end of the turn, right-aligned. */
	const canCopy = $derived(!streaming && answer.trim().length > 0);
</script>

<div class="turn">
	{#if name}
		<div class="who">
			<span class="who-name">{name}</span>
			{#if tag}<span class="who-tag">{tag}</span>{/if}
		</div>
	{/if}
	{#if thinking}
		<div class="body thinking">
			<span class="thinking-dot"></span>
			<span class="thinking-label">{m.assistant_thinking()}</span>
		</div>
	{/if}
	{#each parts as part, i (i)}
		{#if part.type === 'tool_call'}
			<ToolCallBar
				name={part.toolCall.name}
				detail={part.toolCall.detail}
				result={part.toolCall.result}
				status={part.toolCall.status}
			/>
		{:else if part.type === 'rows'}
			<RowsCard rows={part.rows} />
		{:else if part.type === 'stats'}
			<StatsTile stats={part.stats} />
		{:else if part.type === 'reasoning'}
			<ThoughtBlock content={part.content} active={isStreaming(part, i)} />
		{:else if part.type === 'text'}
			<div class="body"><Markdown content={part.content} streaming={isActive(part, i)} /></div>
		{:else}
			<!-- UI-tool parts (`preview` / `documents`) — the app assistant mounts
			     no UI tools, so these never arrive from the backend. -->
			<div class="unsupported" role="note">{m.assistant_part_unsupported()}</div>
		{/if}
	{/each}
	{#if canCopy}
		<div class="turn-foot">
			<CopyButton value={answer} size="sm" iconOnly title={m.assistant_copy_answer()} />
		</div>
	{/if}
</div>

<style>
	.turn {
		display: flex;
		flex-direction: column;
		gap: 0;
	}

	/* Mirrors the agent header in ChatBubble.svelte — rendered once per turn so
	 * interleaved text/tool bars don't each repeat the name. */
	.who {
		font-size: 11.5px;
		font-weight: 700;
		letter-spacing: 0.02em;
		color: var(--facet-accent-ink);
		margin-bottom: 5px;
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.who-name {
		font-family: var(--facet-font-display);
	}
	.who-tag {
		font-family: var(--facet-font-mono);
		font-size: 9.5px;
		font-weight: 600;
		color: var(--facet-text-3);
		background: var(--facet-sunken);
		border-radius: var(--facet-r-pill);
		padding: 1px 7px;
	}

	.body {
		color: var(--facet-text);
	}

	/* ── Copy answer — quiet icon on its own row at the end of the turn,
	   right-aligned. Persistent (no hover reveal) so the affordance is
	   discoverable; it appears once the turn is complete. ──────────────── */
	.turn-foot {
		display: flex;
		justify-content: flex-end;
		margin-top: 2px;
	}

	/* ── UI-tool part placeholder — muted, honest note ──────────────────── */
	.unsupported {
		font-family: var(--facet-font-mono);
		font-size: 11px;
		color: var(--facet-text-3);
		padding: 6px 2px;
		margin-bottom: 9px;
	}

	/* ── Thinking indicator — shown while waiting for the first chunk ─── */
	.thinking {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 4px 0;
	}

	.thinking-dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--facet-accent);
		animation: thinking-pulse 1s steps(2, start) infinite;
	}

	.thinking-label {
		font-family: var(--facet-font-mono);
		font-size: 12px;
		color: var(--facet-text-3);
		font-weight: 500;
		letter-spacing: 0.02em;
	}

	@keyframes thinking-pulse {
		50% {
			opacity: 0.2;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.thinking-dot {
			animation: none;
			opacity: 0.5;
		}
	}
</style>
