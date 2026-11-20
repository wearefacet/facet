<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveDoctypeIcon } from '$lib/doctype/doctype-icons.js';

	/**
	 * DoctypeIcon — the visual mark identifying a doctype.
	 *
	 * Shows the doctype's configured Lucide icon when one is set; otherwise,
	 * falls back to the signature diamond. Used anywhere a doctype is
	 * referenced (headers, lists, badges, capsules, schematic nodes).
	 */
	let {
		icon,
		color,
		shadow = false,
		active = false,
		size = 10
	}: {
		/** Stored kebab-case Lucide icon name (e.g. `"building-2"`). Empty/unknown → diamond. */
		icon?: string | null;
		/** Accent color for the tint (hex, or a CSS var). Used for both the diamond and the icon. */
		color?: string | null;
		/**
		 * Whether the mark reads as a "filled" glyph. When `true` (and an icon
		 * is set) the icon renders with `currentColor`; the diamond renders with
		 * the tinted fill used by badges/capsules. When `false` the diamond uses
		 * the lighter border-ink style of page headers.
		 */
		shadow?: boolean;
		/** Whether the mark is in an "active"/selected state (schematic). */
		active?: boolean;
		/** Icon render size in pixels. Ignored when falling back to the diamond. */
		size?: number;
	} = $props();

	const Icon = $derived(resolveDoctypeIcon(icon));
	const type = $derived(Icon === resolveDoctypeIcon(null) ? 'diamond' : 'icon');
	// For an icon mark, pick a legible stroke color from the tint; the diamond
	// is tinted via its own classes instead. `--tint` is set on the wrapper so
	// children can reference it.
	const stroke = $derived('currentColor');
</script>

{#if type === 'icon'}
	<span
		class="doctype-icon doctype-icon-glyph"
		class:active
		style={`--tint:${color ?? 'var(--accent)'}; width:${size}px; height:${size}px;`}
		aria-hidden="true"
	>
		<Icon class="doctype-icon-svg" {stroke} />
	</span>
{:else}
	<span
		class="doctype-icon doctype-icon-diamond"
		class:shadow
		class:active
		style={`--tint:${color ?? 'var(--accent)'}`}
		aria-hidden="true"
	></span>
{/if}

<style>
	.doctype-icon {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex: none;
	}

	/* ── Diamond (fallback) ─────────────────────────────────────────── */
	.doctype-icon-diamond {
		width: 10px;
		height: 10px;
		transform: rotate(45deg);
		border-radius: 3px;
		background: var(--tint);
	}

	.doctype-icon-diamond.shadow {
		width: 8px;
		height: 8px;
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--tint) 22%, transparent);
		border: 1.4px solid var(--tint);
	}

	.doctype-icon-diamond.active {
		background: var(--tint);
	}

	/* ── Icon glyph ─────────────────────────────────────────────────── */
	.doctype-icon-glyph {
		color: color-mix(in srgb, var(--tint) 85%, currentColor);
	}

	.doctype-icon-glyph.active {
		color: var(--tint);
	}

	.doctype-icon-glyph :global(svg) {
		width: 100%;
		height: 100%;
	}
</style>
