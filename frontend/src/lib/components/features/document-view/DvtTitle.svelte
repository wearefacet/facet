<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { TitleNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The title template node. */
		template: TitleNode;
		/** The full document response — `data` is used for field resolution. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const display = $derived(resolveInterpolated(template.value, content));
	const level = $derived(template.level ?? 2);
</script>

{#if level === 1}
	<h1 class="dvt-title" {...rest}>{display}</h1>
{:else if level === 2}
	<h2 class="dvt-title" {...rest}>{display}</h2>
{:else if level === 3}
	<h3 class="dvt-title" {...rest}>{display}</h3>
{:else if level === 4}
	<h4 class="dvt-title" {...rest}>{display}</h4>
{:else if level === 5}
	<h5 class="dvt-title" {...rest}>{display}</h5>
{:else if level === 6}
	<h6 class="dvt-title" {...rest}>{display}</h6>
{/if}

<style>
	.dvt-title {
		margin: 0;
		font-weight: 600;
		color: var(--text);
		line-height: 1.3;
	}

	:global(h1.dvt-title) {
		font-family: var(--font-display);
		font-size: 24px;
		line-height: 1.2;
	}

	:global(h2.dvt-title) {
		font-size: 20px;
	}

	:global(h3.dvt-title) {
		font-size: 16px;
	}

	:global(h4.dvt-title) {
		font-size: 14px;
	}

	:global(h5.dvt-title) {
		font-size: 13px;
	}

	:global(h6.dvt-title) {
		font-size: 12px;
	}
</style>
