<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { LinkNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The link template node. */
		template: LinkNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const href = $derived(resolveInterpolated(template.href, content));
	const label = $derived(resolveInterpolated(template.label, content));
</script>

<!-- An empty resolved href means the interpolated field is unset. An
		<a href=""> would render as a dead self-link that still looks
		clickable — render nothing instead. -->
{#if href}
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- the href is user-authored template data (interpolated): it may target an app route or an external URL, so it cannot be a route id at this leaf. -->
	<a class="dvt-link" {href} {...rest}>{label}</a>
{/if}

<style>
	.dvt-link {
		color: var(--accent-ink);
		text-decoration: none;
		font-size: 13px;
	}

	.dvt-link:hover {
		text-decoration: underline;
	}
</style>
