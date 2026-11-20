<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * Thin banner shown while a Builder preview session is active.
	 *
	 * The user is browsing the live application under a `typ: "preview"`
	 * capability token bound to a draft domain. Regular RBAC is replaced by
	 * the `Principal::Preview` capability path, so they can create / edit /
	 * delete documents of the draft exactly as they would against a live
	 * domain — but the data is throwaway and the schema itself is not editable
	 * from inside preview (those edits go back to the Builder editor).
	 *
	 * Exit returns the user to the Builder's editor tab for the draft.
	 */
	import * as m from '$lib/paraglide/messages';
	import { PencilRuler, X } from '@lucide/svelte';

	let {
		draftId,
		onexit = () => {}
	}: {
		draftId: string;
		onexit?: () => void;
	} = $props();
</script>

<div class="preview-bar" role="status" aria-live="polite">
	<div class="content">
		<span class="chip">
			<PencilRuler class="banner-ic" size={13} stroke-width={1.9} />
			<span class="msg">{m.builder_preview_banner({ id: draftId })}</span>
			<span class="hint">{m.builder_preview_hint()}</span>
		</span>
		<button class="exit" type="button" onclick={onexit}>
			<X size={13} stroke-width={1.9} />
			{m.builder_preview_exit()}
		</button>
	</div>
</div>

<style>
	/*
	 * Same chrome family as the builder top bar: surface background,
	 * hairline bottom border, 2px gold top edge as the mode marker. All
	 * colours read from tokens, so both themes pass AA without overrides.
	 */
	.preview-bar {
		position: relative;
		display: flex;
		align-items: center;
		min-height: 32px;
		padding: 0 12px;
		background: var(--surface);
		border-bottom: 1px solid var(--border);
	}

	.preview-bar::before {
		content: '';
		position: absolute;
		top: 0;
		left: 0;
		right: 0;
		height: 2px;
		background: var(--accent);
	}

	.content {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		min-width: 0;
	}

	.chip {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font-family: var(--font-sans);
		font-size: 12.5px;
		color: var(--text-2);
		min-width: 0;
	}

	.chip :global(.banner-ic) {
		color: var(--text-3);
		flex: none;
	}

	.msg {
		white-space: nowrap;
		color: var(--text);
		font-weight: 600;
	}

	.hint {
		font-weight: 400;
		color: var(--text-3);
		font-size: 11.5px;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.exit {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		background: var(--surface);
		color: var(--text-2);
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		white-space: nowrap;
		margin-left: auto;
	}

	.exit:hover {
		border-color: var(--border-strong);
		color: var(--text);
	}

	.exit:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
