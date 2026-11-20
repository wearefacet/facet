<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { History as HistoryIcon } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import type { RecordMetaNode } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		historyHref,
		...rest
	}: {
		/** The record-meta template node. */
		template: RecordMetaNode;
		/** The full document response — `meta` is used for provenance. */
		document: DocumentResponse;
		/**
		 * Optional History-link href. Derived by the route from `meta.domain` /
		 * `meta.doc_type` / `meta.id`. When omitted, the History link is hidden
		 * even if `history` is `true` — the node is a pure renderer and does not
		 * own routing conventions.
		 */
		historyHref?: string;
	} = $props();

	const showHistory = $derived(template.history !== false && !!historyHref);
	const createdDate = $derived(document.meta.created_at);
	const updatedDate = $derived(document.meta.updated_at);
	const version = $derived(document.meta.version);
</script>

<section class="dvt-record-meta" {...rest}>
	<h3 class="dvt-record-meta-label">{m.doc_record_label()}</h3>
	<dl class="dvt-record-meta-grid">
		<dt>{m.common_created()}</dt>
		<dd>
			<RelativeTime date={createdDate} />
		</dd>

		<dt>{m.common_updated()}</dt>
		<dd>
			<RelativeTime date={updatedDate} />
		</dd>

		{#if showHistory}
			<dt>{m.doc_history()}</dt>
			<dd>
				<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- historyHref is forwarded from the host show page, which builds it with resolve(); the prop threads through the template tree. -->
				<a class="dvt-record-meta-history" href={historyHref}>
					<HistoryIcon size={13} strokeWidth={2} aria-hidden="true" />
					v{version}
				</a>
			</dd>
		{/if}
	</dl>
</section>

<style>
	.dvt-record-meta {
		display: block;
		min-width: 0;
	}

	.dvt-record-meta-label {
		margin: 0 0 10px;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.dvt-record-meta-grid {
		display: grid;
		grid-template-columns: max-content 1fr;
		gap: 6px 12px;
		margin: 0;
		font-size: 12px;
		color: var(--text-2);
		line-height: 1.7;
	}

	.dvt-record-meta-grid dt {
		font-weight: 500;
		color: var(--text-3);
	}

	.dvt-record-meta-grid dd {
		margin: 0;
		color: var(--text);
		min-width: 0;
	}

	.dvt-record-meta-history {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		color: var(--accent-ink);
		text-decoration: none;
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 500;
		border-radius: var(--r-sm);
		transition: color 0.12s;
	}

	.dvt-record-meta-history:hover {
		color: var(--accent-press);
		text-decoration: underline;
	}
</style>
