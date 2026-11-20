<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { HrNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template: _template,
		document: _document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The hr template node. */
		template: HrNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();
</script>

<hr class="dvt-hr" {...rest} />

<style>
	.dvt-hr {
		border: none;
		border-top: 1px solid var(--border);
		margin: 16px 0;
	}
</style>
