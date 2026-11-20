<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Markdown from './Markdown.svelte';
	import ThoughtBlock from './ThoughtBlock.svelte';
	import ToolCallBar from './ToolCallBar.svelte';
	import ViewPreviewCard from './ViewPreviewCard.svelte';
	import DocumentCard from './DocumentCard.svelte';
	import StatsCard from './StatsCard.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { AgentPart } from '$lib/assistant/index.js';

	/** Shared app-origin default for mounts that pass no data driver. */
	const DEFAULT_DOCUMENT_DRIVER = new DocumentDataDriver('');

	/**
	 * One assistant turn: the agent header (rendered once) followed by an
	 * ordered list of parts — text bubbles, tool-call bars, and the workspace
	 * surfaces (document rows, document cards, stats) — rendered in the order
	 * they were emitted on the stream. Built on top of {@link Markdown} and
	 * {@link ToolCallBar}; driven by the `chunk` events produced by an
	 * `AssistantDriver.streamAsk` iteration — see `$lib/assistant` helpers
	 * like `applyChunkToParts`.
	 *
	 * The {@link ToolCallEntry} shape is re-declared here so components that
	 * construct parts by hand (e.g. stories) can import it from the panel.
	 */
	export interface ToolCallEntry {
		name: string;
		detail?: string;
		result?: string;
		status: 'running' | 'ok' | 'error';
	}

	let {
		name = 'Steve',
		tag = m.assistant_tag_schema(),
		parts = [],
		streaming = false,
		/** True while the whole turn is still being streamed, including
		 * between parts (e.g. before a tool call resolves, or while text after
		 * the reasoning is arriving). Used to keep the reasoning block open
		 * for the full duration of an in-flight turn. */
		streamActive = false,
		/** Data driver for the workspace surfaces (document rows, cards).
		 * Defaults to the HTTP driver against the app origin; stories inject
		 * `MockDataDriver`. */
		documentDriver = DEFAULT_DOCUMENT_DRIVER
	}: {
		name?: string;
		tag?: string;
		parts?: AgentPart[];
		streaming?: boolean;
		streamActive?: boolean;
		documentDriver?: DataDriver;
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
	 * carries the reasoning blocks, the tool trace, or the workspace
	 * surfaces; those stay outside the clipboard on purpose. */
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
		{:else if part.type === 'preview'}
			<ViewPreviewCard preview={part.preview} />
		{:else if part.type === 'rows'}
			<div class="doc-rows">
				{#each part.rows.rows as row (row.id)}
					<DocumentCard ref={row} display="inline" driver={documentDriver} />
				{/each}
			</div>
		{:else if part.type === 'documents'}
			{#if part.documents.status === 'running'}
				<div class="doc-rows">
					{#each [0, 1, 2] as placeholder (placeholder)}
						<div class="doc-skeleton" aria-hidden="true"></div>
					{/each}
				</div>
			{:else if !part.documents.spec || part.documents.status === 'error'}
				<div class="doc-error" role="alert">{m.assistant_documents_error()}</div>
			{:else if part.documents.spec.display === 'card'}
				<div class="doc-grid">
					{#each part.documents.spec.ids as id (id)}
						<DocumentCard
							ref={{
								domain: part.documents.spec.domain,
								doctype: part.documents.spec.doctype,
								id
							}}
							display="card"
							driver={documentDriver}
						/>
					{/each}
				</div>
			{:else}
				<div class="doc-rows">
					{#each part.documents.spec.ids as id (id)}
						<DocumentCard
							ref={{
								domain: part.documents.spec.domain,
								doctype: part.documents.spec.doctype,
								id
							}}
							display="inline"
							driver={documentDriver}
						/>
					{/each}
				</div>
			{/if}
		{:else if part.type === 'stats'}
			<StatsCard stats={part.stats} />
		{:else if part.type === 'reasoning'}
			<ThoughtBlock content={part.content} active={isStreaming(part, i)} />
		{:else}
			<div class="body"><Markdown content={part.content} streaming={isActive(part, i)} /></div>
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
		color: var(--accent-ink);
		margin-bottom: 5px;
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.who-name {
		font-family: var(--font-display);
	}
	.who-tag {
		font-family: var(--font-mono);
		font-size: 9.5px;
		font-weight: 600;
		color: var(--text-3);
		background: var(--sunken);
		border-radius: var(--r-pill);
		padding: 1px 7px;
	}

	.body {
		color: var(--text);
	}

	/* ── Copy answer — quiet icon on its own row at the end of the turn,
	   right-aligned. Persistent (no hover reveal) so the affordance is
	   discoverable; it appears once the turn is complete. ──────────────── */
	.turn-foot {
		display: flex;
		justify-content: flex-end;
		margin-top: 2px;
	}

	/* ── Workspace surfaces — document rows / cards / skeletons ─────── */
	.doc-rows {
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
		margin-bottom: 9px;
		background: var(--surface);
	}

	.doc-rows > :global(.row:last-of-type) {
		border-bottom: none;
	}

	.doc-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(210px, 1fr));
		gap: 8px;
		margin-bottom: 9px;
		min-width: 0;
	}

	.doc-grid > :global(.card) {
		height: 100%;
	}

	.doc-skeleton {
		height: 30px;
		background: linear-gradient(
			90deg,
			var(--sunken) 25%,
			var(--surface-2, var(--sunken)) 50%,
			var(--sunken) 75%
		);
		background-size: 200% 100%;
		animation: skeleton-slide 1.4s ease infinite;
	}
	.doc-skeleton + .doc-skeleton {
		border-top: 1px solid var(--border);
	}

	.doc-error {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--danger);
		padding: 6px 2px;
		margin-bottom: 9px;
	}

	@keyframes skeleton-slide {
		from {
			background-position: 200% 0;
		}
		to {
			background-position: -200% 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.doc-skeleton {
			animation: none;
		}
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
		background: var(--accent);
		animation: thinking-pulse 1s steps(2, start) infinite;
	}

	.thinking-label {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
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
