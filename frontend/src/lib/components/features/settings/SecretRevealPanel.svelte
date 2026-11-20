<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	SecretRevealPanel — the one-time secret reveal surface.

	Every flow that mints a secret (app API key, account API key,
	self-service API key) shows the raw value exactly once, next to a copy
	button and a "store it now" warning. This component is that surface; the
	host supplies the secret and any trailing action buttons (goto, Done).
	The raw value lives only in the host's local state — the panel never
	persists it.
-->
<script lang="ts">
	import { KeyRound } from '@lucide/svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		secret,
		title = null,
		hint = m.common_secret_hint(),
		children
	}: {
		/** The raw secret. Rendered in a mono block and handed to the copy button. */
		secret: string;
		/** Heading inside the panel; omit when the host already shows one. */
		title?: string | null;
		/** Warning line under the heading; omit to render the value alone. */
		hint?: string | null;
		/** Extra action buttons rendered after the copy control. */
		children?: import('svelte').Snippet;
	} = $props();
</script>

<div class="reveal-panel">
	<KeyRound size={17} strokeWidth={2} class="reveal-icon" aria-hidden="true" />
	<div class="reveal-body">
		{#if title}<div class="reveal-title">{title}</div>{/if}
		{#if hint}<div class="reveal-hint">{hint}</div>{/if}
		<code class="reveal-value">{secret}</code>
		<div class="reveal-actions">
			<CopyButton value={secret} title={m.common_copy_clipboard_aria()} />
			{@render children?.()}
		</div>
	</div>
</div>

<style>
	.reveal-panel {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		background: var(--accent-weak);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		padding: 12px 14px;
	}

	:global(.reveal-icon) {
		color: var(--text-2);
		flex: none;
		margin-top: 2px;
	}

	.reveal-body {
		min-width: 0;
		flex: 1;
	}

	.reveal-title {
		font-weight: 500;
		font-size: 13.5px;
		color: var(--text);
	}

	.reveal-hint {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 3px;
		line-height: 1.55;
	}

	.reveal-value {
		display: block;
		margin-top: 9px;
		padding: 10px 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		word-break: break-all;
		user-select: all;
	}

	.reveal-actions {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-top: 10px;
		flex-wrap: wrap;
	}
</style>
