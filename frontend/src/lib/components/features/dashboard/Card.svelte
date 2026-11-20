<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		title,
		description,
		variant = 'notice',
		onaction,
		actionLabel
	}: {
		title: string;
		description?: string;
		variant?: 'danger' | 'warning' | 'notice';
		onaction?: () => void;
		actionLabel?: string;
	} = $props();

	const isDanger = $derived(variant === 'danger');
	const isWarning = $derived(variant === 'warning');
	const isNotice = $derived(variant === 'notice');

	// Map variant names to actual CSS custom property names:
	//   "danger" → --danger, "warning" → --warn, "notice" → --info
	const colorVar = $derived(
		variant === 'danger' ? 'danger' : variant === 'warning' ? 'warn' : 'info'
	);
</script>

<div
	class="card"
	class:card-danger={isDanger}
	class:card-warning={isWarning}
	class:card-notice={isNotice}
>
	<div class="ch">
		<span class="nm" style="color: var(--{colorVar})">{title}</span>
		<span class="sp"></span>
	</div>
	{#if description}
		<div class="cd">{description}</div>
	{/if}
	{#if onaction && actionLabel}
		<button
			class="card-action-btn"
			style="color:var(--{colorVar});border-color:color-mix(in srgb,var(--{colorVar}) 40%,transparent)"
			onclick={onaction}
		>
			{actionLabel}
		</button>
	{/if}
</div>

<style>
	.card {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 18px 20px;
		margin-bottom: 14px;
	}
	.card-danger {
		border-color: color-mix(in srgb, var(--danger) 35%, transparent);
	}
	.card-warning {
		border-color: color-mix(in srgb, var(--warn) 35%, transparent);
	}
	.card-notice {
		border-color: color-mix(in srgb, var(--info) 35%, transparent);
	}

	.ch {
		display: flex;
		align-items: center;
		gap: 11px;
		margin-bottom: 4px;
	}
	.nm {
		font-family: var(--font-sans);
		font-weight: 600;
		font-size: 14px;
	}
	.sp {
		flex: 1;
	}
	.cd {
		font-size: 12.5px;
		color: var(--text-2);
		margin-bottom: 14px;
	}

	.card-action-btn {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 6px 10px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		border: 1px solid;
		background: none;
		cursor: pointer;
		font: inherit;
	}
	.card-action-btn:hover {
		background: var(--sunken);
	}
</style>
