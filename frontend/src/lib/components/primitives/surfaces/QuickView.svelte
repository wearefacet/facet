<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	let {
		open = false,
		onclose = () => {},
		onclosed = () => {},
		header,
		title,
		children,
		footer
	}: {
		/** Whether the drawer is visible. */
		open?: boolean;
		/** Called when the user clicks the scrim or close button. */
		onclose?: () => void;
		/** Called once the close slide-out finished and the drawer is off screen. */
		onclosed?: () => void;
		/** Content for the header bar (capsule, actions, etc.). Close button is always appended. */
		header?: import('svelte').Snippet;
		/** Optional title area below the header. */
		title?: import('svelte').Snippet;
		/** Scrollable body content. */
		children?: import('svelte').Snippet;
		/** Optional footer with action buttons. */
		footer?: import('svelte').Snippet;
	} = $props();

	/**
	 * End of the close phase. `transitionend` does not fire when CSS
	 * transitions are off (prefers-reduced-motion), so a timer just above
	 * the longest close transition (0.18s) covers that case. The host guards
	 * repeated calls, so a late call is a no-op.
	 */
	$effect(() => {
		if (open) return;
		const t = setTimeout(onclosed, 240);
		return () => clearTimeout(t);
	});

	function handleDrawerTransitionEnd(event: TransitionEvent) {
		// Child transitions bubble to the drawer; only the drawer's own slide
		// settles the close phase.
		if (event.target !== event.currentTarget || event.propertyName !== 'transform') return;
		if (open) return;
		onclosed();
	}
</script>

<div class="scrim" class:on={open} onclick={onclose} role="presentation"></div>
<aside class="drawer" class:on={open} inert={!open} ontransitionend={handleDrawerTransitionEnd}>
	<div class="dhead">
		{@render header?.()}
		<span class="sp"></span>
		<button class="x" onclick={onclose} title={m.common_close()}>
			<svg
				width="17"
				height="17"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
				viewBox="0 0 24 24"
			>
				<path d="M6 6l12 12M18 6 6 18" />
			</svg>
		</button>
	</div>

	{#if title}
		<div class="dtitle">
			{@render title()}
		</div>
	{/if}

	<div class="dbody">
		{@render children?.()}
	</div>

	{#if footer}
		<div class="dfoot">
			{@render footer()}
		</div>
	{/if}
</aside>

<style>
	.scrim {
		position: absolute;
		inset: 0;
		background: rgba(10, 12, 16, 0.18);
		opacity: 0;
		pointer-events: none;
		visibility: hidden;
		transition:
			opacity 0.15s ease,
			visibility 0s 0.15s;
		z-index: 2;
	}

	.scrim.on {
		opacity: 1;
		pointer-events: auto;
		visibility: visible;
		transition: opacity 0.15s ease;

		/* Enter on mount: the drawer mounts with `.on` already applied, so the
		   first style resolution needs a starting value to transition from. */
		@starting-style {
			opacity: 0;
		}
	}

	.drawer {
		position: absolute;
		top: 0;
		right: 0;
		height: 100%;
		width: 420px;
		max-width: 92vw;
		background: var(--surface);
		border-left: 1px solid var(--border);
		box-shadow: var(--sh-2);
		visibility: hidden;
		transform: translateX(100%);
		transition:
			transform 0.18s ease,
			visibility 0s 0.18s;
		display: flex;
		flex-direction: column;
		z-index: 3;
	}

	.drawer.on {
		visibility: visible;
		transform: none;
		transition: transform 0.18s ease;

		/* Enter on mount — see the scrim rule. */
		@starting-style {
			transform: translateX(100%);
		}
	}

	.dhead {
		padding: 14px 16px;
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.dhead .sp {
		flex: 1;
	}

	.dhead .x {
		width: 30px;
		height: 30px;
		border-radius: 8px;
		display: grid;
		place-items: center;
		color: var(--text-2);
		flex: none;
	}

	.dhead .x:hover {
		background: var(--sunken);
		color: var(--text);
	}

	.dtitle {
		padding: 16px 18px 6px;
	}

	.dbody {
		flex: 1;
		overflow: auto;
		padding: 8px 18px 18px;
		/* Establish an inline-size containment context so descendants (DvtGrid,
	   DvtField, …) can use `@container` queries to adapt to the drawer width. */
		container-type: inline-size;
	}

	.dfoot {
		padding: 12px 16px;
		border-top: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 9px;
	}
</style>
