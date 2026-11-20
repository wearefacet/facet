<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { Search } from '@lucide/svelte';
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import * as m from '$lib/paraglide/messages';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
	import { DataSourceError } from '$lib/datasource/types.js';
	import { getNavDomains } from '$lib/navState.svelte';
	import { getRecentDocuments, removeRecentDocument } from '$lib/recentDocuments.svelte';
	import {
		assemblePaletteGroups,
		filterPaletteGroups,
		paletteGroupLabel,
		type PaletteCommand,
		type PaletteEntry
	} from './searchGroups.js';
	import { createRecordSearch, type RecordEntry, type SearchScope } from './searchRecords.js';
	import { insideDialog, isModCombo } from '$lib/shortcuts.svelte';

	/**
	 * CommandPalette — the global search surface behind the top-bar trigger
	 * and `Cmd/Ctrl+K`.
	 *
	 * Four groups: Navigate (nav model — domains, then the active domain's
	 * doctypes), Recent (per-browser recent documents, labels resolved like
	 * the dashboard's), Records (the debounced search endpoint), and Actions
	 * (the host command list). Groups without rows do not render; the records
	 * group appears when its first results land.
	 *
	 * Mounted once per shell. The keybind lives on a component-owned
	 * `<svelte:window>` listener — deliberately outside the shortcuts
	 * registry — so it ships with every mount. The listener mirrors the
	 * dispatcher's contract (`defaultPrevented`, dialog guard, platform-mod
	 * rule): a registry entry that already acted wins, an open dialog keeps
	 * its keyboard space, and the palette never stacks over one.
	 */

	let {
		open = $bindable(false),
		commands,
		activeDomain,
		searchPlaceholder = m.nav_search_placeholder()
	}: {
		/** Two-way bindable open state; the host trigger and `Cmd/Ctrl+K` both set it. */
		open?: boolean;
		/** Host-supplied actions for the Actions group. */
		commands: PaletteCommand[];
		/** Active domain id, or `''` when none (Configure). */
		activeDomain: string;
		/** Input placeholder. */
		searchPlaceholder?: string;
	} = $props();

	let query = $state('');
	let records = $state<RecordEntry[]>([]);
	let scope = $state<SearchScope>('domain');
	let activeIndex = $state(0);
	let recentLabels = $state<Record<string, string>>({});

	// The record-search adapter owns the debounce and the stale-drop counter;
	// it outlives a single open cycle and resets with the palette.
	const searcher = createRecordSearch({
		onResults: (entries) => {
			records = entries;
		}
	});

	const recents = $derived(activeDomain ? getRecentDocuments(activeDomain) : []);

	// Fresh state on every open: a reopened palette never inherits the query,
	// the escalated scope, or the previous session's rows.
	$effect(() => {
		if (!open) return;
		query = '';
		scope = 'domain';
		activeIndex = 0;
		recentLabels = {};
		searcher.reset();
	});

	// Recent labels resolve the way the dashboard's chips do: the store keeps
	// only ids, so each entry's label comes from one `show()` round-trip
	// (deduped by the in-flight set and 60s-cached by the show cache). The
	// id stands in until the label lands or the fetch fails. A resolve that
	// fails with a definitive "gone" answer (404 past retention, 410
	// tombstone) prunes the entry from the store (B-392): the row would
	// otherwise render a raw id and 404 on activation. Other failures — a
	// 5xx blip, a network drop, a lost read grant — keep the entry.
	const recentDriver = new DocumentDataDriver('');
	const labelsInFlight = new SvelteSet<string>();
	$effect(() => {
		if (!open) return;
		void recents;
		let cancelled = false;
		for (const entry of recents) {
			if (untrack(() => labelsInFlight.has(entry.id))) continue;
			untrack(() => labelsInFlight.add(entry.id));
			recentDriver
				.domain(entry.domain)
				.doctype(entry.doctype)
				.doc(entry.id)
				.show()
				.then((res) => {
					if (!cancelled) recentLabels[entry.id] = res.meta.display_name ?? entry.id;
				})
				.catch((e: unknown) => {
					// Runs after the effect may have re-run or closed — a document
					// that answered "gone" stays gone, so the prune ignores
					// `cancelled` on purpose.
					if (e instanceof DataSourceError && (e.status === 404 || e.status === 410)) {
						removeRecentDocument(entry.id);
					}
				});
		}
		return () => {
			cancelled = true;
		};
	});

	// The Configure shell mounts its own palette whose Navigate surface is its
	// command list; the live nav model would offer routes that shell does not
	// own, so its Navigate group stays empty there.
	const navModelAvailable = $derived(!page.url.pathname.startsWith('/Configure'));
	const navDomains = $derived(getNavDomains());

	const assembled = $derived(
		assemblePaletteGroups({
			domains: navModelAvailable ? navDomains : [],
			activeDomain,
			recents,
			recentLabels,
			commands,
			records,
			scope,
			query
		})
	);
	const groups = $derived(filterPaletteGroups(assembled, query));
	const rows = $derived(groups.flatMap((g) => g.entries));

	// Selection follows the visible rows. The reset to the first row fires
	// only when the row-key sequence itself changes (a query edit, results
	// landing). The label writes, search responses, and nav rebuilds that
	// re-derive `rows` behind the app keep the same keys — resetting on their
	// array identity alone snapped the highlight back to the first row while
	// the user was arrowing, so arrows and Enter read as dead (B-107).
	// Plain-`let` shadow: the effect writes `activeIndex`, so the dedup must
	// not read it (workflow doc → equality-guard trap).
	let lastRowKeys = '';
	$effect(() => {
		const keys = rows.map((row) => row.key).join('\n');
		if (keys === lastRowKeys) return;
		lastRowKeys = keys;
		activeIndex = 0;
	});

	const activeRow = $derived(rows[Math.min(activeIndex, Math.max(rows.length - 1, 0))]);
	const showEmpty = $derived(query.trim().length >= 2 && groups.length === 0);
	// The popup state of the ARIA combobox: the listbox renders with the
	// groups; the empty-state notice (and a closed list) reads as collapsed.
	const listOpen = $derived(groups.length > 0);

	function handleGlobalKeydown(e: KeyboardEvent) {
		if (e.defaultPrevented || e.isComposing) return;
		if (!isModCombo(e) || e.key.toLowerCase() !== 'k') return;
		// An open dialog owns the keyboard — the dispatcher skips it the same
		// way. While the palette itself is open the focus sits inside it, so
		// the toggle still reaches its own close path.
		if (insideDialog(e.target) && !open) return;
		e.preventDefault();
		open = !open;
	}

	function handleInput(e: Event) {
		const value = (e.target as HTMLInputElement).value;
		query = value;
		if (value.trim().length === 0 && scope !== 'domain') scope = 'domain';
		// Without an active domain (Configure) the records group stays empty —
		// the domain route has no scope to query, so only the local filter runs.
		if (activeDomain) searcher.query(value, scope, activeDomain);
		else searcher.reset();
	}

	/** The escalation chip — back to the active-domain scope, re-run. */
	function handleScopeBack() {
		scope = 'domain';
		if (activeDomain) searcher.query(query, 'domain', activeDomain);
	}

	function scrollToRow(key: string) {
		// Runs from user events only, so the DOM is always present.
		document.getElementById(key)?.scrollIntoView({ block: 'nearest' });
	}

	function moveSelection(next: number) {
		activeIndex = next;
		const row = rows[next];
		if (row) scrollToRow(row.key);
	}

	function handleContentKeydown(e: KeyboardEvent) {
		if (e.defaultPrevented || e.isComposing) return;
		const count = rows.length;
		if (count === 0) return;
		const current = Math.min(activeIndex, count - 1);
		switch (e.key) {
			case 'ArrowDown':
				e.preventDefault();
				moveSelection(Math.min(current + 1, count - 1));
				break;
			case 'ArrowUp':
				e.preventDefault();
				moveSelection(Math.max(current - 1, 0));
				break;
			case 'Home':
				e.preventDefault();
				moveSelection(0);
				break;
			case 'End':
				e.preventDefault();
				moveSelection(count - 1);
				break;
			case 'Enter':
				e.preventDefault();
				activate(rows[current]);
				break;
		}
	}

	function indexOfRow(entry: PaletteEntry): number {
		return rows.findIndex((row) => row.key === entry.key);
	}

	/**
	 * Activates a row. Navigate/Recent/Records rows `goto()` the target then
	 * close; Actions run first, then close; the escalation row stays open and
	 * re-runs the query app-wide. Records — child hits included — land on the
	 * aggregate root's page.
	 */
	function activate(entry: PaletteEntry | undefined) {
		if (!entry) return;
		if (entry.kind === 'escalate') {
			scope = 'app';
			searcher.query(entry.query ?? '', 'app', activeDomain);
			return;
		}
		if (entry.kind === 'action' && entry.command) {
			entry.command.run();
			open = false;
			return;
		}
		open = false;
		const domain = entry.domain ?? '';
		if (entry.kind === 'domain' && domain) {
			void goto(resolve('/[domain=notApi]', { domain }));
			return;
		}
		if (entry.doctype && entry.id) {
			void goto(
				resolve('/[domain=notApi]/[doctype]/[id]', {
					domain,
					doctype: entry.doctype,
					id: entry.id
				})
			);
			return;
		}
		if (entry.doctype && domain) {
			void goto(resolve('/[domain=notApi]/[doctype]', { domain, doctype: entry.doctype }));
		}
	}
</script>

<svelte:window onkeydown={handleGlobalKeydown} />

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="palette-overlay" />
		<Dialog.Content class="palette-content" onkeydown={handleContentKeydown}>
			<Dialog.Title class="palette-sronly">{m.palette_dialog_title()}</Dialog.Title>
			<Dialog.Description class="palette-sronly">{m.palette_dialog_desc()}</Dialog.Description>

			<div class="palette-head">
				<Search size={15} stroke-width={2} />
				<!-- ARIA combobox pattern (B-392): Bits UI supplies only the Dialog
				     here. Its Combobox primitive is a single-select value picker and
				     does not fit a grouped command list, so the input carries
				     hand-rolled combobox semantics: focus stays on the input, the
				     rows own `option` roles, and the highlight rides
				     `aria-activedescendant`. The arrow / Home / End / Enter handling
				     on the dialog content is unchanged. -->
				<input
					class="palette-input"
					type="text"
					role="combobox"
					aria-label={m.palette_input_label()}
					aria-autocomplete="list"
					aria-expanded={listOpen}
					aria-controls={listOpen ? 'palette-listbox' : undefined}
					aria-activedescendant={listOpen ? activeRow?.key : undefined}
					placeholder={searchPlaceholder}
					value={query}
					autocomplete="off"
					spellcheck="false"
					oninput={handleInput}
				/>
				{#if scope === 'app'}
					<button class="palette-chip" type="button" onclick={handleScopeBack}>
						{m.palette_scope_all_domains()}
					</button>
				{/if}
			</div>

			{#if groups.length > 0}
				<div class="palette-list" role="listbox" id="palette-listbox">
					{#each groups as group (group.id)}
						<!-- `group` is an owned element of `listbox` per ARIA 1.2; the
					     visible label names it. -->
						<section class="palette-group" role="group" aria-labelledby={`${group.id}-label`}>
							<div class="palette-group-label" id={`${group.id}-label`}>
								{paletteGroupLabel(group.id)}
							</div>
							{#each group.entries as entry (entry.key)}
								<button
									type="button"
									id={entry.key}
									class="palette-row"
									class:active={entry.key === activeRow?.key}
									role="option"
									aria-selected={entry.key === activeRow?.key}
									tabindex="-1"
									onclick={() => activate(entry)}
									onmouseenter={() => (activeIndex = indexOfRow(entry))}
								>
									<span class="palette-row-mark" aria-hidden="true">
										{#if entry.kind === 'domain'}
											<span class="palette-dot" style={`background:${entry.color}`}></span>
										{:else if entry.kind === 'escalate'}
											<Search size={13} stroke-width={2} />
										{:else if entry.kind === 'action' || entry.color || entry.icon}
											<!-- Actions always carry a mark: the command's icon, or
												DoctypeIcon's signature diamond when it has none. -->
											<DoctypeIcon icon={entry.icon} color={entry.color} size={12} />
										{/if}
									</span>
									<span class="palette-row-main">
										<span class="palette-row-label">{entry.label}</span>
										{#if entry.subtitle}
											<span class="palette-row-subtitle">{entry.subtitle}</span>
										{/if}
									</span>
									{#if entry.tag}
										<span class="palette-row-tag">{entry.tag}</span>
									{/if}
								</button>
							{/each}
						</section>
					{/each}
				</div>
			{:else if showEmpty}
				<div class="palette-empty" role="status">
					{m.palette_empty_results({ query: query.trim() })}
				</div>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.palette-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 120;
	}

	:global(.palette-content) {
		position: fixed;
		top: 14vh;
		left: 50%;
		transform: translateX(-50%);
		width: min(560px, 92vw);
		max-height: min(560px, 72vh);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 121;
		overflow: hidden;
	}

	/* Screen-reader-only title and description — the palette shows no chrome
	   of its own; the a11y tree still names the dialog. */
	:global(.palette-sronly) {
		position: absolute;
		width: 1px;
		height: 1px;
		margin: -1px;
		padding: 0;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
		border: 0;
	}

	.palette-head {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 12px 14px;
		border-bottom: 1px solid var(--border);
		color: var(--text-3);
		flex: none;
	}

	:global(.palette-input) {
		flex: 1;
		min-width: 0;
		border: none;
		outline: none;
		background: transparent;
		color: var(--text);
		font: inherit;
		font-size: 14px;
	}

	:global(.palette-input)::placeholder {
		color: var(--text-3);
	}

	/* The escalated-scope marker; clicking it returns to the active domain. */
	.palette-chip {
		flex: none;
		border: 1px solid var(--border-strong);
		border-radius: var(--r-pill);
		background: var(--accent-weak);
		color: var(--accent-ink);
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		padding: 3px 9px;
		cursor: pointer;
	}

	.palette-chip:hover {
		border-color: var(--accent-ink);
	}

	.palette-list {
		overflow-y: auto;
		padding: 6px 6px 10px;
		min-height: 0;
	}

	.palette-group {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.palette-group + .palette-group {
		margin-top: 8px;
	}

	.palette-group-label {
		padding: 6px 10px 4px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.palette-row {
		display: flex;
		align-items: center;
		gap: 9px;
		width: 100%;
		padding: 7px 10px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 13px;
		text-align: left;
		cursor: pointer;
	}

	.palette-row:hover,
	.palette-row.active {
		background: var(--sunken);
		color: var(--text);
	}

	.palette-row-mark {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 16px;
		flex: none;
		color: var(--text-3);
	}

	.palette-dot {
		width: 9px;
		height: 9px;
		border-radius: 50%;
		flex: none;
	}

	.palette-row-main {
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 0;
		flex: 1;
	}

	.palette-row-label {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.palette-row-subtitle {
		font-size: 11.5px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.palette-row-tag {
		flex: none;
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.palette-empty {
		padding: 22px 16px;
		font-size: 13px;
		color: var(--text-3);
		text-align: center;
	}
</style>
