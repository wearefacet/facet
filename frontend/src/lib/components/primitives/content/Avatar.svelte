<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	type Size = 'sm' | 'md' | 'lg';

	let {
		initials,
		src,
		alt = '',
		size = 'md',
		background,
		...rest
	}: {
		/** Initials displayed as fallback when no `src` is provided. */
		initials?: string;
		/** Image source URL. When provided, renders as an `<img>` inside the avatar. */
		src?: string;
		/** Alt text for the image. */
		alt?: string;
		/** Size. Defaults to `md`. */
		size?: Size;
		/** Background color override for the initials fallback. */
		background?: string;
	} = $props();

	const cls = $derived(['avatar', `avatar-${size}`].join(' '));
</script>

<span
	class={cls}
	style={background ? `background: ${background}` : undefined}
	role="img"
	aria-label={alt || initials}
	{...rest}
>
	{#if src}
		<img class="avatar-img" {src} {alt} />
	{:else if initials}
		<span class="avatar-initials">{initials}</span>
	{/if}
</span>

<style>
	/* ── Avatar — matches design-guideline .av ──────────────────────────── */
	.avatar {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		border-radius: 50%;
		color: #fff;
		font-weight: 600;
		flex: none;
		overflow: hidden;
	}

	.avatar-img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		border-radius: 50%;
	}

	/* Fallback initials */
	.avatar-initials {
		line-height: 1;
		user-select: none;
	}

	/* Sizes */
	.avatar-sm {
		width: 22px;
		height: 22px;
		font-size: 10px;
	}

	.avatar-md {
		width: 26px;
		height: 26px;
		font-size: 11px;
	}

	.avatar-lg {
		width: 34px;
		height: 34px;
		font-size: 13px;
	}
</style>
