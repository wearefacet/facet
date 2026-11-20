<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { LabelNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The label template node. */
		template: LabelNode;
		/** The full document response — `data` is used for field resolution. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const display = $derived(resolveInterpolated(template.value, content));
</script>

<span class="dvt-label" {...rest}>{display}</span>

<style>
	.dvt-label {
		display: inline-block;
		font-size: 13px;
		color: var(--text);
		line-height: 1.5;
	}
</style>
