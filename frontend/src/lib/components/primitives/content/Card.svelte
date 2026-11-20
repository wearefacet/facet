<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * Card — a tinted container for document previews in kanban/grid views.
	 *
	 * The card applies a doctype-colored border-top accent via `--tint` and
	 * renders the children snippet (typically a DocumentViewTemplate) inside.
	 *
	 * ```svelte
	 * <Card doctype="contact">
	 *   {#snippet children()}
	 *     <DocumentViewTemplate {template} {document} />
	 *   {/snippet}
	 * </Card>
	 * ```
	 */
	let {
		/**
		 * Doctype key for tinting. One of: invoice, shipment, contact,
		 * task, document, contract. Controls the top border accent color.
		 */
		doctype = 'document',
		/** When true, shows drag handle and sets grab cursor (no DND wired yet). */
		draggable = false,
		/** Body content rendered inside the card. */
		children,
		...rest
	}: {
		doctype?: string;
		draggable?: boolean;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<div
	class="card"
	class:card-draggable={draggable}
	style="--tint: var(--dt-{doctype})"
	role="region"
	{...rest}
>
	{#if draggable}
		<div class="card-grip" aria-hidden="true">
			<div class="card-grip-dot"></div>
			<div class="card-grip-dot"></div>
			<div class="card-grip-dot"></div>
		</div>
	{/if}
	<div class="card-inner">
		{@render children?.()}
	</div>
</div>

<style>
	/* ── Card — matches table.html .card + design-guideline .cap tinting ─── */
	.card {
		container-type: inline-size;
		min-width: 0;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 11px 12px;
		box-shadow: var(--sh-1);
		transition:
			border-color 0.12s ease,
			box-shadow 0.12s ease;
		border-top: 2px solid color-mix(in srgb, var(--tint) 40%, var(--border));
	}

	.card:hover {
		border-color: var(--border-strong);
		box-shadow: var(--sh-2);
	}

	.card-draggable {
		cursor: grab;
	}

	.card-draggable:active {
		cursor: grabbing;
	}

	.card-grip {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 3px;
		padding: 6px 0 10px;
		opacity: 0.5;
		transition: opacity 0.12s ease;
	}

	.card-draggable:hover .card-grip {
		opacity: 1;
	}

	.card-grip-dot {
		width: 4px;
		height: 4px;
		border-radius: 50%;
		background: var(--text-3);
	}

	.card-inner {
		overflow: hidden;
	}
</style>
