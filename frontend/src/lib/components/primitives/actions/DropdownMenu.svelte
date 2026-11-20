<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { DropdownMenu } from 'bits-ui';
	import '../shared.css';

	export type MenuItem = {
		label: string;
		onclick?: () => void;
		/** Optional tooltip text (e.g. the action's description). */
		title?: string;
		disabled?: boolean;
		separator?: boolean;
		/** Destructive styling (red text). For irreversible actions like Delete. */
		variant?: 'danger';
	};

	let {
		label: triggerLabel,
		items,
		align = 'start',
		/** When true, renders an icon-only trigger (the children snippet) instead of text + caret. */
		trigger = 'text',
		children,
		triggerChild,
		...rest
	}: {
		/** Accessible label for the trigger button (used as the trigger's `aria-label` too). */
		label: string;
		/** Menu items. An item with `separator: true` renders a divider. */
		items: MenuItem[];
		/** Alignment of the dropdown relative to the trigger. */
		align?: 'start' | 'center' | 'end';
		/** Trigger appearance: `'text'` (label + caret) or `'icon'` (renders the children snippet — e.g. an IconButton). */
		trigger?: 'text' | 'icon';
		/** Icon/children to render inside the trigger when `trigger` is `'icon'`. */
		children?: import('svelte').Snippet;
		/** When provided, the caller's own element becomes the trigger (bits-ui `child`
			mode): the snippet receives the trigger props and must spread them on a single
			interactive element (a `<button>` or `<a>`). Used by Button's `menu` mode, where
			the styled button itself is the trigger — nesting a Trigger inside one would
			emit `<button><button>`, which breaks SSR hydration. */
		triggerChild?: import('svelte').Snippet<[Record<string, unknown>]>;
	} = $props();

	let open = $state(false);
</script>

<DropdownMenu.Root bind:open>
	<!-- The trigger renders as a single native <button>. Icon mode fills its
	children with the icon only — nesting an IconButton here would emit
	<button><button>, which the browser repairs during SSR and breaks
	hydration (the node_invalid_placement_ssr → hydration_mismatch crash).
	triggerChild mode goes one step further: the caller's element IS the
	trigger, so there is still exactly one interactive element. -->
	{#if triggerChild}
		<DropdownMenu.Trigger {...rest}>
			{#snippet child({ props })}
				{@render triggerChild(props)}
			{/snippet}
		</DropdownMenu.Trigger>
	{:else}
		<DropdownMenu.Trigger
			class="dm-trigger{trigger === 'icon' ? ' dm-trigger-icon' : ''}"
			aria-label={triggerLabel}
			{...rest}
		>
			{#if trigger === 'icon'}
				{@render children?.()}
			{:else}
				{triggerLabel}
				<span class="dm-caret" aria-hidden="true">▼</span>
			{/if}
		</DropdownMenu.Trigger>
	{/if}

	<DropdownMenu.Portal>
		<DropdownMenu.Content class="dm-content menu-surface" sideOffset={4} {align}>
			{#each items as item (item.label + (item.separator ? '-sep' : ''))}
				{#if item.separator}
					<DropdownMenu.Separator class="menu-separator" />
				{:else}
					<DropdownMenu.Item
						class={'menu-item' + (item.variant === 'danger' ? ' dm-item-danger' : '')}
						disabled={item.disabled}
						title={item.title}
						onSelect={() => {
							// No preventDefault: the handler runs first, then Bits UI
							// closes the menu — the standard pick-and-continue flow
							// (e.g. "+ Add filter" must not block the toolbar row).
							item.onclick?.();
						}}
					>
						{item.label}
					</DropdownMenu.Item>
				{/if}
			{/each}
		</DropdownMenu.Content>
	</DropdownMenu.Portal>
</DropdownMenu.Root>

<style>
	/* ── Dropdown menu (classes applied to Bits UI components) ─────────── */
	:global(.dm-trigger) {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font: inherit;
		color: inherit;
		cursor: pointer;
		border: none;
		background: none;
		padding: 0;
	}

	.dm-caret {
		font-size: 0.6em;
		line-height: 1;
		opacity: 0.7;
	}

	/* Icon-mode trigger — mirrors the IconButton look (see IconButton.svelte)
	without a nested <button>. */
	:global(.dm-trigger-icon) {
		width: 34px;
		height: 34px;
		border-radius: 9px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: var(--text-2);
		transition:
			background 0.12s,
			color 0.12s;
		flex-shrink: 0;
	}

	:global(.dm-trigger-icon:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.dm-trigger-icon:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	/* ── Content ─────────────────────────────────────────────────────── */
	/* Surface look and item base styles come from the shared menu classes. */
	:global(.dm-content) {
		min-width: 160px;
		z-index: 1100;
	}

	/* Destructive item — demoted but still distinguishable. Red text only,
	   no red fill, so it stays quiet inside the menu. */
	:global(.dm-item-danger) {
		color: var(--danger);
	}

	:global(.dm-item-danger[data-highlighted]) {
		background: var(--danger-weak);
	}
</style>
