<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Button from '../../primitives/actions/Button.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import HoverHint from '../../primitives/content/HoverHint.svelte';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { Trash2, Plus, ExternalLink } from '@lucide/svelte';
	import { untrack } from 'svelte';
	import { SvelteSet } from 'svelte/reactivity';

	import RbacDoctypeTree from './RbacDoctypeTree.svelte';
	import {
		buildTree,
		loadState,
		serializeState,
		roleOptions,
		filterTree,
		deriveExpandedKeys,
		descendantCount,
		emptyRow,
		type DoctypeNode,
		type EditorState,
		type ScopeValue,
		type RoleContent,
		type PermissionRaw
	} from './rbacModel.js';
	import { humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import { CONNECTIVITY_CHANNELS } from '$lib/iam/content.js';
	import { resolve } from '$app/paths';
	import { confirm } from '$lib/confirm.svelte';
	import { setUnsavedEditsGate, clearUnsavedEditsGate } from '$lib/unsavedEdits.js';
	import * as m from '$lib/paraglide/messages';

	let {
		registry,
		domains = [],
		roles = [],
		selectedRoleId = $bindable(''),
		onsave,
		onnew,
		ondelete,
		memberCountByRoleName = new Map<string, number>(),
		assignmentsRoute = '/Configure/access/assignments'
	}: {
		/** Map of `{domain}.{Doctype}` → doctype definition record. */
		registry: Map<string, Record<string, unknown>>;
		/** Domain docs (`core.Domain` list items) for colour / description. */
		domains?: { id: string; data: Record<string, unknown> }[];
		/** Roles (`iam.Roles` list items) for the picker. The connectivity and
		 * budget fields drive the read-only powers strip under the role bar. */
		roles?: {
			data: {
				name?: string;
				description?: string;
				connectivity?: string[];
				assistant_token_budget?: number | null;
			};
		}[];
		/** Selected role id (name). Bindable so a host page can drive it
		 * (e.g. deep-link via `?role=` and stay in sync with the URL).
		 * When changed, state is reloaded. */
		selectedRoleId?: string;
		/** Persist the role's permissions. The host resolves the role document
		 * (iam.Roles, keyed by `name`) and issues a document `update` replacing
		 * the `permissions` field with the serialized array. Resolving allows the
		 * editor to clear its dirty flag. Reject to surface a save error. */
		onsave?: (roleName: string, permissions: PermissionRaw[]) => Promise<void>;
		/** Open the host's new-role dialog. No payload — the host owns the
		 * creation flow and refreshes `roles` + `selectedRoleId` on success. */
		onnew?: () => void;
		/** Delete the named role. The host issues the delete mutation, refreshes
		 * `roles`, and clears `selectedRoleId` when the deleted role was current.
		 * Rejects to surface an error (e.g. the backend Lua guard refusing the
		 * delete because accounts still hold the role). */
		ondelete?: (roleName: string) => Promise<void>;
		/** Member counts per role `name`, derived from `iam.Account.roles`
		 * membership by the host. Drives the inline badge and the delete guard
		 * (a role with members cannot be deleted — the backend Lua hook enforces
		 * the same rule). */
		memberCountByRoleName?: Map<string, number>;
		/** Route to the role-to-account assignment page. Surfaced as a "Manage"
		 * link beside the member count so users can act on the count. */
		assignmentsRoute?: string;
	} = $props();

	// ── Tree build ─────────────────────────────────────────────────────────
	// Build once per registry + domains change; this is a derived value, never
	// mutated in place by the editor.
	const tree = $derived.by(() => {
		const built = buildTree(registry);
		if (domains.length === 0) return built;
		const byId = new Map(domains.map((d) => [d.id, d.data]));
		return built.map((d) => {
			const data = byId.get(d.domain) ?? {};
			return {
				...d,
				color: typeof data.color === 'string' ? data.color : undefined,
				description: typeof data.description === 'string' ? data.description : undefined
			};
		});
	});

	// ── Search ───────────────────────────────────────────────────────────────
	// Filtering affects only what is rendered — `editorState` and `expanded`
	// are untouched, so clearing the search restores the original view. See
	// `filterTree` for the inclusion rules (match → keep subtree; nested
	// ancestor kept as scaffolding when a descendant matches).
	let search = $state('');

	const filteredTree = $derived(filterTree(tree, search));

	// ── Editor state ────────────────────────────────────────────────────────
	const emptyState: EditorState = {};

	// Loaded role content — driven by selectedRoleId + roles prop.
	const loadedRole = $derived.by<RoleContent | null>(() => {
		if (!selectedRoleId) return null;
		const role = roles.find((r) => (r.data.name ?? '') === selectedRoleId);
		if (!role) return null;
		return role.data as unknown as RoleContent;
	});

	// When the selected role changes, reload editorState from its permissions.
	const loadedState = $derived.by<EditorState>(() => {
		if (!loadedRole) return structuredClone(emptyState);
		return loadState(loadedRole);
	});

	// ── Accordion state ────────────────────────────────────────────────────
	// On reload, only the smallest subtree exposing every doctype the role
	// touches is expanded — so with 500+ definitions the user isn't drowned.
	// Domain keys are stored with a `domain:` prefix so they don't collide with
	// doctype qualified keys (`production.Project` etc.).
	const DOMAIN_KEY_PREFIX = 'domain:';
	function domainKey(name: string): string {
		return `${DOMAIN_KEY_PREFIX}${name}`;
	}

	const defaultExpanded = $derived(deriveExpandedKeys(tree, loadedState));
	let expanded = $state<Set<string>>(new Set());
	let userToggled = $state(false);
	let editorState = $state<EditorState>(structuredClone(emptyState));

	// The role whose permissions currently live in `editorState`. The reload
	// effect below keys on this, NOT on `loadedState` directly, so an unrelated
	// refresh of the same role's data (e.g. host invalidation) does not silently
	// discard the user's in-progress edits — only an explicit role switch does.
	let committedRoleId = $state<string>('');

	// Reset to defaults whenever the committed role changes — but only until
	// the user manually toggles something (then leave them alone).
	$effect(() => {
		if (committedRoleId !== selectedRoleId) {
			committedRoleId = selectedRoleId;
			editorState = structuredClone(loadedState);
			userToggled = false;
		}
		const next = untrack(() => new SvelteSet(defaultExpanded));
		// Auto-expand whichever domain contains a touched doctype, so the
		// accordion's top-level shape matches the role's footprint.
		for (const k of defaultExpanded) {
			const segs = k.split('.');
			if (segs.length >= 2) untrack(() => next.add(domainKey(segs[0])));
		}
		if (!userToggled) expanded = next;
	});

	function toggleExpand(qualified: string) {
		userToggled = true;
		// untrack: the scratch set is written and read in one handler — a tracked
		// read + the add/delete write would self-dirty it.
		const next = untrack(() => {
			const set = new SvelteSet(expanded);
			if (set.has(qualified)) set.delete(qualified);
			else set.add(qualified);
			return set;
		});
		expanded = next;
	}

	function toggleDomain(name: string) {
		toggleExpand(domainKey(name));
	}

	function isDomainExpanded(name: string): boolean {
		return expanded.has(domainKey(name));
	}

	function expandAll() {
		userToggled = true;
		// untrack: see toggleExpand.
		const next = untrack(() => {
			const set = new SvelteSet(expanded);
			for (const domain of filteredTree) {
				set.add(domainKey(domain.domain));
				for (const root of domain.roots) addSubtreeKeys(root, set);
			}
			return set;
		});
		expanded = next;
	}

	function collapseAll() {
		userToggled = true;
		expanded = new Set();
	}

	function addSubtreeKeys(node: DoctypeNode, acc: Set<string>) {
		acc.add(node.qualified);
		for (const child of node.children) addSubtreeKeys(child, acc);
	}

	// ── Domain counts ──────────────────────────────────────────────────────
	// Total + touched doctype counts per domain, shown in the header so the
	// user can scan the role's footprint per domain at a glance.
	function countDoctypes(roots: DoctypeNode[]): number {
		let n = 0;
		for (const root of roots) n += 1 + descendantCount(root);
		return n;
	}

	function countTouched(roots: DoctypeNode[], state: EditorState): number {
		let n = 0;
		function walk(node: DoctypeNode) {
			const v = state[node.qualified];
			if (v) {
				// Any action (custom or canonical) with a non-empty scope set counts.
				const any = Object.entries(v).some(([, val]) => Array.isArray(val) && val.length > 0);
				if (any) n += 1;
			}
			for (const child of node.children) walk(child);
		}
		for (const root of roots) walk(root);
		return n;
	}

	// ── Mutation handler ─────────────────────────────────────────────────────
	function setScope(qualified: string, action: string, value: ScopeValue[]) {
		const current = editorState[qualified] ?? emptyRow();
		editorState = {
			...editorState,
			[qualified]: { ...current, [action]: value }
		};
	}

	// ── Derived outputs ─────────────────────────────────────────────────────
	const serialized = $derived(serializeState(editorState));
	// The saved snapshot for the committed role — used to derive `dirty`. Held
	// as a serialized string so deep-equality is cheap and stable (object key
	// order is normalised by `serializeState`).
	const savedSerialized = $derived(JSON.stringify(serializeState(loadedState)));
	const dirty = $derived(JSON.stringify(serialized) !== savedSerialized);

	const roleOpts = $derived(roleOptions(roles));
	const visibleTags = $derived(loadedRole?.visible_tags ?? []);
	const isWildcard = $derived(
		(loadedRole?.permissions ?? []).some((p) => p.action === '*' && p.on === '*.*')
	);

	// ── Role powers strip ───────────────────────────────────────────────────
	// Read-only mirror of the role's programmatic powers (connectivity channels
	// + assistant token cap). The Details tab owns the write surface; this strip
	// only shows state, so a grants author sees what the role may open. A
	// missing or empty list reads as all-off — the same fail-closed default the
	// backend enforces.
	const connectivity = $derived(loadedRole?.connectivity ?? []);
	const assistantEnabled = $derived(connectivity.includes('assistant'));
	const budget = $derived(loadedRole?.assistant_token_budget ?? null);

	// ── Role switching + persistence ─────────────────────────────────────────
	// The picker writes to `pendingRoleId` first, never directly to the bound
	// `selectedRoleId`. If the working copy is dirty, switching is gated behind
	// a confirm so unsaved edits are never lost silently. On cancel, the picker
	// snaps back to the committed role.
	let pendingRoleId = $state('');
	$effect(() => {
		// Keep the picker in sync with external changes (URL deep-link, save →
		// host refresh, …). One-way: the picker's own selection flows through
		// `handleRoleChange`, not back through here.
		if (pendingRoleId !== selectedRoleId) pendingRoleId = selectedRoleId;
	});

	async function handleRoleChange(next: string) {
		if (next === selectedRoleId) return;
		if (
			dirty &&
			!(await confirm({
				title: m.admin_confirm_discard_title(),
				message: m.admin_confirm_discard_switch({
					current: humanizeRoleName(selectedRoleId),
					next: humanizeRoleName(next)
				}),
				confirmLabel: m.admin_discard_button(),
				variant: 'danger'
			}))
		) {
			// Revert the picker to the committed role.
			pendingRoleId = selectedRoleId;
			return;
		}
		selectedRoleId = next;
	}

	let saving = $state(false);
	let saveError = $state<string | undefined>(undefined);

	async function save() {
		if (!selectedRoleId || saving || !onsave) return;
		saving = true;
		saveError = undefined;
		try {
			await onsave(selectedRoleId, serialized);
			// The host refreshes the `roles` prop on success; when it lands,
			// `loadedState` recomputes to match `editorState` and `dirty` clears.
		} catch (err) {
			saveError = errorMessage(err);
		} finally {
			saving = false;
		}
	}

	async function discard() {
		if (!dirty) return;
		if (
			!(await confirm({
				title: m.admin_confirm_discard_title(),
				message: m.admin_confirm_discard_message({ current: humanizeRoleName(selectedRoleId) }),
				confirmLabel: m.admin_discard_button(),
				variant: 'danger'
			}))
		)
			return;
		editorState = structuredClone(loadedState);
		saveError = undefined;
	}

	// ── Unsaved-edits gate ──────────────────────────────────────────────────
	// The role-detail layout asks the gate before a tab navigation; the
	// shared beforeunload handler arms the browser's leave dialog for close
	// and refresh (both host pages benefit). The editor's internal flows —
	// the picker switch and delete — keep their own confirms.
	const unsavedGate = () => dirty;
	$effect(() => {
		setUnsavedEditsGate(unsavedGate);
		return () => clearUnsavedEditsGate(unsavedGate);
	});

	// ── Membership + deletion ──────────────────────────────────────────────
	// Member count for the selected role — drives the badge and the delete
	// guard. Keyed by role `name` (the picker value), mirroring the host's
	// `memberCountByRoleName` map. 0 when nothing is selected.
	const memberCount = $derived(memberCountByRoleName?.get(selectedRoleId) ?? 0);
	const canDelete = $derived(
		Boolean(loadedRole) && memberCount === 0 && !saving && Boolean(ondelete)
	);
	const deleteTitle = $derived(
		memberCount > 0
			? m.admin_delete_disabled_title({ count: memberCount })
			: !loadedRole
				? m.admin_delete_pick_title()
				: m.admin_delete_title()
	);

	async function handleDelete() {
		if (!selectedRoleId || !ondelete) return;
		if (
			dirty &&
			!(await confirm({
				title: m.admin_confirm_discard_title(),
				message: m.admin_confirm_discard_delete({ current: humanizeRoleName(selectedRoleId) }),
				confirmLabel: m.admin_discard_button(),
				variant: 'danger'
			}))
		) {
			return;
		}
		if (
			!(await confirm({
				title: m.admin_confirm_delete_title({ name: humanizeRoleName(selectedRoleId) }),
				message: m.admin_confirm_delete_message(),
				confirmLabel: m.admin_confirm_delete_button(),
				variant: 'danger'
			}))
		)
			return;
		saveError = undefined;
		try {
			await ondelete(selectedRoleId);
		} catch (err) {
			saveError = errorMessage(err);
		}
	}
</script>

<div class="rbac">
	<header class="rbac-head">
		<div class="rbac-role-bar">
			<div class="rbac-role-field">
				<div class="rbac-role-picker">
					<Select
						label={m.common_role()}
						placeholder={m.admin_role_placeholder()}
						options={roleOpts}
						value={pendingRoleId}
						onValueChange={handleRoleChange}
						disabled={saving}
					/>
				</div>
				{#if loadedRole?.description}
					<span class="rbac-role-hint" title={loadedRole.description}>
						{loadedRole.description}
					</span>
				{/if}
			</div>

			<div class="rbac-role-actions">
				<Button variant="ghost" size="sm" onclick={() => onnew?.()} disabled={!onnew || saving}>
					{#snippet iconLeft()}<Plus size={14} stroke-width={2} />{/snippet}
					{m.admin_new_role()}
				</Button>
				{#if loadedRole}
					<span class="rbac-members" title={m.admin_members_aria({ count: memberCount })}>
						<span class="rbac-members-count">{memberCount}</span>
						<span class="rbac-members-label"
							>{memberCount === 1 ? m.admin_member_singular() : m.admin_member_plural()}</span
						>
						<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- assignmentsRoute arrives from the host page, which builds it with resolve(). -->
						<a class="rbac-members-link" href={assignmentsRoute}>{m.admin_manage_members()}</a>
					</span>
					<a
						class="rbac-role-open"
						href={resolve('/Configure/access/roles/[id]/details', {
							id: `iam.Roles.${selectedRoleId}`
						})}
						title={m.admin_details_aria()}
					>
						<ExternalLink size={13} stroke-width={2} aria-hidden="true" />
						{m.admin_details_link()}
					</a>
					<Button
						variant="primary"
						size="sm"
						onclick={save}
						disabled={!dirty || saving}
						loading={saving}
					>
						{m.common_save()}
					</Button>
					<Button variant="ghost" size="sm" onclick={discard} disabled={!dirty || saving}>
						{m.admin_discard_button()}
					</Button>
					<Button
						variant="danger"
						size="sm"
						onclick={handleDelete}
						disabled={!canDelete}
						title={deleteTitle}
					>
						{#snippet iconLeft()}<Trash2 size={14} stroke-width={2} />{/snippet}
						{m.common_delete()}
					</Button>
				{/if}
			</div>
		</div>

		{#if saveError}
			<p class="rbac-save-error" role="alert">{saveError}</p>
		{/if}

		{#if loadedRole}
			<div class="rbac-tags">
				<span class="rbac-tags-label">visible_tags</span>
				{#if visibleTags.length === 0}
					<span class="rbac-tag-empty">{m.admin_tags_empty()}</span>
				{:else}
					{#each visibleTags as t (t)}
						<span class="rbac-tag" class:rbac-tag-wild={t === '*'}>{t}</span>
					{/each}
				{/if}
			</div>

			<div class="rbac-tags">
				<span class="rbac-tags-label" title={m.admin_connectivity_hint()}>connectivity</span>
				{#each CONNECTIVITY_CHANNELS as channel (channel)}
					<span
						class="rbac-channel"
						class:rbac-channel-off={!connectivity.includes(channel)}
						title={connectivity.includes(channel)
							? m.admin_connectivity_channel_on()
							: m.admin_connectivity_channel_off()}
					>
						{channel}
					</span>
				{/each}
				{#if assistantEnabled}
					<span class="rbac-budget">
						{budget == null
							? m.admin_connectivity_budget_unlimited()
							: m.admin_connectivity_budget_tokens({ count: String(budget) })}
					</span>
				{/if}
			</div>
		{/if}

		{#if loadedRole && tree.length > 0}
			<div class="rbac-toolbar">
				<div class="rbac-search">
					<input
						type="search"
						class="rbac-search-input"
						placeholder={m.admin_search_placeholder()}
						bind:value={search}
						aria-label={m.admin_search_aria()}
					/>
					{#if search}
						<button
							type="button"
							class="rbac-search-clear"
							aria-label={m.admin_search_clear_aria()}
							onclick={() => (search = '')}>×</button
						>
					{/if}
				</div>
				<div class="rbac-toolbar-actions">
					<button type="button" class="rbac-tool-btn" onclick={expandAll}
						>{m.admin_expand_all()}</button
					>
					<button type="button" class="rbac-tool-btn" onclick={collapseAll}
						>{m.admin_collapse_all()}</button
					>
				</div>
			</div>
		{/if}
	</header>

	{#if !loadedRole}
		<p class="rbac-empty">{m.admin_empty()}</p>
	{:else if isWildcard}
		<div class="rbac-wildcard">
			{m.admin_wildcard_note()}
		</div>
	{:else if tree.length === 0}
		<p class="rbac-empty">{m.admin_no_doctypes()}</p>
	{:else if filteredTree.length === 0}
		<p class="rbac-empty">{m.admin_no_match({ query: search })}</p>
	{:else}
		<div class="rbac-domains" role="tree" aria-label={m.admin_tree_aria()}>
			{#each filteredTree as domain (domain.domain)}
				<section
					role="treeitem"
					aria-selected="false"
					aria-expanded={isDomainExpanded(domain.domain)}
					class="rbac-domain"
					class:rbac-domain-collapsed={!isDomainExpanded(domain.domain)}
					style="--domain-color: {domain.color ?? 'var(--text-3)'}"
				>
					<header class="rbac-domain-head">
						<button
							type="button"
							class="rbac-domain-caret"
							class:caret-open={isDomainExpanded(domain.domain)}
							onclick={() => toggleDomain(domain.domain)}
							aria-expanded={isDomainExpanded(domain.domain)}
							aria-label={isDomainExpanded(domain.domain)
								? m.admin_collapse_domain_aria()
								: m.admin_expand_domain_aria()}
						></button>
						<span class="rbac-domain-pill">{domain.domain}</span>
						{#if domain.description}
							<HoverHint
								text={domain.description}
								label={m.admin_domain_hint_aria({ name: domain.domain })}
							/>
						{/if}
						<span class="rbac-domain-spacer"></span>
						<span
							class="rbac-domain-count"
							class:rbac-domain-count-active={countTouched(domain.roots, editorState) > 0}
							title={m.admin_doctypes_count_title({
								touched: countTouched(domain.roots, editorState),
								total: countDoctypes(domain.roots)
							})}
						>
							<span class="rbac-domain-count-active">{countTouched(domain.roots, editorState)}</span
							>
							<span class="rbac-domain-count-sep">/</span>
							<span class="rbac-domain-count-total">{countDoctypes(domain.roots)}</span>
						</span>
						<button
							type="button"
							class="rbac-domain-toggle"
							onclick={() => toggleDomain(domain.domain)}
						>
							{isDomainExpanded(domain.domain)
								? m.admin_collapse_button()
								: m.admin_expand_button()}
						</button>
					</header>

					{#if isDomainExpanded(domain.domain)}
						<div class="rbac-domain-tree" role="group">
							{#each domain.roots as root (root.qualified)}
								<RbacDoctypeTree
									node={root}
									state={editorState}
									{expanded}
									onSet={setScope}
									onToggleExpand={toggleExpand}
								/>
							{/each}
						</div>
					{/if}
				</section>
			{/each}
		</div>
	{/if}
</div>

<style>
	.rbac {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.rbac-head {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	/* Role bar: labelled picker on the left, Save/Discard actions on the right. */
	.rbac-role-bar {
		display: flex;
		align-items: flex-start;
		gap: 16px;
		flex-wrap: wrap;
	}
	.rbac-role-field {
		display: flex;
		flex-direction: column;
		gap: 5px;
		min-width: 240px;
		flex: 1 1 280px;
	}
	.rbac-role-picker {
		min-width: 240px;
	}
	.rbac-role-hint {
		font-size: 12px;
		color: var(--text-2);
		max-width: 72ch;
	}
	.rbac-role-actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding-top: 18px; /* visually align with the picker (label sits above) */
	}

	.rbac-members {
		display: inline-flex;
		align-items: baseline;
		gap: 4px;
		font-size: 12px;
		color: var(--text-2);
		padding: 0 4px;
	}
	.rbac-members-count {
		font-weight: 600;
		color: var(--text);
	}
	.rbac-members-label {
		color: var(--text-3);
	}
	.rbac-members-link {
		color: var(--accent);
		text-decoration: none;
		font-weight: 500;
		margin-left: 4px;
	}
	.rbac-members-link:hover {
		text-decoration: underline;
	}
	.rbac-role-open {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		margin-left: 10px;
		padding: 2px 8px;
		border-radius: var(--r-sm);
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text-2);
		font-size: 11.5px;
		font-weight: 500;
		text-decoration: none;
	}
	.rbac-role-open:hover {
		background: var(--sunken);
		color: var(--text);
		border-color: var(--border-strong, var(--border));
	}

	.rbac-save-error {
		margin: 0;
		font-size: 12.5px;
		color: var(--danger, #dc2626);
		background: color-mix(in srgb, var(--danger, #dc2626) 12%, transparent);
		border: 1px solid color-mix(in srgb, var(--danger, #dc2626) 35%, transparent);
		border-radius: var(--r-sm);
		padding: 6px 10px;
	}

	.rbac-tags {
		display: flex;
		align-items: center;
		gap: 6px;
		flex-wrap: wrap;
	}
	.rbac-tags-label {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}
	.rbac-tag {
		font-family: var(--font-mono);
		font-size: 11.5px;
		padding: 1px 7px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--text-3) 40%, transparent);
		background: var(--surface-2);
		color: var(--text-2);
	}
	.rbac-tag-wild {
		border-color: color-mix(in srgb, var(--accent-ink) 40%, transparent);
		background: var(--accent-weak);
		color: var(--accent-ink);
	}
	.rbac-tag-empty {
		font-size: 11.5px;
		color: var(--text-3);
	}
	.rbac-channel {
		font-family: var(--font-mono);
		font-size: 11.5px;
		padding: 1px 7px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--accent-ink) 40%, transparent);
		background: var(--accent-weak);
		color: var(--accent-ink);
	}
	.rbac-channel-off {
		border-color: color-mix(in srgb, var(--text-3) 40%, transparent);
		background: var(--surface-2);
		color: var(--text-3);
		text-decoration: line-through;
		opacity: 0.7;
	}
	.rbac-budget {
		font-size: 11.5px;
		color: var(--text-2);
		padding-left: 8px;
	}

	.rbac-toolbar {
		display: flex;
		align-items: center;
		gap: 16px;
		flex-wrap: wrap;
	}

	.rbac-search {
		position: relative;
		flex: 1 1 auto;
		max-width: 480px;
		min-width: 220px;
	}
	.rbac-search-input {
		width: 100%;
		font-family: var(--font-sans);
		font-size: 13px;
		padding: 8px 30px 8px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}
	.rbac-search-input::placeholder {
		color: var(--text-3);
	}
	.rbac-search-input:focus-visible {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}
	.rbac-search-clear {
		position: absolute;
		right: 6px;
		top: 50%;
		transform: translateY(-50%);
		border: none;
		background: none;
		color: var(--text-3);
		font-size: 18px;
		line-height: 1;
		cursor: pointer;
		padding: 2px 6px;
		border-radius: var(--r-sm);
	}
	.rbac-search-clear:hover {
		color: var(--text);
		background: var(--surface-2);
	}

	.rbac-toolbar-actions {
		display: inline-flex;
		gap: 6px;
	}
	.rbac-tool-btn {
		font-family: var(--font-sans);
		font-size: 11.5px;
		color: var(--text-2);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 5px 9px;
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s;
	}
	.rbac-tool-btn:hover {
		background: var(--surface-2);
		color: var(--text);
	}

	.rbac-wildcard {
		padding: 12px 14px;
		font-size: 13px;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid color-mix(in srgb, var(--accent-ink) 30%, transparent);
		border-radius: var(--r);
	}
	.rbac-empty {
		font-size: 13px;
		color: var(--text-3);
	}

	.rbac-domains {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	.rbac-domain {
		background: var(--surface);
		border: 1px solid var(--border);
		border-left: 3px solid var(--domain-color, var(--text-3));
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
	}
	.rbac-domain-collapsed .rbac-domain-head {
		border-bottom: none;
	}

	.rbac-domain-head {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 10px 14px;
		background: var(--surface-2);
		border-bottom: 1px solid var(--border);
		flex-wrap: wrap;
		border-top-left-radius: var(--r-lg);
		border-top-right-radius: var(--r-lg);
	}

	.rbac-domain-caret {
		width: 16px;
		height: 16px;
		flex-shrink: 0;
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
		color: var(--text-2);
		font-size: 9px;
		line-height: 1;
		display: inline-flex;
		align-items: center;
		justify-content: center;
	}
	.rbac-domain-caret::before {
		content: '▶';
		transition: transform 0.12s;
	}
	.rbac-domain-caret.caret-open::before {
		transform: rotate(90deg);
	}

	.rbac-domain-spacer {
		flex: 1 1 auto;
	}

	/* Touched/total count: a neutral pill readable in both light and dark
	   themes. The active count is signalled by bold + accent text, NOT an
	   accent background fill (which was low-contrast on dark themes). */
	.rbac-domain-count {
		font-family: var(--font-mono);
		font-size: 12px;
		padding: 2px 8px;
		border-radius: var(--r-pill);
		background: var(--surface);
		border: 1px solid var(--border);
		color: var(--text-3);
		white-space: nowrap;
	}
	.rbac-domain-count-active {
		color: var(--accent-ink);
		font-weight: 700;
	}
	.rbac-domain-count-sep {
		margin: 0 1px;
		opacity: 0.6;
	}
	.rbac-domain-count-total {
		color: var(--text-2);
	}

	.rbac-domain-toggle {
		font-family: var(--font-sans);
		font-size: 11px;
		color: var(--text-2);
		background: transparent;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 3px 8px;
		cursor: pointer;
	}
	.rbac-domain-toggle:hover {
		background: var(--surface);
		color: var(--text);
	}

	.rbac-domain-pill {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 700;
		letter-spacing: 0.04em;
		color: var(--domain-color, var(--text));
		text-transform: uppercase;
	}

	.rbac-domain-tree {
		display: flex;
		flex-direction: column;
		border-bottom-left-radius: var(--r-lg);
		border-bottom-right-radius: var(--r-lg);
		overflow: hidden;
	}
</style>
