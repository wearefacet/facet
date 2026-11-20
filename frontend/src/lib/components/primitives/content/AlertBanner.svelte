<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	type Variant = 'danger' | 'warn';

	let {
		message,
		details = [],
		variant = 'danger',
		dismissable = false,
		onDismiss
	}: {
		/** Primary alert text. */
		message: string;
		/** Optional secondary detail lines (e.g. non-field validation errors). */
		details?: string[];
		/** Visual tone — default `danger` matches the app's error banner. */
		variant?: Variant;
		/** When true, renders a dismiss control that fires `onDismiss`. */
		dismissable?: boolean;
		onDismiss?: () => void;
	} = $props();
</script>

<div class="alert-banner" class:alert-warn={variant === 'warn'} role="alert">
	<span class="alert-msg">{message}</span>
	{#if dismissable}
		<button
			class="alert-dismiss"
			type="button"
			onclick={onDismiss}
			aria-label={m.doc_banner_dismiss()}>{m.doc_banner_dismiss()}</button
		>
	{/if}
	{#if details.length > 0}
		<ul class="alert-details">
			{#each details as detail (detail)}
				<li>{detail}</li>
			{/each}
		</ul>
	{/if}
</div>

<style>
	.alert-banner {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 8px 12px;
		margin: 12px 24px 0;
		padding: 9px 12px;
		font-size: 13px;
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
	}

	.alert-warn {
		color: var(--warn);
		background: var(--warn-weak);
		border-color: var(--warn);
	}

	.alert-msg {
		font-weight: 600;
	}

	.alert-dismiss {
		margin-left: auto;
		border: 1px solid currentColor;
		background: transparent;
		color: inherit;
		border-radius: 4px;
		padding: 2px 8px;
		font-size: 11px;
		cursor: pointer;
	}

	.alert-details {
		flex: 1 1 100%;
		margin: 0;
		padding-left: 18px;
	}

	.alert-details li {
		margin-top: 2px;
		font-weight: 400;
	}
</style>
