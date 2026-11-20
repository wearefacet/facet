<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveInterpolated, getDocContent } from '$lib/template-resolve';
	import type { ImageNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';

	let {
		template,
		document,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The image template node. */
		template: ImageNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const src = $derived(resolveInterpolated(template.src, content));
	const isAvatar = $derived(template.variant === 'avatar');
</script>

<!-- An empty resolved src means the interpolated field is unset — an
		<img src=""> renders as a broken-image glyph. Render nothing. -->
{#if src}
	{#if isAvatar}
		<div class="dvt-image-avatar-wrap">
			<img class="dvt-image-avatar" {src} alt={template.alt ?? ''} {...rest} />
		</div>
	{:else}
		<img class="dvt-image" {src} alt={template.alt ?? ''} {...rest} />
	{/if}
{/if}

<style>
	.dvt-image {
		display: block;
		max-width: 100%;
		height: auto;
		border-radius: var(--r);
	}

	.dvt-image-avatar-wrap {
		display: flex;
		justify-content: center;
		padding: 4px 0;
	}

	.dvt-image-avatar {
		display: block;
		width: 72px;
		height: 72px;
		object-fit: cover;
		border-radius: 50%;
		border: 1px solid var(--border-strong);
		background: var(--sunken);
	}

	@container (max-width: 359px) {
		.dvt-image-avatar {
			width: 56px;
			height: 56px;
		}
	}
</style>
