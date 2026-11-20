<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * DoctypeBadge — inline doctype identifier with the signature diamond.
	 *
	 * Renders a small badge showing the doctype's name (display font) tinted
	 * by the per-doctype `--dt-*` token. Used in type selectors, table headers,
	 * form labels, and any context where the doctype is identified visually.
	 *
	 * For document record display (ID + label), see `Capsule` instead.
	 */
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';

	type DoctypeTint = 'invoice' | 'shipment' | 'contact' | 'task' | 'document' | 'contract';

	let {
		doctype = 'invoice',
		label,
		icon,
		color,
		...rest
	}: {
		/** Per-doctype tint variant. Defaults to `invoice`. */
		doctype?: DoctypeTint;
		/** Human-readable doctype label (e.g. "Invoice", "Customer"). */
		label: string;
		/** Optional doctype icon name — falls back to the diamond mark. */
		icon?: string | null;
		/** Optional accent color, forwarded to the icon/diamond mark. */
		color?: string | null;
	} = $props();

	const cls = $derived(`dt-badge dt-badge-${doctype}`);
</script>

<span class={cls} {...rest}>
	<span class="dt-badge-mail">
		<DoctypeIcon {icon} {color} shadow active />
	</span>
	<span class="dt-badge-label">{label}</span>
</span>

<style>
	.dt-badge {
		--tint: var(--text-2);
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 2px 10px;
		border-radius: var(--r);
		background: color-mix(in srgb, var(--tint) 9%, var(--surface));
		border: 1px solid color-mix(in srgb, var(--tint) 34%, transparent);
		font-family: var(--font-display);
		font-weight: 500;
		font-size: 13px;
		line-height: 20px;
		color: color-mix(in srgb, var(--tint) 75%, var(--text));
		white-space: nowrap;
	}

	.dt-badge-mail {
		display: inline-flex;
		align-items: center;
		flex: none;
	}

	.dt-badge-invoice {
		--tint: var(--dt-invoice);
	}
	.dt-badge-shipment {
		--tint: var(--dt-shipment);
	}
	.dt-badge-contact {
		--tint: var(--dt-contact);
	}
	.dt-badge-task {
		--tint: var(--dt-task);
	}
	.dt-badge-document {
		--tint: var(--dt-document);
	}
	.dt-badge-contract {
		--tint: var(--dt-contract);
	}
</style>
