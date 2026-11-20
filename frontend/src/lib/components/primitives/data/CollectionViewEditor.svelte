<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Dialog } from 'bits-ui';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type {
		CollectionView,
		CollectionViewColumn,
		CollectionSurface,
		KanbanLane
	} from '$lib/collectionView/types.js';
	import {
		buildConfig,
		buildPayload,
		defaultColumns,
		pickableFields,
		sortableFields,
		validateDraft,
		type CollectionViewDraft
	} from '$lib/collectionView/config.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import CollectionViewSurfaceStep from './CollectionViewSurfaceStep.svelte';
	import CollectionViewColumnsForm from './CollectionViewColumnsForm.svelte';
	import CollectionViewCalendarForm from './CollectionViewCalendarForm.svelte';
	import CollectionViewKanbanForm from './CollectionViewKanbanForm.svelte';
	import { DataSourceError } from '$lib/datasource/types.js';

	/**
	 * Modal editor for a `core.CollectionView` (a saved listing surface).
	 *
	 * Two-step flow:
	 *   1. Surface picker — choose the presentation layout (`table`,
	 *      `calendar`, and `kanban` are enabled; `grid` is shown disabled as
	 *      a forward signal).
	 *   2. Surface config — for `table`: the view name, the general-vs-personal
	 *      scope, and an ordered column set picked from the doctype's flat
	 *      fields; for `kanban`: the board mode, group-by field or lane editor,
	 *      card sort, and the base filter.
	 *
	 * Create vs. edit:
	 * - Create (`view` absent): POSTs to the parent `core.DocType`'s
	 *   `collection_view` children endpoint. The General/Personal toggle is
	 *   shown only when the active role holds an *unrestricted* `create`
	 *   permission (Lua `ctx.actor.scope == nil`); a `$mine`-scoped creator is
	 *   personal-only and the backend force-binds `owner_id` regardless.
	 * - Edit (`view` present): PATCHes the existing view. `owner_id` is
	 *   immutable server-side, so the scope selector is display-only.
	 *
	 * Permission affordances are UI hints only — the backend `WriteEnforcer`
	 * re-checks every action.
	 */
	let {
		driver,
		doctype,
		parentDocId,
		view = null,
		/** Projection id of the existing view to edit (edit mode). Create mode omits it. */
		viewId,
		viewerId,
		onclose,
		onsaved
	}: {
		driver: DataDriver;
		doctype: DoctypeDef;
		/** Projection id of the parent `core.DocType` (e.g. `"crm.Deal"`). */
		parentDocId: string;
		/** Existing view to edit; null/undefined opens in create mode. */
		view?: CollectionView | null;
		/** Projection id of the existing view being edited. */
		viewId?: string;
		/** Account id of the current user — used to set `owner_id` for personal views. */
		viewerId?: string;
		onclose?: () => void;
		/** Fired after a successful create/update with the saved view payload. */
		onsaved?: (view: CollectionView) => void;
	} = $props();

	const isEdit = $derived(view != null);

	type Step = 'surface' | 'config';
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let step = $state<Step>(isEdit ? 'config' : 'surface');

	// ── Form state ──────────────────────────────────────────────────
	// svelte-ignore state_referenced_locally — the editor is remounted fresh
	// per open (keyed), so reading the prop's initial value here is intended.
	let name = $state(view?.name ?? '');
	// `surface` is immutable in edit mode for v1 (only `table` and `calendar`
	// exist; the editor only constructs `table` views today).
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let surface = $state<CollectionSurface>(view?.surface ?? 'table');

	/**
	 * Effective scope of the view being authored:
	 * - Create: derived from the toggle (default Personal — always succeeds).
	 * - Edit: read from the existing view's `owner_id` (general ⇔ absent).
	 */
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let personal = $state(view ? (view.owner_id ?? null) != null : true);

	let saving = $state(false);
	let errorMsg = $state<string | null>(null);

	// ── Column builder state ────────────────────────────────────────
	/**
	 * Selectable flat fields plus the system-managed timestamp columns
	 * (`created_at` / `updated_at`). Every document carries them in
	 * its `meta` — the Table's loader flattens them onto the row — so they are
	 * selectable for any doctype. The `title` is the picker label and the
	 * default column header.
	 */
	const pickable = $derived(pickableFields(doctype.fields));

	/** Ordered, authored columns (editable labels + order). */
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let columns = $state<CollectionViewColumn[]>(
		view?.config?.columns
			? view.config.columns.map((c) => ({ ...c }))
			: defaultColumns(doctype.fields)
	);

	function addColumn(f: FieldDef) {
		columns = [...columns, { key: f.key, label: f.title ?? f.key }];
	}

	function removeColumn(index: number) {
		columnsTouched = true;
		columns = columns.filter((_, i) => i !== index);
	}

	function moveColumn(index: number, dir: -1 | 1) {
		const target = index + dir;
		if (target < 0 || target >= columns.length) return;
		const next = [...columns];
		[next[index], next[target]] = [next[target], next[index]];
		columns = next;
	}

	function patchLabel(index: number, value: string) {
		// Avoid mutating shared proxy state — replace the array entry.
		const next = [...columns];
		next[index] = { ...next[index], label: value };
		columns = next;
	}

	function patchEditable(index: number, value: boolean) {
		// Unchecking drops the key entirely so the stored config stays clean.
		const next = [...columns];
		const col = { ...next[index] };
		if (value) col.editable = true;
		else delete col.editable;
		next[index] = col;
		columns = next;
	}

	// ── Calendar config state ────────────────────────────────────────
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let discriminator = $state(view?.config?.calendar?.discriminator ?? '');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let endField = $state(view?.config?.calendar?.end_field ?? '');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let colorBy = $state(view?.config?.calendar?.color_by ?? '');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let titleTemplate = $state(view?.config?.calendar?.title_template ?? '');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let weekStart = $state<'monday' | 'sunday'>(view?.config?.calendar?.week_start ?? 'monday');

	// svelte-ignore state_referenced_locally — initial value from the prop.
	let filters = $state<Record<string, unknown>>(
		view?.config?.calendar?.filters
			? { ...view.config.calendar.filters }
			: view?.config?.kanban?.filters
				? { ...view.config.kanban.filters }
				: {}
	);

	/** Fields the FilterBar may filter on (filterable, non-system-hidden). */
	const filterableFields = $derived(
		doctype.fields.filter((f) => !f.read_only && !f.write_only && (f.operators?.length ?? 0) > 0)
	);

	// ── Kanban config state ──────────────────────────────────────────
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let kanbanMode = $state<'values' | 'custom'>(view?.config?.kanban?.mode ?? 'values');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let groupBy = $state(view?.config?.kanban?.group_by ?? '');
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let lanes = $state<KanbanLane[]>(
		view?.config?.kanban?.lanes
			? view.config.kanban.lanes.map((lane) => ({ ...lane, filter: { ...lane.filter } }))
			: []
	);
	// The card sort draft composes back to the one-entry `sort` array; the
	// leading `-` maps to the descending direction.
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let sortField = $state((view?.config?.kanban?.sort?.[0] ?? '').replace(/^-/, ''));
	// svelte-ignore state_referenced_locally — initial value from the prop.
	let sortDesc = $state(
		(view?.config?.kanban?.sort?.[0] ?? '') === ''
			? true
			: (view?.config?.kanban?.sort?.[0] ?? '').startsWith('-')
	);

	// ── Validation ──────────────────────────────────────────────────
	const draft = $derived<CollectionViewDraft>({
		name,
		surface,
		columns,
		discriminator,
		endField,
		colorBy,
		titleTemplate,
		weekStart,
		filters,
		filterableFields,
		fields: doctype.fields,
		kanbanMode,
		groupBy,
		lanes,
		sortField,
		sortDesc,
		sortFields: sortableFields(doctype.fields)
	});
	const validation = $derived(validateDraft(draft));
	// ── Error visibility ────────────────────────────────────────────
	// `validateDraft` gates the save button continuously, but each
	// message stays hidden until the user touches the field it describes
	// — an untouched dialog must not open with errors (same policy as
	// NewRoleDialog: the hint waits for the first blur; the Create button
	// stays disabled regardless). The lane messages are the exception:
	// they belong to the custom mode the user chose explicitly, so they
	// show as soon as that mode is active.
	let nameTouched = $state(false);
	let columnsTouched = $state(false);
	let discriminatorTouched = $state(false);
	let endFieldTouched = $state(false);
	let groupByTouched = $state(false);
	const nameError = $derived(nameTouched ? validation.nameError : null);
	const columnsError = $derived(columnsTouched ? validation.columnsError : null);
	const discriminatorError = $derived(discriminatorTouched ? validation.discriminatorError : null);
	const endFieldError = $derived(endFieldTouched ? validation.endFieldError : null);
	const groupByError = $derived(groupByTouched ? validation.groupByError : null);
	const lanesError = $derived(validation.lanesError);
	const laneErrors = $derived(validation.laneErrors);
	const canSave = $derived(!saving && validation.canSave);

	// ── Submission ──────────────────────────────────────────────────
	async function handleSave() {
		if (!canSave) return;
		errorMsg = null;
		saving = true;
		try {
			const child = driver
				.domain('core')
				.doctype('DocType')
				.doc(parentDocId)
				.children<CollectionView>('collection_view');
			let saved: CollectionView;
			if (isEdit && view && viewId) {
				// PATCH with a plain partial document — `Document::Update`
				// deep-merges it over the current content and re-validates types.
				// `owner_id` is never touched here (immutable server-side), so
				// the editor cannot flip general↔personal on update.
				const patch = {
					name: name.trim(),
					surface,
					config: buildConfig(draft)
				};
				await child.doc(viewId).update(patch);
				saved = { ...view, ...buildPayload(draft, { personal, viewerId }) };
			} else {
				const res = await child.create(buildPayload(draft, { personal, viewerId }));
				saved = res.data as CollectionView;
			}
			onsaved?.(saved);
		} catch (err) {
			errorMsg =
				err instanceof DataSourceError
					? err.message
					: err instanceof Error
						? err.message
						: m.common_save_failed();
		} finally {
			saving = false;
		}
	}

	const title = $derived(isEdit ? m.list_editor_edit_title() : m.list_editor_new_title());
</script>

<Dialog.Root
	open
	onOpenChange={(v) => {
		if (!v) onclose?.();
	}}
>
	<Dialog.Portal>
		<Dialog.Overlay class="cve-overlay" />
		<Dialog.Content class="cve-panel">
			<header class="cve-head">
				<Dialog.Title class="cve-title">{title}</Dialog.Title>
				<Dialog.Close class="cve-close" aria-label={m.common_close()}>✕</Dialog.Close>
			</header>

			{#if errorMsg}
				<div class="cve-error" role="alert">{errorMsg}</div>
			{/if}

			{#if step === 'surface' && !isEdit}
				<div class="cve-body">
					<CollectionViewSurfaceStep value={surface} onselect={(s) => (surface = s)} />
				</div>
				<footer class="cve-foot">
					<Button variant="ghost" onclick={() => onclose?.()}>{m.common_cancel()}</Button>
					<Button variant="primary" onclick={() => (step = 'config')}>
						{m.list_editor_next()}
					</Button>
				</footer>
			{:else}
				<div class="cve-body">
					<div class="cve-form">
						<Input
							label={m.common_name()}
							placeholder={m.list_editor_name_placeholder()}
							bind:value={name}
							error={nameError ?? undefined}
							required
							onblur={() => (nameTouched = true)}
						/>

						<div class="cve-field">
							<span class="cve-field-label">{m.list_editor_scope()}</span>
							{#if isEdit}
								<!-- owner_id is immutable; show the current scope as a read-only badge -->
								<div class="cve-scope-badge" data-scope={personal ? 'personal' : 'general'}>
									{personal ? m.list_editor_scope_personal() : m.list_editor_scope_general()}
								</div>
								<span class="cve-field-helper">
									{personal
										? m.list_editor_personal_edit_helper()
										: m.list_editor_general_edit_helper()}
								</span>
							{:else}
								<div class="cve-radios" role="radiogroup" aria-label={m.list_editor_scope_aria()}>
									<label class="cve-radio">
										<input type="radio" name="cve-scope" value={true} bind:group={personal} />
										<span>{m.list_editor_scope_personal()}</span>
										<span class="cve-radio-sub">{m.list_editor_personal_sub()}</span>
									</label>
									<Can doctype="core.CollectionView" action="create" scope="unrestricted">
										<label class="cve-radio">
											<input type="radio" name="cve-scope" value={false} bind:group={personal} />
											<span>{m.list_editor_scope_general()}</span>
											<span class="cve-radio-sub">{m.list_editor_general_sub()}</span>
										</label>
										{#snippet fallback()}
											<!-- A `$mine`-scoped creator cannot make general views: the
										     backend force-binds owner_id, so the General radio is hidden. -->
										{/snippet}
									</Can>
								</div>
								{#if personal && !viewerId}
									<span class="cve-field-helper cve-warn">
										{m.list_editor_personal_warn()}
									</span>
								{/if}
							{/if}
						</div>

						{#if surface === 'table'}
							<CollectionViewColumnsForm
								fields={pickable}
								{columns}
								error={columnsError}
								onadd={addColumn}
								onremove={removeColumn}
								onmove={moveColumn}
								onlabel={patchLabel}
								oneditable={patchEditable}
							/>
						{:else if surface === 'calendar'}
							<CollectionViewCalendarForm
								{doctype}
								{driver}
								bind:discriminator
								bind:endField
								bind:colorBy
								bind:titleTemplate
								bind:filters
								{filterableFields}
								{discriminatorError}
								{endFieldError}
								onDiscriminatorBlur={() => (discriminatorTouched = true)}
								onEndFieldBlur={() => (endFieldTouched = true)}
							/>
						{:else}
							<CollectionViewKanbanForm
								{doctype}
								{driver}
								bind:kanbanMode
								bind:groupBy
								bind:lanes
								bind:sortField
								bind:sortDesc
								bind:filters
								{filterableFields}
								{groupByError}
								{lanesError}
								{laneErrors}
								onGroupByBlur={() => (groupByTouched = true)}
							/>
						{/if}
					</div>
				</div>
				<footer class="cve-foot">
					<Button variant="ghost" onclick={() => onclose?.()}>{m.common_cancel()}</Button>
					{#if !isEdit}
						<Button variant="secondary" onclick={() => (step = 'surface')}>
							{m.common_back()}
						</Button>
					{/if}
					<Button
						variant="primary"
						loading={saving}
						disabled={!canSave}
						onclick={handleSave}
						label={isEdit ? m.list_editor_save_changes() : m.list_editor_create_view()}
					/>
				</footer>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	/* Bits UI renders the overlay and the panel in a portal at the document
	   root. Target them with :global classes. */
	:global(.cve-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(15, 17, 22, 0.45);
		backdrop-filter: blur(2px);
		z-index: 1000;
	}

	:global(.cve-panel) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(680px, calc(100vw - 48px));
		max-height: min(88vh, 760px);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		box-shadow: 0 24px 60px rgba(0, 0, 0, 0.28);
		overflow: hidden;
		z-index: 1001;
	}

	.cve-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 16px 20px;
		border-bottom: 1px solid var(--border);
	}

	:global(.cve-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.cve-close) {
		width: 30px;
		height: 30px;
		border-radius: var(--r-sm, 6px);
		border: none;
		background: none;
		color: var(--text-2);
		cursor: pointer;
		font-size: 14px;
		line-height: 1;
	}

	:global(.cve-close:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	.cve-body {
		padding: 20px;
		overflow-y: auto;
		flex: 1;
	}

	.cve-error {
		background: var(--danger-weak, rgba(220, 60, 60, 0.1));
		color: var(--danger);
		font-size: 12.5px;
		padding: 10px 14px;
		margin: 12px 20px 0;
		border-radius: var(--r-sm, 6px);
	}

	/* ── Form ──────────────────────────────────────────────────────────── */
	.cve-form {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	.cve-field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.cve-field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.cve-field-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-warn {
		color: var(--warn, #b7791f);
	}

	/* ── Scope radios / badge ─────────────────────────────────────────── */
	.cve-radios {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
	}

	.cve-radio {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		font-size: 13px;
		min-width: 140px;
	}

	.cve-radio input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}

	.cve-radio:has(input:checked) {
		border-color: var(--accent);
		box-shadow: 0 0 0 2px var(--accent-weak);
	}

	.cve-radio-sub {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-scope-badge {
		align-self: flex-start;
		padding: 5px 10px;
		border-radius: var(--r-pill, 999px);
		font-size: 12px;
		font-weight: 600;
		border: 1px solid var(--border);
		background: var(--surface-2);
	}

	.cve-scope-badge[data-scope='general'] {
		color: var(--accent);
		border-color: var(--accent);
		background: var(--accent-weak);
	}

	/* ── Footer ────────────────────────────────────────────────────────── */
	.cve-foot {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		padding: 14px 20px;
		border-top: 1px solid var(--border);
		background: var(--surface-2);
	}
</style>
