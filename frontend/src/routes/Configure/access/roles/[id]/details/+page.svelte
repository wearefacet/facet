<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { invalidateAll } from '$app/navigation';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import RowList from '$lib/components/primitives/data/RowList.svelte';
	import RowItem from '$lib/components/primitives/data/RowItem.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import StringListEditor from '$lib/components/primitives/forms/StringListEditor.svelte';
	import { ArrowLeft } from '@lucide/svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { toBannerError, errorMessage } from '$lib/datasource/bannerError.js';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { budgetInputToValue, budgetInputValid, budgetToInput } from '$lib/iam/roleBudget.js';
	import { levelToInput, parseLevelInput } from '$lib/iam/roleLevel.js';
	import { tagUnionOverflow } from '$lib/iam/roleTags.js';
	import { getVisibleTags } from '$lib/permissions.svelte.js';
	import { setUnsavedEditsGate, clearUnsavedEditsGate } from '$lib/unsavedEdits.js';
	import { CONNECTIVITY_CHANNELS } from '$lib/iam/content.js';
	import type { RoleContent } from '$lib/iam/content.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Role details page — edit the role's mutable fields: `level` (required
	 * integer, 0–100), `description`, the `visible_tags` field-visibility
	 * list, the connectivity controls (the per-role programmatic channels:
	 * `mcp`, `webhook`, `api`, `assistant`) and the assistant token budget.
	 * The role `name` is unique and immutable.
	 *
	 * Tag writes follow the backend union rule (`RBAC::RoleAuthority`): a
	 * new tag must already sit in the caller's own `visible_tags` or in the
	 * role's previous tags. The check runs client-side against the active
	 * role's tags for fast inline errors; the backend re-checks on save and
	 * the banner shows its structured details when it refuses.
	 *
	 * The role id in the URL is the role document id (`iam.Roles.{name}`).
	 * Loads via `.show()`, edits a local copy, and PATCHes the changed
	 * fields on save. While the form is dirty, the shared unsaved-edits
	 * gate guards tab navigation and browser close.
	 */

	const roleId = $derived(page.params.id ?? '');
	const roleName = $derived(humanizeRoleName(roleDocIdToName(roleId)));

	let description = $state('');
	// Held as text so an emptied input reads as a validation error instead
	// of a silent zero; `parseLevelInput` owns the number.
	let level = $state('');
	let connectivity: string[] = $state([]);
	// Field-visibility tags. `StringListEditor` mutates the bound array in
	// place; the committed copy is the union's second baseline.
	let visibleTags = $state<string[]>([]);
	let committedTags = $state<string[]>([]);
	// The explicit Unlimited switch owns the null: checked clears the input and
	// the save sends an explicit null (the update pipeline restores it).
	let unlimited = $state(true);
	// Text state so an emptied input reads as "no budget" (unlimited).
	let assistantBudget = $state('');
	let committedDescription = $state('');
	let committedLevel = $state('');
	let committedConnectivity: string[] = $state([]);
	let committedUnlimited = $state(true);
	let committedBudget = $state('');
	let loadError = $state<string | undefined>(undefined);
	let actionError = $state<string | undefined>(undefined);
	let actionDetails = $state<string[]>([]);
	let loaded = $state(false);
	let saving = $state(false);

	// Single shared driver for reads and writes on this page.
	const driver = new DocumentDataDriver('');

	async function loadAll() {
		try {
			const res = await driver.domain('iam').doctype('Roles').doc(roleId).show();
			const data = res.data as RoleContent;
			const desc = String(data.description ?? '');
			description = desc;
			committedDescription = desc;
			level = levelToInput(data.level);
			committedLevel = level;
			connectivity = Array.isArray(data.connectivity) ? data.connectivity : [];
			committedConnectivity = [...connectivity];
			const tags = Array.isArray(data.visible_tags) ? data.visible_tags : [];
			visibleTags = [...tags];
			committedTags = [...tags];
			assistantBudget = budgetToInput(data.assistant_token_budget);
			committedBudget = assistantBudget;
			unlimited = data.assistant_token_budget == null;
			committedUnlimited = unlimited;
			loadError = undefined;
		} catch (err) {
			loadError = errorMessage(err);
		} finally {
			loaded = true;
		}
	}

	$effect(() => {
		void page.url.pathname;
		void roleId;
		loadAll();
	});

	// Reload on permission refresh (matches the roles list page).
	onPermissionRefresh(() => {
		void loadAll();
		void invalidateAll();
	});

	// Integer budgets only; the Unlimited switch skips validation. The
	// backend re-validates against the `integer` field type.
	const budgetValid = $derived(budgetInputValid(unlimited, assistantBudget));
	// Level is required, integer, 0–100.
	const levelValid = $derived(parseLevelInput(level) !== null);
	const connectivityDirty = $derived(
		connectivity.length !== committedConnectivity.length ||
			CONNECTIVITY_CHANNELS.some(
				(c) => connectivity.includes(c) !== committedConnectivity.includes(c)
			)
	);

	// ── Visible tags — the field-visibility union ─────────────────────────
	// The backend denies a write whose new tags leave the union of the
	// caller's own tags and the role's previous tags. Mirror it client-side:
	// unknown caller tags (store not hydrated) defer to the backend.
	const callerTags = $derived(getVisibleTags());
	const overflowTags = $derived(tagUnionOverflow(visibleTags, committedTags, callerTags));
	// An empty list would make the role field-blind (every field carries at
	// least the implicit `default` tag), so the editor requires one tag.
	const tagsValid = $derived(overflowTags.length === 0 && visibleTags.length > 0);
	const tagsError = $derived(
		overflowTags.length > 0
			? m.configure_role_tags_union_error({ tags: overflowTags.join(', ') })
			: visibleTags.length === 0
				? m.configure_role_tags_required()
				: undefined
	);
	const tagsDirty = $derived(
		visibleTags.length !== committedTags.length ||
			visibleTags.some((t) => !committedTags.includes(t))
	);

	const dirty = $derived(
		description !== committedDescription ||
			level !== committedLevel ||
			connectivityDirty ||
			tagsDirty ||
			unlimited !== committedUnlimited ||
			(!unlimited && assistantBudget.trim() !== committedBudget.trim())
	);

	function validateTag(value: string): string | null {
		return tagUnionOverflow([value], committedTags, callerTags).length > 0
			? m.configure_role_tags_union_error({ tags: value })
			: null;
	}

	function toggleChannel(channel: string) {
		connectivity = connectivity.includes(channel)
			? connectivity.filter((c) => c !== channel)
			: [...connectivity, channel];
	}

	async function save() {
		const nextLevel = parseLevelInput(level);
		if (!dirty || saving || !budgetValid || nextLevel === null || !tagsValid) return;
		saving = true;
		actionError = undefined;
		actionDetails = [];
		try {
			await driver
				.domain('iam')
				.doctype('Roles')
				.doc(roleId)
				.update({
					level: nextLevel,
					description,
					connectivity,
					visible_tags: visibleTags,
					// An explicit null unsets the field (unlimited) — the update
					// pipeline restores explicit nulls from the patch.
					assistant_token_budget: budgetInputToValue(unlimited, assistantBudget)
				});
			await loadAll();
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			actionError = banner.message;
			actionDetails = banner.details;
		} finally {
			saving = false;
		}
	}

	function discard() {
		description = committedDescription;
		level = committedLevel;
		connectivity = [...committedConnectivity];
		visibleTags = [...committedTags];
		unlimited = committedUnlimited;
		assistantBudget = committedBudget;
		actionError = undefined;
		actionDetails = [];
	}

	// ── Unsaved-edits gate ───────────────────────────────────────────────
	// The role-detail layout asks the gate before a tab navigation; the
	// shared beforeunload handler arms the browser's leave dialog for
	// close and refresh. The effect body reads nothing reactive — the gate
	// closure reads the live `dirty` when asked.
	const unsavedGate = () => dirty;
	$effect(() => {
		setUnsavedEditsGate(unsavedGate);
		return () => clearUnsavedEditsGate(unsavedGate);
	});
</script>

<svelte:head>
	<title>{m.configure_role_details_page_title({ name: roleName })}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.configure_role_details_tab()} subtitle={m.configure_role_details_subtitle()}>
		{#snippet actions()}
			<Button variant="ghost" size="sm" href="/Configure/access/roles">
				{#snippet iconLeft()}
					<ArrowLeft size={13} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{m.configure_role_back_button()}
			</Button>
		{/snippet}
	</PageHeader>

	<div class="role-chip">
		<span class="chip-label">{m.common_role()}</span>
		<span class="chip-name">{roleName}</span>
		<span class="chip-id">{roleId}</span>
	</div>

	{#if loadError}
		<AlertBanner message={loadError} dismissable onDismiss={() => (loadError = undefined)} />
	{/if}
	{#if actionError}
		<AlertBanner
			message={actionError}
			details={actionDetails}
			dismissable
			onDismiss={() => {
				actionError = undefined;
				actionDetails = [];
			}}
		/>
	{/if}

	{#if !loaded}
		<p class="status">{m.configure_role_loading()}</p>
	{:else}
		<RowList>
			<RowItem>
				<div class="detail-grid">
					<div class="field">
						<span class="field-label">{m.common_name()}</span>
						<span class="field-value mono">{roleName}</span>
					</div>

					<div class="level-field">
						<Input
							type="text"
							label={m.admin_new_role_level_label()}
							placeholder={m.admin_new_role_level_placeholder()}
							bind:value={level}
							inputmode="numeric"
							error={levelValid
								? undefined
								: level.trim() === ''
									? m.admin_new_role_level_required()
									: m.admin_new_role_level_error()}
							helper={m.admin_new_role_level_helper()}
						/>
					</div>

					<label class="field" for="role-description">
						<span class="field-label">
							{m.common_description()}
							<span class="field-optional">{m.configure_role_desc_editable()}</span>
						</span>
						<textarea
							id="role-description"
							class="desc-input"
							bind:value={description}
							rows="4"
							placeholder={m.admin_new_role_desc_placeholder()}></textarea>
					</label>

					<div class="tags-block">
						<StringListEditor
							label={m.configure_role_tags_label()}
							helper={m.configure_role_tags_helper()}
							bind:values={visibleTags}
							error={tagsError}
							validator={validateTag}
						/>
					</div>

					<div class="assistant-block">
						<span class="field-label">{m.configure_role_assistant_label()}</span>
						<div class="channel-row">
							{#each CONNECTIVITY_CHANNELS as channel (channel)}
								<label class="channel-check">
									<input
										type="checkbox"
										checked={connectivity.includes(channel)}
										onchange={() => toggleChannel(channel)}
									/>
									<span class="channel-name">{channel}</span>
								</label>
							{/each}
						</div>
						<p class="channel-helper">{m.configure_role_channels_helper()}</p>
						<div class="assistant-row">
							<div class="budget-field">
								<Input
									type="text"
									label={m.configure_role_budget_label()}
									placeholder={m.configure_role_budget_placeholder()}
									bind:value={assistantBudget}
									inputmode="numeric"
									suffix="tokens"
									disabled={!connectivity.includes('assistant') || unlimited}
									error={!unlimited && assistantBudget.trim() !== '' && !budgetValid
										? m.configure_role_budget_error()
										: undefined}
									helper={m.configure_role_budget_helper()}
								/>
							</div>
							<Toggle
								label={m.configure_role_budget_unlimited()}
								bind:checked={unlimited}
								onchange={() => {
									// Checking Unlimited clears the input; unchecking just
									// re-enables it (the text stays as committed).
									if (unlimited) assistantBudget = '';
								}}
							/>
						</div>
					</div>

					<div class="actions">
						<Button
							variant="ghost"
							size="md"
							disabled={!dirty || saving || !budgetValid || !levelValid || !tagsValid}
							onclick={discard}
						>
							{m.admin_discard_button()}
						</Button>
						<Button
							variant="primary"
							size="md"
							disabled={!dirty || saving || !budgetValid || !levelValid || !tagsValid}
							onclick={save}
						>
							{saving ? m.common_saving() : m.configure_role_save_button()}
						</Button>
					</div>
				</div>
			</RowItem>
		</RowList>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}

	.role-chip {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		padding: 4px 10px 4px 8px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill, 999px);
		background: var(--surface);
		margin-bottom: 18px;
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.chip-label {
		color: var(--text-3);
	}

	.chip-name {
		color: var(--text);
		font-weight: 600;
	}

	.chip-id {
		color: var(--text-3);
		font-size: 11px;
	}

	.detail-grid {
		display: flex;
		flex-direction: column;
		gap: 20px;
		width: 100%;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 7px;
	}

	.field-label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}

	.field-optional {
		font-weight: 400;
		color: var(--text-3);
	}

	.field-value {
		font-size: 13.5px;
		color: var(--text);
	}

	.mono {
		font-family: var(--font-mono);
	}

	.tags-block {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-top: 14px;
		border-top: 1px solid var(--border);
	}

	.assistant-block {
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding-top: 14px;
		border-top: 1px solid var(--border);
	}

	.channel-row {
		display: flex;
		gap: 18px;
		flex-wrap: wrap;
	}

	.channel-check {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		font-size: 13px;
		color: var(--text);
		cursor: pointer;
	}

	.channel-check input {
		accent-color: var(--accent);
	}

	.channel-name {
		font-family: var(--font-mono);
		font-size: 12.5px;
	}

	.channel-helper {
		font-size: 12px;
		color: var(--text-3);
		max-width: 560px;
	}

	.assistant-row {
		display: flex;
		align-items: flex-end;
		gap: 24px;
		flex-wrap: wrap;
	}

	.budget-field {
		width: 260px;
	}

	.level-field {
		width: 260px;
	}

	.desc-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-family: var(--font-sans);
		font-size: 13.5px;
		line-height: 1.5;
		resize: vertical;
		min-height: 96px;
	}

	.desc-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 4px;
	}

	.status {
		font-size: 13px;
		color: var(--text-3);
	}
</style>
