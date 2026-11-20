<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { getDocContent, resolveRaw } from '$lib/template-resolve';
	import type { MarkdownNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import Markdown from '$lib/components/primitives/content/Markdown.svelte';

	/**
	 * DvtMarkdown — renders a `longtext` field as readonly markdown prose
	 * through the shared `Content/Markdown` primitive (the same Milkdown
	 * engine as every other markdown surface). The show-page counterpart of
	 * the `input-longtext` form node: longtext is markdown, so a record view
	 * renders the stored source as a document, never as a plain-text field
	 * row. Renders nothing when the field is empty.
	 */
	let {
		template,
		document,
		onreferenceclick
	}: {
		/** The markdown template node. */
		template: MarkdownNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Reference-chip click handler forwarded by parent — a readonly
		 *  chip click opens the QuickView when the host wires one. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const value = $derived.by(() => {
		const raw = resolveRaw(template.field, content);
		return typeof raw === 'string' ? raw : raw == null ? '' : String(raw);
	});
</script>

{#if value.trim().length > 0}
	<div class="dvt-markdown">
		<Markdown {value} readonly bare onReferenceClick={onreferenceclick} />
	</div>
{/if}

<style>
	/* The prose typography is owned by the Milkdown theme rules (the single
	 * prose definition) — the node only guards against min-width blowout
	 * inside grid columns. */
	.dvt-markdown {
		min-width: 0;
	}
</style>
