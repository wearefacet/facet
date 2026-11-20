<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Switch } from 'bits-ui';

	let {
		label,
		checked = $bindable(false),
		disabled = false,
		readonly = false,
		error,
		onchange,
		...rest
	}: {
		label?: string;
		checked?: boolean;
		disabled?: boolean;
		readonly?: boolean;
		error?: string;
		/** Called with the new checked value when the toggle flips. */
		onchange?: (checked: boolean) => void;
		/** Accessible name for the switch when no visible label is rendered. */
		'aria-label'?: string;
	} = $props();

	const inputId = $derived(label ? `toggle-${label}` : undefined);
	const hasError = $derived(Boolean(error));
</script>

<div
	class="toggle-wrap"
	class:toggle-disabled={disabled || readonly}
	class:toggle-has-error={hasError}
>
	<Switch.Root
		id={inputId}
		bind:checked
		disabled={disabled || readonly}
		aria-invalid={hasError || undefined}
		{...rest}
		onCheckedChange={(c) => {
			checked = c;
			onchange?.(c);
		}}
	>
		{#snippet children({ checked: isChecked })}
			<span class="toggle-track" class:toggle-checked={isChecked} aria-hidden="true">
				<span class="toggle-thumb" class:toggle-checked={isChecked}></span>
			</span>
		{/snippet}
	</Switch.Root>
	{#if label}
		<label class="toggle-label" for={inputId}>{label}</label>
	{/if}
	{#if error}
		<span class="toggle-err" role="alert">{error}</span>
	{/if}
</div>

<style>
	/* ── Toggle (switch) — wraps Bits UI Switch.Root ──────────────────────── */
	.toggle-wrap {
		display: inline-flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 8px;
		user-select: none;
	}

	.toggle-disabled {
		opacity: 0.45;
		cursor: not-allowed;
	}

	/* Switch.Root renders as a <button> — reset button styles */
	.toggle-wrap :global([data-switch-root]) {
		display: inline-flex;
		align-items: center;
		border: none;
		background: none;
		padding: 0;
		font: inherit;
		color: inherit;
		cursor: pointer;
	}

	.toggle-disabled :global([data-switch-root]) {
		cursor: not-allowed;
	}

	:global(.toggle-track) {
		position: relative;
		width: 38px;
		height: 22px;
		border-radius: var(--r-pill);
		background: var(--border-strong);
		transition: background 0.15s;
		flex-shrink: 0;
		pointer-events: none;
		display: block;
	}

	:global(.toggle-thumb) {
		position: absolute;
		top: 2px;
		left: 2px;
		width: 18px;
		height: 18px;
		border-radius: 50%;
		background: #fff;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
		transition: transform 0.15s;
		display: block;
	}

	:global(.toggle-thumb.toggle-checked) {
		transform: translateX(16px);
	}

	/* checked state: track gets accent background */
	:global(.toggle-track.toggle-checked) {
		background: var(--accent);
	}

	/* focus-visible ring on the root button */
	.toggle-wrap:has(:focus-visible) :global(.toggle-track) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.toggle-label {
		font-size: 13px;
		color: var(--text);
		cursor: pointer;
	}

	/* ── Error state ────────────────────────────────────────────── */
	.toggle-err {
		flex: 1 1 100%;
		font-size: 11.5px;
		color: var(--danger);
		margin-top: 2px;
	}
</style>
