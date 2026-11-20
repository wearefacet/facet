<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';
	import {
		formatKeys,
		getRegisteredShortcuts,
		getShortcutsHelpOpen,
		setShortcutsHelpOpen,
		type ShortcutEntry,
		type ShortcutGroup
	} from '$lib/shortcuts.svelte';

	/**
	 * ShortcutsDialog — the keyboard-shortcut cheat sheet, mounted once in
	 * the root layout and opened with `?` (the store lives in
	 * `$lib/shortcuts.svelte.ts`). It renders every entry that is currently
	 * registered — route scope on top, then the global scope — grouped by
	 * section, so the list always reflects what the active page actually
	 * answers to.
	 */

	const open = $derived(getShortcutsHelpOpen());

	const groups: { key: ShortcutGroup; label: string }[] = [
		{ key: 'general', label: m.shortcuts_group_general() },
		{ key: 'list', label: m.shortcuts_group_list() },
		{ key: 'document', label: m.shortcuts_group_document() }
	];

	/**
	 * The registry holds plain data (no signals), so the section list is a
	 * plain function, not a `$derived`. Bits UI mounts `Dialog.Content` per
	 * open and unmounts it on close, so the `{#each sections()}` inside it
	 * re-computes on every open — the dialog always lists the entries
	 * registered at that moment.
	 */
	function sections(): { key: ShortcutGroup; label: string; items: ShortcutEntry[] }[] {
		const all = getRegisteredShortcuts();
		return groups
			.map((g) => ({ ...g, items: all.filter((e) => e.group === g.key) }))
			.filter((g) => g.items.length > 0);
	}
</script>

<Dialog.Root
	{open}
	onOpenChange={(v) => {
		setShortcutsHelpOpen(v);
	}}
>
	<Dialog.Portal>
		<Dialog.Overlay class="shortcuts-overlay" />
		<Dialog.Content class="shortcuts-content">
			<Dialog.Title class="shortcuts-title">{m.shortcuts_title()}</Dialog.Title>
			<Dialog.Description class="shortcuts-desc">{m.shortcuts_desc()}</Dialog.Description>

			{#each sections() as section (section.key)}
				<section class="sgroup">
					<h3 class="sgroup-title">{section.label}</h3>
					<ul class="sgroup-list">
						{#each section.items as item (item.id)}
							<li class="srow">
								<span class="srow-label">{item.label}</span>
								<span class="srow-keys">
									{#each formatKeys(item.keys) as k, i (i)}
										<kbd>{k}</kbd>
									{/each}
								</span>
							</li>
						{/each}
					</ul>
				</section>
			{/each}

			<Dialog.Close
				class="close-btn"
				title={m.common_close()}
				aria-label={m.shortcuts_close_aria()}
			>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.shortcuts-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 120;
	}

	:global(.shortcuts-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(440px, 92vw);
		max-height: min(640px, 86vh);
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 14px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		padding: 24px;
		z-index: 121;
	}

	:global(.shortcuts-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.shortcuts-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.sgroup {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.sgroup-title {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--text-3);
		margin: 0;
	}

	.sgroup-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
	}

	.srow {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
		font-size: 13px;
		color: var(--text);
	}

	.srow:last-child {
		border-bottom: none;
	}

	.srow-label {
		min-width: 0;
	}

	.srow-keys {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		flex: none;
	}

	.srow-keys kbd {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 2px 6px;
		min-width: 20px;
		text-align: center;
	}

	:global(.shortcuts-content .close-btn) {
		position: absolute;
		top: 14px;
		right: 14px;
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: none;
		border-radius: var(--r);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.shortcuts-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.shortcuts-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
