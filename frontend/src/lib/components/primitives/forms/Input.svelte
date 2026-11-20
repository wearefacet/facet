<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Field from './Field.svelte';

	type InputType = 'text' | 'number' | 'email' | 'password' | 'date' | 'tel' | 'url';

	let {
		type = 'text',
		label,
		placeholder,
		helper,
		error,
		value = $bindable(''),
		disabled = false,
		readonly = false,
		required = false,
		autocomplete,
		iconLeft,
		iconRight,
		prefix,
		suffix,
		inputmode,
		idScope,
		oninput,
		onchange,
		onblur,
		...rest
	}: {
		type?: InputType;
		label?: string;
		placeholder?: string;
		helper?: string;
		error?: string;
		value?: string | number;
		disabled?: boolean;
		readonly?: boolean;
		required?: boolean;
		/** HTML `autocomplete` token (e.g. "username", "current-password", "one-time-code"). */
		autocomplete?: import('svelte/elements').HTMLInputAttributes['autocomplete'];
		/** Icon rendered inside the input field on the left side. */
		iconLeft?: import('svelte').Snippet;
		/** Icon rendered inside the input field on the right side. */
		iconRight?: import('svelte').Snippet;
		/** Static text adornment rendered inside the input on the left (e.g. "https://"). */
		prefix?: string;
		/** Static text adornment rendered inside the input on the right (e.g. "%", "USD"). */
		suffix?: string;
		/** HTML `inputmode` hint (e.g. "decimal", "numeric") for mobile keyboards. */
		inputmode?: import('svelte/elements').HTMLInputAttributes['inputmode'];
		/**
		 * Unique scope for the synthesized id (B-394). Inline child-row editors
		 * render the same fields per row; a label-only id collides from row 2,
		 * so the row's draft id scopes it — the StructuredInput pattern
		 * `rf-{draft.id}-{field.key}`. Callers without a per-instance key omit
		 * it and keep the label-only scheme.
		 */
		idScope?: string;
		oninput?: (e: Event) => void;
		onchange?: (e: Event) => void;
		onblur?: (e: Event) => void;
	} = $props();

	const hasError = $derived(Boolean(error));
	const hasIconLeft = $derived(Boolean(iconLeft));
	const hasIconRight = $derived(Boolean(iconRight));
	const hasPrefix = $derived(typeof prefix === 'string' && prefix.length > 0);
	const hasSuffix = $derived(typeof suffix === 'string' && suffix.length > 0);
	// A prefix and an icon-left occupy the same visual slot; the icon takes
	// precedence when both are set so callers do not silently stack two
	// adornments on the same edge. The same rule applies to suffix / icon-right.
	const showPrefix = $derived(hasPrefix && !hasIconLeft);
	const showSuffix = $derived(hasSuffix && !hasIconRight);
	// Measured affix widths. The affix auto-sizes to its text, so the padding
	// that reserves room for it on the input must be measured, not fixed —
	// a wide adornment ("https://") overflows any hardcoded slot and its
	// opaque background paints over the value text.
	let affixLeftW = $state(0);
	let affixRightW = $state(0);

	// The synthesized id — one value shared by the label's `for`, the Field
	// base id (helper/error targets), and the input. The scope keeps ids
	// unique when the same label renders per row (B-394).
	const inputId = $derived(
		label ? (idScope ? `input-${idScope}-${label}` : `input-${label}`) : undefined
	);
</script>

<div class="input-wrap" class:input-error={hasError}>
	<Field {label} {required} {helper} {error} id={inputId} forId={inputId}>
		{#snippet children(meta)}
			<div
				class="input-field-wrap"
				class:input-has-icon-left={hasIconLeft || showPrefix}
				class:input-has-icon-right={hasIconRight || showSuffix}
				style:--affix-left-w={affixLeftW ? `${affixLeftW}px` : undefined}
				style:--affix-right-w={affixRightW ? `${affixRightW}px` : undefined}
			>
				{#if iconLeft}
					<span class="input-icon input-icon-left" aria-hidden="true">
						{@render iconLeft()}
					</span>
				{:else if showPrefix}
					<span
						class="input-affix input-affix-left"
						aria-hidden="true"
						bind:clientWidth={affixLeftW}>{prefix}</span
					>
				{/if}

				<input
					id={inputId}
					{type}
					{placeholder}
					{disabled}
					{readonly}
					{required}
					{autocomplete}
					{inputmode}
					bind:value
					class="input-field"
					aria-invalid={hasError || undefined}
					aria-describedby={meta.describedBy}
					{oninput}
					{onchange}
					{onblur}
					{...rest}
				/>

				{#if iconRight}
					<span class="input-icon input-icon-right" aria-hidden="true">
						{@render iconRight()}
					</span>
				{:else if showSuffix}
					<span
						class="input-affix input-affix-right"
						aria-hidden="true"
						bind:clientWidth={affixRightW}>{suffix}</span
					>
				{/if}
			</div>
		{/snippet}
	</Field>
</div>

<style>
	/* ── Input wrap ─────────────────────────────────────────────────────── */
	.input-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	/* ── Field wrap (supports icon adornment) ──────────────────────────── */
	.input-field-wrap {
		display: flex;
		align-items: center;
		position: relative;
	}

	/* ── Field ── matches design-guideline .inp ──────────────────────────── */
	.input-field {
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
		flex: 1;
		min-width: 0;
	}

	.input-has-icon-left .input-field {
		padding-left: 32px;
	}

	.input-has-icon-right .input-field {
		padding-right: 32px;
	}

	.input-field-wrap:focus-within .input-field {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.input-field::placeholder {
		color: var(--text-3);
	}

	.input-field:disabled {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	.input-field[readonly] {
		background: var(--surface-2);
	}

	.input-error .input-field {
		border-color: var(--danger);
	}

	.input-error .input-field-wrap:focus-within .input-field {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Icon adornment ─────────────────────────────────────────────────── */
	.input-icon {
		position: absolute;
		top: 50%;
		transform: translateY(-50%);
		display: flex;
		align-items: center;
		justify-content: center;
		color: var(--text-3);
		pointer-events: none;
		font-size: 14px;
		width: 32px;
	}

	.input-icon-left {
		left: 0;
	}

	.input-icon-right {
		right: 0;
	}

	/* ── Text adornment (prefix / suffix) ───────────────────────────────── */
	/* A string adornment covers an inline label like "https://" or a unit like
	   "%", pinned to one edge of the input. It auto-sizes to its text (unlike
	   the fixed-width icon slot) and is rendered with a hairline divider so the
	   user reads it as chrome, not as the value being edited. */
	.input-affix {
		position: absolute;
		top: 50%;
		transform: translateY(-50%);
		display: flex;
		align-items: center;
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
		background: var(--surface-2);
		pointer-events: none;
		white-space: nowrap;
		height: 100%;
	}

	.input-affix-left {
		left: 0;
		padding: 0 8px;
		border-right: 1px solid var(--border);
		border-top-left-radius: var(--r);
		border-bottom-left-radius: var(--r);
	}

	.input-affix-right {
		right: 0;
		padding: 0 8px;
		border-left: 1px solid var(--border);
		border-top-right-radius: var(--r);
		border-bottom-right-radius: var(--r);
	}

	/* Reserve room for the affix on the corresponding edge of the input. The
	   measured width rides the wrap as a custom property; the 7px gap keeps the
	   value clear of the hairline divider. Until measured (SSR paint), the
	   fallback keeps the legacy fixed slot. */
	.input-field-wrap:has(.input-affix-left) .input-field {
		padding-left: calc(var(--affix-left-w, 49px) + 7px);
	}

	.input-field-wrap:has(.input-affix-right) .input-field {
		padding-right: calc(var(--affix-right-w, 49px) + 7px);
	}

	/* Helper and error text render through the shared Field component. */
</style>
