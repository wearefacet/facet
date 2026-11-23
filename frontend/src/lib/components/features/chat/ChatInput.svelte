<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Send, Square } from '@lucide/svelte';

	let {
		value = $bindable(''),
		placeholder = m.assistant_input_placeholder(),
		disabled = false,
		busy = false,
		onsend,
		onstop,
		children,
		...rest
	}: {
		/** Current input value (two-way bindable). */
		value?: string;
		/** Placeholder text. */
		placeholder?: string;
		/** Disables input and send. */
		disabled?: boolean;
		/**
		 * When true, the composer shows a "thinking…" placeholder and refuses
		 * input. Distinct from `disabled`: carries the streaming in-flight
		 * semantics (the agent is producing a turn) rather than a generic
		 * lockout. Either flag alone is enough to block sending.
		 */
		busy?: boolean;
		/** Called with the message text on Enter or send-button click. */
		onsend?: (text: string) => void;
		/** Called when the user clicks the button while `busy` (aborts the in-flight turn). */
		onstop?: () => void;
		/** Optional row content rendered below the textarea (context chips, model chip, attach button, etc.). */
		children?: import('svelte').Snippet;
		/** Rest props spread onto the textarea (e.g. `aria-label`). */
		rest?: Record<string, unknown>;
	} = $props();

	let textarea: HTMLTextAreaElement | null = $state(null);

	// Auto-grow the textarea height to fit content, clamped between a min and
	// a max. Beyond the max, the textarea scrolls internally. The user can
	// still drag the vertical resize handle to make it taller.
	const MIN_HEIGHT = 22;
	const MAX_AUTO_HEIGHT = 200;

	function autosize() {
		if (!textarea) return;
		textarea.style.height = 'auto';
		const next = Math.min(textarea.scrollHeight, MAX_AUTO_HEIGHT);
		textarea.style.height = `${Math.max(next, MIN_HEIGHT)}px`;
	}

	$effect(() => {
		// Re-run autosize whenever the bound value changes (incl. programmatic
		// updates from outside, e.g. clearing after send).
		void value;
		autosize();
	});

	function onkeydown(e: KeyboardEvent) {
		// Enter sends. Shift+Enter keeps the native textarea newline (the
		// textarea grows to fit; Alt+Enter stays native too). Ctrl/Cmd+Enter
		// also sends — the earlier chord, kept for muscle memory. Enter that
		// confirms an IME composition never sends.
		if (e.key !== 'Enter' || e.isComposing) return;
		if (e.shiftKey || e.altKey) return;
		e.preventDefault();
		send();
	}

	function send() {
		const text = value.trim();
		if (!text || locked) return;
		onsend?.(text);
		value = '';
		// Reset height after sending.
		queueMicrotask(autosize);
	}

	function onButtonClick() {
		if (busy) {
			onstop?.();
			return;
		}
		send();
	}

	const locked = $derived(disabled || busy);
	const canSend = $derived(value.trim().length > 0 && !locked);
</script>

<div class="composer" class:disabled class:busy>
	<div class="inputwrap">
		<textarea
			bind:this={textarea}
			class="ta"
			rows="1"
			placeholder={busy ? m.assistant_input_thinking() : placeholder}
			disabled={locked}
			bind:value
			{onkeydown}
			{...rest}></textarea>
		{#if children}
			<div class="crow">
				{@render children()}
			</div>
		{/if}
	</div>
	<button
		class="send"
		class:stop={busy}
		type="button"
		title={busy ? m.assistant_stop_title() : m.assistant_send_title()}
		aria-label={busy ? m.assistant_stop_aria() : m.assistant_send_aria()}
		disabled={!busy && !canSend}
		onclick={onButtonClick}
	>
		{#if busy}
			<Square size={13} fill="currentColor" />
		{:else}
			<Send size={17} />
		{/if}
	</button>
</div>

<style>
	/* ── Composer — matches .composer / .inputwrap / .send from mockup ─── */
	.composer {
		display: flex;
		align-items: flex-end;
		gap: 9px;
	}

	.inputwrap {
		flex: 1;
		border: 1px solid var(--border-strong);
		border-radius: var(--r-lg);
		background: var(--surface);
		padding: 10px 12px;
		box-shadow: var(--sh-1);
		display: flex;
		flex-direction: column;
		gap: 9px;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}
	.inputwrap:focus-within {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.ta {
		border: none;
		outline: none;
		resize: vertical;
		font: inherit;
		font-size: 13.5px;
		line-height: 1.5;
		color: var(--text);
		background: transparent;
		width: 100%;
		min-height: 22px;
		max-height: 320px;
		padding: 0;
		margin: 0;
		overflow-y: auto;
	}
	.ta::placeholder {
		color: var(--text-3);
	}
	.ta:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.crow {
		display: flex;
		align-items: center;
		gap: 7px;
	}

	.send {
		width: 34px;
		height: 34px;
		border-radius: 9px;
		background: var(--accent);
		color: var(--on-accent);
		border: none;
		cursor: pointer;
		display: grid;
		place-items: center;
		flex-shrink: 0;
		transition:
			background 0.12s,
			opacity 0.12s;
	}
	.send:hover:not(:disabled) {
		background: var(--accent-press);
	}
	.send:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}
	.send.stop {
		background: var(--danger, #c0392b);
	}
	.send.stop:hover:not(:disabled) {
		background: var(--danger-strong, #a93226);
	}
	.send:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.composer.disabled {
		opacity: 0.7;
	}

	.composer.busy .inputwrap {
		border-color: var(--accent-weak);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}
</style>
