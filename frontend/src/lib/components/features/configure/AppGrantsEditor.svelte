<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack } from 'svelte';
	import { Search, Lock } from '@lucide/svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import {
		PLAIN_LEVEL_OPTIONS,
		canonicalActions,
		clampChildLevel,
		clearChildrenExceedingParent,
		coreActionVerb,
		effectiveRequireds,
		hasExplicitGrant,
		isCoreActionName,
		levelActionNames,
		levelLabel,
		levelToActions,
		materialiseInherited,
		resolveEffectiveLevel,
		summarizeGrants,
		anySensitiveGranted,
		type PlainLevel
	} from '$lib/app/appGrantsMapping';
	import type { AppGrant, DoctypeCatalogueEntry } from '$lib/app/appTypes';
	import * as m from '$lib/paraglide/messages';
	import { SvelteMap } from 'svelte/reactivity';

	/**
	 * AppGrantsEditor — the plain-language permissions picker shared by the
	 * app wizard's permissions step and the app detail Grants tab.
	 *
	 * The parent owns the `grants` `$state` array and threads it in as a
	 * bindable prop. This component mutates the array in place (add/remove
	 * grant entries, change the level, flip `required`). Per the workflow
	 * doc's deep-mutation rule, the mutation handlers that touch a grant's
	 * `actions` live here so the derived summary — which depends on the same
	 * array — re-renders from the same scope.
	 *
	 * `mode` only affects chrome: `wizard` shows the explanation header;
	 * `edit` is bare so the Grants tab can render its own save controls.
	 *
	 * Inheritance is a frontend editor behaviour, not a backend grant-shape
	 * change: a child doctype with no explicit grant inherits its parent's
	 * effective level for display. Backend `RBAC::GrantResolver` does not
	 * implement inheritance — a child with no grant entry has no effective
	 * permission through the app token — so before save the editor calls
	 * `materialiseInherited` to expand every inherited-child display into an
	 * explicit grant entry. The `onchange` callback therefore receives the
	 * materialised grants array; the parent persists that array verbatim.
	 */

	type Props = {
		grants: AppGrant[];
		doctypeCatalogue: DoctypeCatalogueEntry[];
		mode?: 'wizard' | 'edit';
		onchange?: (grants: AppGrant[]) => void;
	};

	let { grants = $bindable(), doctypeCatalogue, mode = 'wizard', onchange }: Props = $props();

	// ── Catalogue tree ────────────────────────────────────────────────────────
	// Roots are doctypes with no parent. Children are grouped under their
	// parent's target. The catalogue stays flat on the wire; the tree is built
	// here so the editor can render nested children with inheritance.
	const childrenOf = $derived.by(() => {
		// untrack: interleaved get/set on a tracked map inside a derivation
		// self-dirties it and re-runs the derivation.
		return untrack(() => {
			const map = new SvelteMap<string, DoctypeCatalogueEntry[]>();
			for (const entry of doctypeCatalogue) {
				if (!entry.parentTarget) continue;
				const list = map.get(entry.parentTarget) ?? [];
				list.push(entry);
				map.set(entry.parentTarget, list);
			}
			return map;
		});
	});

	// ── Domain segmented rail ────────────────────────────────────────────────
	// One segment per domain, in catalogue order. The number is the count of
	// doctypes in that domain with a non-`none` effective level (inherited
	// counts as "has a grant somewhere in the subtree").
	const domains = $derived.by(() => {
		// untrack: same scratch-map rule as `childrenOf` above.
		return untrack(() => {
			const seen = new SvelteMap<string, DoctypeCatalogueEntry[]>();
			for (const entry of doctypeCatalogue) {
				const list = seen.get(entry.domain) ?? [];
				list.push(entry);
				seen.set(entry.domain, list);
			}
			return [...seen.entries()].map(([domain, entries]) => ({ domain, entries }));
		});
	});

	function domainGrantCount(entries: DoctypeCatalogueEntry[]): number {
		return entries.filter(
			(e) => resolveEffectiveLevel(grants, e.target, doctypeCatalogue) !== 'none'
		).length;
	}

	// Active domain is selected by clicking a rail segment. Defaults to the
	// first domain with grants, or the first domain overall.
	let activeDomain = $state<string | undefined>(undefined);
	$effect(() => {
		// Keep the active domain valid as the catalogue changes. If the
		// current selection has no entries (e.g. filtered out), fall back.
		if (activeDomain && !domains.some((d) => d.domain === activeDomain)) {
			activeDomain = domains[0]?.domain;
		} else if (!activeDomain) {
			const firstWithGrants = domains.find((d) => domainGrantCount(d.entries) > 0);
			activeDomain = firstWithGrants?.domain ?? domains[0]?.domain;
		}
	});

	const activeEntries = $derived(domains.find((d) => d.domain === activeDomain)?.entries ?? []);

	// ── Search ─────────────────────────────────────────────────────────────────
	// A plain text filter — not the async combobox pattern from the bits-ui
	// doc. Searching filters within the active domain; clearing the query
	// returns to the rail's active domain.
	let query = $state('');

	// Only roots are filtered directly; children of a matching root are still
	// shown (the inheritance context matters). A query that matches a child
	// also surfaces its root.
	const filteredRoots = $derived.by(() => {
		const q = query.trim().toLowerCase();
		const match = (e: DoctypeCatalogueEntry) =>
			e.label.toLowerCase().includes(q) ||
			e.target.toLowerCase().includes(q) ||
			e.description.toLowerCase().includes(q);
		if (!q) return activeEntries.filter((e) => e.parentTarget === undefined);
		return activeEntries
			.filter((e) => e.parentTarget === undefined)
			.filter((root) => {
				if (match(root)) return true;
				const kids = childrenOf.get(root.target) ?? [];
				return kids.some(match);
			});
	});

	// ── Grant resolution ───────────────────────────────────────────────────────
	function grantFor(target: string): AppGrant | undefined {
		return grants.find((g) => g.target === target);
	}

	function effectiveLevel(entry: DoctypeCatalogueEntry): PlainLevel {
		return resolveEffectiveLevel(grants, entry.target, doctypeCatalogue);
	}

	// The ceiling a child's level can reach: its parent's effective level.
	// Segments above this are greyed/disabled. Roots have no ceiling (full).
	function parentCeiling(entry: DoctypeCatalogueEntry): PlainLevel {
		if (!entry.parentTarget) return 'full';
		return resolveEffectiveLevel(grants, entry.parentTarget, doctypeCatalogue);
	}

	// ── Mutations ─────────────────────────────────────────────────────────────
	// All handlers that touch `grants[]` live here so the derived summary and
	// the rail counts re-render from the same scope as the mutations. After
	// every mutation, materialise inherited children into explicit grants
	// in place on the bound array, then emit through `onchange` so the parent
	// persists a grants array that matches the displayed levels and its
	// dirty-tracking fires.
	function emit(): void {
		const materialised = materialiseInherited(grants, doctypeCatalogue);
		// Splice in place so the parent's bound `$state` stays the source of
		// truth — both parents (wizard permissions step, detail grants tab)
		// persist the bound `grants` array, not the value passed to `onchange`.
		grants.splice(0, grants.length, ...materialised);
		onchange?.(grants);
	}

	function setLevel(entry: DoctypeCatalogueEntry, desired: PlainLevel): void {
		const level = clampChildLevel(desired, parentCeiling(entry));
		const idx = grants.findIndex((g) => g.target === entry.target);
		if (level === 'none') {
			if (idx >= 0) grants.splice(idx, 1);
		} else {
			// Preserve the per-action `required` flags the user already chose
			// and any named actions layered on top. The flags seed from the
			// effective grant (own entry first, else the inherited ancestor's)
			// so overriding an inherited level keeps the flags the picker
			// displayed.
			const requireds: Record<string, boolean> = { ...coreRequireds(entry) };
			const existing = idx >= 0 ? grants[idx] : null;
			const core = levelToActions(level, requireds);
			// Keep named actions that are not part of the core level. Canonical
			// core names (create/update) and the legacy `write` alias are core —
			// grants authored outside the editor arrive in the canonical shape.
			const named = existing?.actions.filter((a) => !isCoreActionName(a.name)) ?? [];
			const actions = [...core, ...named];
			if (idx >= 0) {
				grants[idx].actions = actions;
			} else {
				grants.push({ target: entry.target, actions });
			}
		}
		// When a parent's level drops, clear child grants that now exceed it.
		// When a parent rises, leave explicit child grants as they are — the
		// user opts in per child. Walking the parent's direct children is enough
		// because `clearChildrenExceedingParent` reads the parent's effective
		// level, which itself may inherit from a grandparent.
		const kids = childrenOf.get(entry.target) ?? [];
		if (kids.length > 0) {
			const next = clearChildrenExceedingParent(grants, entry.target, doctypeCatalogue);
			if (next.length !== grants.length) {
				grants.splice(0, grants.length, ...next);
			}
		}
		emit();
	}

	function bulkSetDomain(level: PlainLevel): void {
		for (const root of activeEntries.filter((e) => e.parentTarget === undefined)) {
			setLevel(root, level);
		}
	}

	function toggleRequired(target: string, actionName: string): void {
		const grant = grantFor(target);
		if (!grant) return;
		const action = grant.actions.find((a) => a.name === actionName);
		if (!action) return;
		action.required = !action.required;
		emit();
	}

	// ── Core required flags ────────────────────────────────────────────────
	// The required flags the picker displays for a doctype: the explicit
	// entry's flags, or — for an inherited child — the flags of the nearest
	// ancestor grant (the same walk the effective level uses).
	function coreRequireds(entry: DoctypeCatalogueEntry): Record<string, boolean> {
		return effectiveRequireds(grants, entry.target, doctypeCatalogue);
	}

	// Flips one core action's required flag. Mirrors `setLevel`'s merge: the
	// level owns membership, the flags ride along. An inherited child (no
	// explicit entry, or a named-only one) materialises its core actions on
	// first touch — override-on-touch, the same rule the level segments
	// follow.
	function toggleCoreRequired(entry: DoctypeCatalogueEntry, actionName: string): void {
		const level = effectiveLevel(entry);
		if (level === 'none') return; // the row renders only above none
		const idx = grants.findIndex((g) => g.target === entry.target);
		const requireds: Record<string, boolean> = { ...coreRequireds(entry) };
		requireds[actionName] = !requireds[actionName];
		const core = levelToActions(level, requireds);
		const named = idx >= 0 ? grants[idx].actions.filter((a) => !isCoreActionName(a.name)) : [];
		const actions = [...core, ...named];
		if (idx >= 0) {
			// Replace through splice, not a deep property write: `emit()` already
			// rebuilds entries as fresh objects, so identity was never a
			// contract, and a deep write on the array trips Svelte's
			// ownership guard when the editor renders over unbound props.
			grants.splice(0, grants.length, ...grants.map((g, i) => (i === idx ? { ...g, actions } : g)));
		} else {
			grants.push({ target: entry.target, actions });
		}
		emit();
	}

	function toggleNamedAction(
		entry: DoctypeCatalogueEntry,
		namedAction: { name: string; label: string }
	): void {
		let grant = grantFor(entry.target);
		if (!grant) {
			// Adding a named action implicitly creates a core grant so the
			// summary makes sense ("export contacts" implies "see contacts").
			// The base is the entry's effective level with its effective flags —
			// for an inherited child that preserves the displayed level and its
			// required flags instead of demoting the entry to a bare optional
			// read. (The pills render only above none, so the base is never
			// `none` in practice; levelToActions returns [] and the named action
			// still lands.)
			const base = clampChildLevel(effectiveLevel(entry), parentCeiling(entry));
			grant = { target: entry.target, actions: levelToActions(base, coreRequireds(entry)) };
			grants.push(grant);
		}
		const existing = grant.actions.find((a) => a.name === namedAction.name);
		if (existing) {
			grant.actions = grant.actions.filter((a) => a.name !== namedAction.name);
		} else {
			grant.actions.push({ name: namedAction.name, required: false });
		}
		if (grant.actions.length === 0) {
			const idx = grants.findIndex((g) => g === grant);
			if (idx >= 0) grants.splice(idx, 1);
		}
		emit();
	}

	function namedActionActive(entry: DoctypeCatalogueEntry, name: string): boolean {
		return Boolean(grantFor(entry.target)?.actions.some((a) => a.name === name));
	}

	function namedActionRequired(entry: DoctypeCatalogueEntry, name: string): boolean {
		return Boolean(grantFor(entry.target)?.actions.find((a) => a.name === name)?.required);
	}

	// ── Segmented control helpers ─────────────────────────────────────────────
	function isSegmentDisabled(entry: DoctypeCatalogueEntry, level: PlainLevel): boolean {
		if (level === 'none') return false;
		return LEVEL_RANK[level] > LEVEL_RANK[parentCeiling(entry)];
	}

	const LEVEL_RANK: Record<PlainLevel, number> = { none: -1, read: 0, write: 1, full: 2 };

	// ── Summary ────────────────────────────────────────────────────────────────
	const summaryGroups = $derived(summarizeGrants(grants, doctypeCatalogue));
	const grantedCount = $derived(
		doctypeCatalogue.filter((e) => effectiveLevel(e) !== 'none').length
	);
	const grantedDomainCount = $derived(
		new Set(doctypeCatalogue.filter((e) => effectiveLevel(e) !== 'none').map((e) => e.domain)).size
	);
	// Distinct canonical action names across the grants — the `write` alias
	// counts as its create/update pair, so legacy and canonical grants total
	// the same way.
	const actionCount = $derived(
		new Set(
			(Array.isArray(grants) ? grants : []).flatMap((g) =>
				canonicalActions(g.actions ?? []).map((a) => a.name)
			)
		).size
	);
	const hasSensitive = $derived(anySensitiveGranted(grants, doctypeCatalogue));
</script>

<div class="grants-editor" data-mode={mode}>
	{#if mode === 'wizard'}
		<header class="grants-head">
			<h2>{m.apps_grants_wizard_title()}</h2>
			<p class="muted">{m.apps_grants_wizard_helper()}</p>
		</header>
	{/if}

	<div class="grants-toolbar">
		<div class="grants-rail" role="tablist" aria-label={m.apps_grants_domains_aria()}>
			{#each domains as d (d.domain)}
				{@const count = domainGrantCount(d.entries)}
				<button
					type="button"
					role="tab"
					class="grants-rail-segment"
					class:grants-rail-segment-active={d.domain === activeDomain}
					aria-selected={d.domain === activeDomain}
					onclick={() => (activeDomain = d.domain)}
				>
					<span class="grants-rail-label">{d.domain}</span>
					{#if count > 0}
						<span class="grants-rail-count">{count}</span>
					{/if}
				</button>
			{/each}
		</div>
		<div class="grants-search">
			<Search size={15} strokeWidth={1.9} aria-hidden="true" />
			<input
				type="text"
				placeholder={m.apps_grants_filter_placeholder()}
				bind:value={query}
				class="grants-search-input"
				aria-label={m.apps_grants_filter_aria()}
			/>
		</div>
	</div>

	{#if activeDomain}
		<div class="grants-bulk">
			<span class="grants-bulk-label">{m.apps_grants_set_all_label({ domain: activeDomain })}</span>
			{#each PLAIN_LEVEL_OPTIONS as opt (opt.value)}
				<button type="button" class="grants-bulk-button" onclick={() => bulkSetDomain(opt.value)}>
					{levelLabel(opt.value)}
				</button>
			{/each}
		</div>
	{/if}

	<div class="grants-cards">
		{#each filteredRoots as root (root.target)}
			{@const level = effectiveLevel(root)}
			{@const kids = childrenOf.get(root.target) ?? []}
			<div class="grants-card" class:grants-card-active={level !== 'none'}>
				<div class="grants-card-head">
					<div class="grants-card-meta">
						<div class="grants-card-label">
							{root.label}
							{#if root.sensitive}
								<Lock
									size={14}
									strokeWidth={2}
									class="grants-card-sensitive"
									aria-label={m.apps_grants_sensitive_aria()}
								/>
							{/if}
						</div>
						<div class="grants-card-desc">{root.description}</div>
					</div>
					<div
						class="grants-segmented"
						role="group"
						aria-label={m.apps_grants_access_aria({ name: root.label })}
					>
						{#each PLAIN_LEVEL_OPTIONS as opt (opt.value)}
							{@const disabled = isSegmentDisabled(root, opt.value)}
							<button
								type="button"
								class="grants-segment"
								class:grants-segment-on={level === opt.value}
								class:grants-segment-disabled={disabled}
								aria-pressed={level === opt.value}
								{disabled}
								onclick={() => setLevel(root, opt.value)}
							>
								{levelLabel(opt.value)}
							</button>
						{/each}
					</div>
				</div>

				{#if level !== 'none'}
					{@const requireds = coreRequireds(root)}
					<div class="grants-required-row">
						<span class="grants-required-label">{m.apps_grants_core_required_label()}</span>
						<div class="grants-required-pills">
							{#each levelActionNames(level) as actionName (actionName)}
								{@const required = Boolean(requireds[actionName])}
								<span class="grants-required-pill" class:grants-required-pill-on={required}>
									<span class="grants-required-verb">{coreActionVerb(actionName)}</span>
									<Toggle
										checked={required}
										aria-label={coreActionVerb(actionName)}
										onchange={() => toggleCoreRequired(root, actionName)}
									/>
									<span class="grants-required-state"
										>{required ? m.apps_grants_required() : m.apps_grants_optional()}</span
									>
								</span>
							{/each}
						</div>
					</div>
				{/if}

				{#if level !== 'none' && root.namedActions && root.namedActions.length > 0}
					<div class="grants-card-named">
						<div class="grants-card-named-label">{m.apps_grants_named_label()}</div>
						<div class="grants-named-pills">
							{#each root.namedActions as namedAction (namedAction.name)}
								{@const active = namedActionActive(root, namedAction.name)}
								<span class="grants-named-pill" class:grants-named-pill-on={active}>
									<button
										type="button"
										class="grants-named-pill-toggle"
										aria-pressed={active}
										onclick={() => toggleNamedAction(root, namedAction)}
									>
										{namedAction.label}
									</button>
									{#if active}
										<label class="grants-named-pill-required">
											<Toggle
												checked={namedActionRequired(root, namedAction.name)}
												onchange={() => toggleRequired(root.target, namedAction.name)}
											/>
											<span
												>{namedActionRequired(root, namedAction.name)
													? m.apps_grants_required()
													: m.apps_grants_optional()}</span
											>
										</label>
									{/if}
								</span>
							{/each}
						</div>
					</div>
				{/if}

				{#if kids.length > 0}
					<div class="grants-children">
						<div class="grants-children-label">
							{m.apps_grants_children_label({ root: root.label })}
						</div>
						{#each kids as child (child.target)}
							{@const childLevel = effectiveLevel(child)}
							<div class="grants-child">
								<div class="grants-child-meta">
									<div class="grants-child-label">{child.label}</div>
									<div class="grants-child-desc">{child.description}</div>
								</div>
								<div class="grants-child-status">
									{#if hasExplicitGrant(grants, child.target)}
										<span class="grants-child-tag grants-child-tag-overridden">
											{m.apps_grants_tag_overridden({ level: levelLabel(childLevel) })}
										</span>
									{:else if childLevel !== 'none'}
										<span class="grants-child-tag grants-child-tag-inherited">
											{m.apps_grants_tag_inherited({ level: levelLabel(childLevel) })}
										</span>
									{:else}
										<span class="grants-child-tag grants-child-tag-none">
											{m.apps_grants_tag_none_inherited()}
										</span>
									{/if}
								</div>
								<div
									class="grants-segmented grants-segmented-sm"
									role="group"
									aria-label={m.apps_grants_access_aria({ name: child.label })}
								>
									{#each PLAIN_LEVEL_OPTIONS as opt (opt.value)}
										{@const disabled = isSegmentDisabled(child, opt.value)}
										<button
											type="button"
											class="grants-segment"
											class:grants-segment-on={childLevel === opt.value}
											class:grants-segment-disabled={disabled}
											aria-pressed={childLevel === opt.value}
											{disabled}
											onclick={() => setLevel(child, opt.value)}
										>
											{levelLabel(opt.value)}
										</button>
									{/each}
								</div>
								{#if childLevel !== 'none'}
									{@const childRequireds = coreRequireds(child)}
									<div class="grants-required-row grants-required-row-compact">
										<div class="grants-required-pills">
											{#each levelActionNames(childLevel) as actionName (actionName)}
												{@const required = Boolean(childRequireds[actionName])}
												<span class="grants-required-pill" class:grants-required-pill-on={required}>
													<span class="grants-required-verb">{coreActionVerb(actionName)}</span>
													<Toggle
														checked={required}
														aria-label={coreActionVerb(actionName)}
														onchange={() => toggleCoreRequired(child, actionName)}
													/>
													<span class="grants-required-state"
														>{required ? m.apps_grants_required() : m.apps_grants_optional()}</span
													>
												</span>
											{/each}
										</div>
									</div>
									{#if child.namedActions && child.namedActions.length > 0}
										<div class="grants-card-named grants-child-named">
											<div class="grants-card-named-label">{m.apps_grants_named_label()}</div>
											<div class="grants-named-pills">
												{#each child.namedActions as namedAction (namedAction.name)}
													{@const active = namedActionActive(child, namedAction.name)}
													<span class="grants-named-pill" class:grants-named-pill-on={active}>
														<button
															type="button"
															class="grants-named-pill-toggle"
															aria-pressed={active}
															onclick={() => toggleNamedAction(child, namedAction)}
														>
															{namedAction.label}
														</button>
														{#if active}
															<label class="grants-named-pill-required">
																<Toggle
																	checked={namedActionRequired(child, namedAction.name)}
																	onchange={() => toggleRequired(child.target, namedAction.name)}
																/>
																<span
																	>{namedActionRequired(child, namedAction.name)
																		? m.apps_grants_required()
																		: m.apps_grants_optional()}</span
																>
															</label>
														{/if}
													</span>
												{/each}
											</div>
										</div>
									{/if}
								{/if}
							</div>
						{/each}
					</div>
				{/if}
			</div>
		{/each}

		{#if filteredRoots.length === 0}
			<div class="grants-empty">
				{#if query.trim()}
					{m.apps_grants_empty_match({ query })}
					<button type="button" class="grants-empty-clear" onclick={() => (query = '')}
						>{m.apps_grants_empty_clear()}</button
					>
				{:else if activeDomain}
					{m.apps_grants_empty_domain({ domain: activeDomain })}
				{:else}
					{m.apps_grants_empty()}
				{/if}
			</div>
		{/if}
	</div>

	{#if summaryGroups.length > 0}
		<div class="grants-summary">
			<div class="grants-summary-label">{m.apps_grants_summary_label()}</div>
			<div class="grants-summary-groups">
				{#each summaryGroups as group (group.kind + ':' + group.verb)}
					<div class="grants-summary-group">
						<span class="grants-summary-verb">{group.verb}</span>
						{#if group.kind === 'core' && group.targets.length > 0}
							<span class="grants-summary-nouns">
								{group.targets[0]}
								{#if group.targets.length > 1}
									{#each group.targets.slice(1, -1) as noun (noun)}<span>, {noun}</span>{/each}
									<span> and {group.targets[group.targets.length - 1]}</span>
								{/if}
							</span>
						{/if}
						{#if group.optional}
							<span class="grants-summary-optional">{m.apps_grants_optional()}</span>
						{/if}
					</div>
				{/each}
			</div>
			<div class="grants-summary-footer">
				<span>
					{grantedDomainCount === 1 && actionCount === 1
						? m.apps_grants_summary_counts_ss({
								doctypes: grantedCount,
								domains: grantedDomainCount,
								actions: actionCount
							})
						: grantedDomainCount === 1 && actionCount !== 1
							? m.apps_grants_summary_counts_sp({
									doctypes: grantedCount,
									domains: grantedDomainCount,
									actions: actionCount
								})
							: grantedDomainCount !== 1 && actionCount === 1
								? m.apps_grants_summary_counts_ps({
										doctypes: grantedCount,
										domains: grantedDomainCount,
										actions: actionCount
									})
								: m.apps_grants_summary_counts_pp({
										doctypes: grantedCount,
										domains: grantedDomainCount,
										actions: actionCount
									})}
				</span>
				<span class="grants-summary-tail">{m.apps_grants_summary_tail()}</span>
			</div>
			{#if hasSensitive}
				<div class="grants-summary-sensitive">{m.apps_grants_summary_sensitive()}</div>
			{/if}
		</div>
	{/if}
</div>

<style>
	.grants-editor {
		display: flex;
		flex-direction: column;
		gap: 14px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		background: var(--surface-2);
		overflow: hidden;
	}

	.grants-head {
		padding: 16px 20px 12px;
		border-bottom: 1px solid var(--border);
	}

	.grants-head h2 {
		font-size: 15px;
		font-weight: 500;
		margin: 0 0 4px;
		color: var(--text);
	}

	.muted {
		font-size: 13px;
		color: var(--text-3);
		line-height: 1.6;
		margin: 0;
	}

	/* ── Toolbar: domain rail + search ─────────────────────────────────────── */

	.grants-toolbar {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 12px 16px 0;
		flex-wrap: wrap;
	}

	.grants-rail {
		display: flex;
		gap: 2px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 3px;
		flex-wrap: wrap;
	}

	.grants-rail-segment {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 5px 11px;
		border: none;
		background: transparent;
		color: var(--text-3);
		font: inherit;
		font-size: 12.5px;
		border-radius: 5px;
		cursor: pointer;
		text-transform: capitalize;
	}

	.grants-rail-segment:hover {
		color: var(--text);
	}

	.grants-rail-segment-active {
		background: var(--surface-2);
		color: var(--text);
		font-weight: 500;
	}

	.grants-rail-count {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--accent);
	}

	.grants-search {
		display: flex;
		align-items: center;
		gap: 8px;
		flex: 1;
		min-width: 140px;
		color: var(--text-3);
	}

	.grants-search-input {
		flex: 1;
		min-width: 0;
		padding: 7px 10px;
		font: inherit;
		font-size: 13px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
	}

	.grants-search-input:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	/* ── Bulk-set row ─────────────────────────────────────────────────────── */

	.grants-bulk {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 0 16px;
		flex-wrap: wrap;
		font-size: 12.5px;
		color: var(--text-3);
	}

	.grants-bulk-label {
		text-transform: capitalize;
	}

	.grants-bulk-button {
		height: 26px;
		padding: 0 10px;
		font: inherit;
		font-size: 12px;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
	}

	.grants-bulk-button:hover {
		border-color: var(--accent);
		color: var(--text);
	}

	/* ── Doctype cards ────────────────────────────────────────────────────── */

	.grants-cards {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 0 16px;
	}

	.grants-card {
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		padding: 12px 14px;
		background: var(--surface);
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.grants-card-active {
		border-color: var(--accent);
		background: var(--accent-weak, var(--surface));
	}

	.grants-card-head {
		display: flex;
		align-items: flex-start;
		gap: 12px;
	}

	.grants-card-meta {
		flex: 1;
		min-width: 0;
	}

	.grants-card-label {
		font-size: 14px;
		font-weight: 500;
		color: var(--text);
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}

	/* The lock icon is a Lucide component; its SVG is not scoped by Svelte,
	   so the colour must target it via :global(). */
	:global(.grants-card-sensitive) {
		color: var(--warn, #d97706);
		vertical-align: -2px;
	}

	.grants-card-desc {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 2px;
	}

	/* ── Segmented control ────────────────────────────────────────────────── */

	.grants-segmented {
		display: inline-flex;
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
		flex-shrink: 0;
	}

	.grants-segment {
		padding: 5px 10px;
		font: inherit;
		font-size: 12px;
		color: var(--text-3);
		background: var(--surface);
		border: none;
		border-left: 1px solid var(--border);
		cursor: pointer;
	}

	.grants-segment:first-child {
		border-left: none;
	}

	.grants-segment:hover:not(:disabled) {
		color: var(--text);
	}

	.grants-segment-on {
		background: var(--accent);
		color: var(--on-accent);
	}

	.grants-segment-disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.grants-segmented-sm .grants-segment {
		padding: 4px 8px;
		font-size: 11.5px;
	}

	/* ── Named actions (Extra abilities) ─────────────────────────────────── */

	.grants-card-named {
		padding-top: 8px;
		border-top: 1px solid var(--border);
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	.grants-card-named-label {
		font-size: 11px;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	.grants-named-pills {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.grants-named-pill {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 3px 4px 3px 9px;
		border-radius: 999px;
		border: 1px solid var(--border);
		background: var(--surface);
		font-size: 12.5px;
	}

	.grants-named-pill-on {
		border-color: var(--accent);
		background: var(--accent-weak);
	}

	.grants-named-pill-toggle {
		border: none;
		background: transparent;
		font: inherit;
		font-size: 12px;
		color: var(--text-2);
		cursor: pointer;
		padding: 0;
	}

	.grants-named-pill-on .grants-named-pill-toggle {
		color: var(--text);
	}

	.grants-named-pill-required {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	/* ── Core required flags ───────────────────────────────────────────── */
	.grants-required-row {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px 10px;
		padding-top: 8px;
		border-top: 1px solid var(--border);
	}

	.grants-required-label {
		font-size: 11px;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	.grants-required-pills {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.grants-required-pill {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 3px 9px;
		border-radius: 999px;
		border: 1px solid var(--border);
		background: var(--surface);
		font-size: 12.5px;
	}

	.grants-required-pill-on {
		border-color: var(--accent);
		background: var(--accent-weak);
	}

	.grants-required-verb {
		color: var(--text-2);
	}

	.grants-required-pill-on .grants-required-verb {
		color: var(--text);
	}

	.grants-required-state {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	/* Children keep the pills but drop the separator — the row sits directly
	   under the child's own segmented control, inside its bordered row. */
	.grants-child .grants-required-row-compact {
		padding-top: 2px;
		border-top: none;
	}

	/* The named-action block mirrors the root card's, minus the separator —
	   the child row already separates its segments from the required row. */
	.grants-child .grants-child-named {
		padding-top: 2px;
		border-top: none;
	}

	/* ── Children (nested) ───────────────────────────────────────────────── */

	.grants-children {
		margin-top: 4px;
		padding-left: 12px;
		border-left: 2px solid var(--border);
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.grants-children-label {
		font-size: 11px;
		color: var(--text-3);
		margin-bottom: 4px;
	}

	.grants-child {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 6px 0;
		flex-wrap: wrap;
	}

	.grants-child + .grants-child {
		border-top: 1px solid var(--border);
	}

	.grants-child-meta {
		flex: 1;
		min-width: 0;
	}

	.grants-child-label {
		font-size: 13px;
		color: var(--text);
	}

	.grants-child-desc {
		font-size: 11.5px;
		color: var(--text-3);
		margin-top: 1px;
	}

	.grants-child-tag {
		font-size: 11px;
		padding: 3px 8px;
		border-radius: 999px;
		flex-shrink: 0;
	}

	.grants-child-tag-inherited {
		background: var(--accent-weak);
		color: var(--accent);
	}

	.grants-child-tag-overridden {
		border: 1px solid var(--border);
		color: var(--text-2);
	}

	.grants-child-tag-none {
		color: var(--text-3);
	}

	/* ── Empty state ─────────────────────────────────────────────────────── */

	.grants-empty {
		padding: 20px 16px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
	}

	.grants-empty-clear {
		background: none;
		border: none;
		color: var(--accent);
		cursor: pointer;
		font: inherit;
		text-decoration: underline;
	}

	/* ── Summary ─────────────────────────────────────────────────────────── */

	.grants-summary {
		margin: 0 16px 14px;
		padding: 13px 15px;
		background: var(--surface);
		border-radius: var(--r-lg, 12px);
	}

	.grants-summary-label {
		font-size: 12.5px;
		font-weight: 500;
		margin-bottom: 8px;
		color: var(--text-2);
	}

	.grants-summary-groups {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.grants-summary-group {
		font-size: 13px;
		color: var(--text);
	}

	.grants-summary-verb {
		font-weight: 500;
		margin-right: 4px;
	}

	.grants-summary-optional {
		margin-left: 6px;
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	.grants-summary-footer {
		margin-top: 10px;
		padding-top: 8px;
		border-top: 1px solid var(--border);
		font-size: 12px;
		color: var(--text-3);
		display: flex;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: 6px;
	}

	.grants-summary-tail {
		color: var(--text-3);
	}

	.grants-summary-sensitive {
		margin-top: 6px;
		font-size: 11.5px;
		color: var(--warn, #d97706);
	}
</style>
