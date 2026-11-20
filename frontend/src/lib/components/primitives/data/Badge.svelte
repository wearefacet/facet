<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	type Variant = 'neutral' | 'accent' | 'ok' | 'warn' | 'danger' | 'info';
	/** Per-doctype tint variants — uses `--dt-*` design tokens (overrides `variant` when set). */
	type DoctypeTint = 'invoice' | 'shipment' | 'contact' | 'task' | 'document' | 'contract';
	type Size = 'sm' | 'md';

	let {
		variant = 'neutral',
		doctype,
		tint,
		size = 'md',
		label,
		children,
		class: klass = '',
		...rest
	}: {
		/**
		 * Semantic color variant. Defaults to `neutral`.
		 * - `neutral` — muted gray (matches the example's `.badge.muted`)
		 * - `accent` — brand gold
		 * - `info` — blue semantic
		 * - `ok` / `warn` / `danger` — semantic colors
		 */
		variant?: Variant;
		/** Per-doctype tint variant. When set, overrides the `variant` color entirely. */
		doctype?: DoctypeTint;
		/**
		 * Arbitrary hex/rgb color (e.g. a doctype enum value's `color`). When
		 * set, overrides `variant` and `doctype` — the badge uses this color for
		 * both its text and the faint tinted background (color-mixed against
		 * `--surface`). Used to surface declared enum-value colors without
		 * baking each one into a CSS variant.
		 */
		tint?: string;
		/** Size. Defaults to `md`. */
		size?: Size;
		/** Badge label text (alternative to children snippet). */
		label?: string;
		children?: import('svelte').Snippet;
		/** Extra class names forwarded to the root `<span>`. */
		class?: string;
	} = $props();

	const cls = $derived(
		[
			'badge',
			`badge-${size}`,
			tint ? 'badge-tint' : doctype ? `badge-dt-${doctype}` : `badge-${variant}`,
			klass
		]
			.filter(Boolean)
			.join(' ')
	);

	const style = $derived(tint ? `--tint: ${tint};` : undefined);
</script>

<span class={cls} {style} {...rest}>
	{@render children?.()}
	{label}
</span>

<style>
	/* ── Badge base ── matches design-guideline .badge ──────────────────── */
	.badge {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 4px 12px;
		border-radius: var(--r-pill);
		font-size: 11.5px;
		font-weight: 600;
		line-height: 1;
		white-space: nowrap;
	}

	/* Decorative dot — matches design-guideline .badge::before */
	.badge::before {
		content: '';
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: currentColor;
		opacity: 0.9;
		flex-shrink: 0;
	}

	/* ── Sizes ──────────────────────────────────────────────────────────── */
	.badge-sm {
		padding: 3px 9px;
		font-size: 10.5px;
		letter-spacing: 0.02em;
	}

	.badge-sm::before {
		width: 5px;
		height: 5px;
	}

	/* ── Semantic variants ── matches design-guideline .badge.{ok,warn,dn,muted,info} ──── */
	.badge-neutral {
		color: var(--text-2);
		background: var(--sunken);
	}

	.badge-accent {
		color: var(--accent-ink);
		background: var(--accent-weak);
	}

	.badge-ok {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.badge-warn {
		color: var(--warn);
		background: var(--warn-weak);
	}

	.badge-danger {
		color: var(--danger);
		background: var(--danger-weak);
	}

	.badge-info {
		color: var(--info);
		background: var(--info-weak);
	}

	/* ── Per-doctype tints ──────────────────────────────────────────────── */
	.badge-dt-invoice {
		background: color-mix(in srgb, var(--dt-invoice) 14%, transparent);
		color: var(--dt-invoice);
	}

	.badge-dt-shipment {
		background: color-mix(in srgb, var(--dt-shipment) 14%, transparent);
		color: var(--dt-shipment);
	}

	.badge-dt-contact {
		background: color-mix(in srgb, var(--dt-contact) 14%, transparent);
		color: var(--dt-contact);
	}

	.badge-dt-task {
		background: color-mix(in srgb, var(--dt-task) 14%, transparent);
		color: var(--dt-task);
	}

	.badge-dt-document {
		background: color-mix(in srgb, var(--dt-document) 14%, transparent);
		color: var(--dt-document);
	}

	.badge-dt-contract {
		background: color-mix(in srgb, var(--dt-contract) 14%, transparent);
		color: var(--dt-contract);
	}

	/* ── Data-driven arbitrary tint ────────────────────────────────────── */
	/* Used when a `tint` hex/rgb color is supplied (e.g. an enum value's
	   declared `color`). The badge's dot already uses `currentColor`, so only
	   the text and a faint mixed background need to be set. */
	.badge-tint {
		color: var(--tint);
		background: color-mix(in srgb, var(--tint) 14%, transparent);
	}
</style>
