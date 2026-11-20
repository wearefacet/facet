<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { CapsuleNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The capsule template node. */
		template: CapsuleNode;
		/** The full document response — `data` is used for field resolution. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const display = $derived(resolveInterpolated(template.value, content));

	// Truncate long labels the same way the `Capsule` primitive does: the
	// visible text is cut at 32 chars with an ellipsis, and the full value
	// is exposed via the hover `title` so tooltips and AT can still read it.
	const MAX_LABEL_LENGTH = 32;
	const visibleLabel = $derived(
		display && display.length > MAX_LABEL_LENGTH
			? display.slice(0, MAX_LABEL_LENGTH) + '…'
			: display
	);
	const tooltipTitle = $derived(display && display.length > MAX_LABEL_LENGTH ? display : undefined);
</script>

<!-- An empty resolution (missing field, unbound token, no value) renders
     nothing — an empty pill reads as a visual bug, not as data. -->
{#if visibleLabel}
	<span class="dvt-capsule" {...rest} title={tooltipTitle}>{visibleLabel}</span>
{/if}

<style>
	.dvt-capsule {
		display: inline-flex;
		align-items: center;
		width: fit-content;
		padding: 2px 10px;
		font-size: 11px;
		font-weight: 600;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border-radius: 999px;
		line-height: 1.5;
		white-space: nowrap;
	}
</style>
