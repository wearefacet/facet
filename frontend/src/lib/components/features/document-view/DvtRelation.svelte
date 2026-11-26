<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import type { DocumentResponse, ListResponse } from '$lib/datasource/types';
	import type {
		InputAutoNode,
		RelationNode,
		ReferenceClickHandler,
		TemplateNode
	} from '$lib/template-types';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import StructuredInput from '$lib/components/primitives/forms/StructuredInput.svelte';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import DvtInput from './DvtInput.svelte';
	import DvtRelationTable from './DvtRelationTable.svelte';
	import { type DoctypeDef, type FieldDef } from '$lib/doctype/types.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { toast } from '$lib/toast.svelte.js';
	import { can, fieldVisible } from '$lib/permissions.svelte';
	import { Plus, Trash2 } from '@lucide/svelte';
	import {
		type ChildDraft,
		computeChildOps,
		type ChildOp,
		type ChildSaveOutcome,
		type ExistingChild
	} from '$lib/doctype/childDrafts.js';
	import {
		rowCapsuleReference,
		rowDocument as rowDocumentFor,
		type RelationRow
	} from '$lib/doctype/relationColumns.js';
	import { createRelationDrafts } from '$lib/doctype/relationDrafts.svelte.js';
	import { loadRelationTemplates } from '$lib/doctype/relationTemplates.js';

	// Rows a relation section fetches when the template sets no `limit`.
	// Matches the backend's `MAX_ITEMS` — the child list honors `items` now,
	// so the default must render the whole owned set, not truncate it.
	const DEFAULT_RELATION_LIMIT = 1000;

	let {
		template,
		document,
		driver,
		values,
		def: _def,
		fieldErrors: _fieldErrors,
		onreferenceclick
	}: {
		/** The relation template node. */
		template: RelationNode;
		/** The current document the relation is bound to (its `meta.id` seeds the query). */
		document: DocumentResponse;
		/** Driver used to fetch the relation list, hydrate capsules, and load
		 *  the relation doctype's inline/form view templates. */
		driver?: DataDriver;
		/**
		 * Mutable form values bag for the parent. When present, the relation is
		 * in form mode; if `template.editable === true`, each row renders the
		 * child doctype's `form` template and Add/Remove affordances appear.
		 * The drafts are staged under `values[__relation_drafts__][rel]`.
		 */
		values?: Record<string, unknown>;
		/** Doctype definition of the parent — used to detect the `children`
		 *  entry matching `template.source.rel` (for schema validation). */
		def?: DoctypeDef;
		/** Per-top-level-field validation errors — forwarded into each row's
		 *  nested `DocumentViewTemplate` so backend errors surface inline. */
		fieldErrors?: Record<string, unknown>;
		/** Click handler forwarded to row capsules. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const limit = $derived(template.limit ?? DEFAULT_RELATION_LIMIT);
	// Editable relations always render as inline rows (capsule mode is
	// read-only). Defaults to `'capsule'` for backward compatibility.
	const viewMode = $derived(template.editable ? 'inline' : (template.view ?? 'capsule'));
	// Form mode is active when a `values` bag was supplied AND the relation is
	// marked editable. Non-editable relations render read-only even inside a
	// form template (e.g. an inverse reference panel on an edit page).
	const isEditable = $derived(Boolean(template.editable));

	// ── Malformed source guard ────────────────────────────────────────
	// The stored view template passes through unchanged, so a source written
	// before validation existed can reach this component in a broken shape —
	// a bare string, or a kind without its required member. Detect it once
	// here: the section shows a local config error instead of firing a list
	// request the backend answers with the wrong 403/422 error.
	function sourceShapeError(source: unknown): boolean {
		if (source === null || typeof source !== 'object') return true;
		const s = source as { kind?: unknown; rel?: unknown; field?: unknown };
		if (s.kind === 'children') return typeof s.rel !== 'string' || s.rel.length === 0;
		if (s.kind === 'filter') return typeof s.field !== 'string' || s.field.length === 0;
		return true;
	}
	const malformedSource = $derived(sourceShapeError(template.source as unknown));

	let rows = $state<RelationRow[] | null>(null);
	let loading = $state(false);
	let errorMsg = $state<string | null>(null);
	// Cancellation counters for the list/template fetches; each has its own so
	// an in-flight template load does not cancel an in-flight row list (or vice
	// versa) when the parent document id changes.
	let listSeq = 0;
	let tplSeq = 0;

	// Resolve the parent document's qualified id — used as the `parent_id` walk
	// for `source.kind === 'children'`, and as the `field__eq` filter value for
	// `source.kind === 'filter'`.
	const parentId = $derived(document.meta.id);

	// The relation doctype is a qualified string (e.g. "crm.CompanyMembership").
	const qualifiedRelation = $derived(template.doctype);
	const relationParts = $derived.by(() => {
		const first = qualifiedRelation.indexOf('.');
		if (first < 1) return null;
		const second = qualifiedRelation.indexOf('.', first + 1);
		const domain = qualifiedRelation.slice(0, first);
		const doctype =
			second < 0 ? qualifiedRelation.slice(first + 1) : qualifiedRelation.slice(first + 1, second);
		return { domain, doctype };
	});

	// Loaded child view templates. Loaded lazily on first render — `inline`
	// for read mode (with a `quickView` fallback mirroring `loadDoctypeView`'s
	// view→quickView chain), `form` for editable mode. `null` means the load
	// settled and found no stored template: read rows fall back to capsules,
	// editable rows to the generic field walk below.
	let inlineTemplate = $state<TemplateNode | null | undefined>(undefined);
	let formTemplate = $state<TemplateNode | null | undefined>(undefined);
	let relationDef = $state<DoctypeDef | undefined>(undefined);
	let templatesLoading = $state(false);

	async function loadTemplates() {
		if (!driver || !relationParts) return;
		if (malformedSource) return;
		// capsule mode needs no template/def; inline + editable + table all need
		// the relation doctype's def (table for column field-type lookup).
		if (!isEditable && viewMode !== 'inline' && viewMode !== 'table') return;
		const my = ++tplSeq;
		templatesLoading = true;
		try {
			const update = await loadRelationTemplates(
				driver,
				qualifiedRelation,
				{ relationDef, formTemplate, inlineTemplate },
				{ editable: isEditable }
			);
			if (my !== tplSeq) return;
			relationDef = update.relationDef ?? relationDef;
			// `null` is a settled result here ("no stored view"), not an absent
			// key — a `??` merge would fold it back into `undefined` and the row
			// body would match no render branch. Merge by key presence.
			if (update.formTemplate !== undefined) formTemplate = update.formTemplate;
			if (update.inlineTemplate !== undefined) inlineTemplate = update.inlineTemplate;
		} catch {
			if (my === tplSeq) {
				if (isEditable) formTemplate = null;
				else inlineTemplate = null;
			}
		} finally {
			if (my === tplSeq) templatesLoading = false;
		}
	}

	function fetchErrorLabel(e: unknown): string {
		return errorMessage(e, m.doc_relation_load_failed());
	}

	let prevParentId: string | undefined;

	async function load() {
		if (!driver || !relationParts) return;
		// A malformed source is a config error, not a data error: skip the
		// request entirely and show the local message.
		if (malformedSource) {
			rows = null;
			loading = false;
			errorMsg = m.doc_relation_source_invalid();
			return;
		}
		// Reset the user-edited drafts when the bound parent document changes —
		// otherwise a user's pending edits on candidate A would leak into
		// candidate B. The controller also drops its cached mirror artifacts so
		// the `$effect.pre` re-creates the bag — the previous bag referenced
		// drafts from the old parent id.
		if (prevParentId !== parentId) {
			prevParentId = parentId;
			relationDrafts.reset();
		}
		// Skip the fetch entirely on a create form (no parent id yet — the parent
		// has not been saved, so it cannot have children). On the create route,
		// `document.meta.id` is the empty string, which would produce an invalid
		// URL like `/Api/hr/Candidate//experiences` and a 404. The user starts
		// from an empty list and adds rows via the Add button; those drafts are
		// persisted against the parent id once the parent create succeeds.
		if (template.source.kind === 'children' && !parentId) {
			rows = [];
			errorMsg = null;
			loading = false;
			return;
		}
		const my = ++listSeq;
		loading = true;
		errorMsg = null;
		// Keep stale rows visible while the new fetch is in flight so the section
		// does not collapse visually on a parent id change.
		try {
			if (template.source.kind === 'children') {
				// The children REST route is keyed by the PARENT's domain + doctype
				// (`/Api/:parentDomain/:parentDoctype/:id/:rel`), not the child's.
				// The relation's `doctype` field names the child doctype (used for
				// template / definition lookups elsewhere) — using it here would
				// produce `/Api/.../:childDoctype/:parentId/:rel`, which the
				// backend's RestRoutes would reject with 404 "Unknown child".
				const res: ListResponse = await driver
					.domain(document.meta.domain)
					.doctype(document.meta.doc_type)
					.doc(parentId)
					.children(template.source.rel)
					.list({ items: limit });
				if (my !== listSeq) return;
				rows = res.data as unknown as RelationRow[];
			} else {
				const res: ListResponse = await driver
					.domain(relationParts.domain)
					.doctype(relationParts.doctype)
					.list({
						items: limit,
						filters: { [`${template.source.field}__eq`]: parentId }
					});
				if (my !== listSeq) return;
				rows = res.data as unknown as RelationRow[];
			}
			// No seeding step here. `drafts` is derived from `rows` (via
			// `userDrafts ?? rows.map(rowToDraft)`). When rows land, the derived
			// re-evaluates and the drafts come into sync — no imperative write
			// to `values[DRAFTS_KEY]` is needed inside `load()`.
		} catch (e) {
			if (my !== listSeq) return;
			rows = null;
			errorMsg = fetchErrorLabel(e);
		} finally {
			if (my === listSeq) loading = false;
		}
	}

	// Re-fetch whenever the binding inputs change. `parentId` is the relevant
	// reactive input — `template.*` fields can be assumed stable across a single
	// render (the parent view template is itself cached / conditionally swapped).
	$effect(() => {
		void parentId;
		void qualifiedRelation;
		void template.source;
		void limit;
		void isEditable;
		load();
		loadTemplates();
	});

	// ── Inline boolean toggles (table view) ──────────────────────────────
	// A table column marked `editable` over a plain boolean field renders its
	// cell as a toggle that PATCHes the row document directly. Two gates sit
	// on top of the schema check in `toggleTarget`: the viewer must hold
	// `update` on the relation doctype (a UI hint — the backend WriteEnforcer
	// re-checks), and the surface must be read-only. A form's `values` bag
	// means staged edits — an immediate PATCH there would break the form's
	// commit model ("toggled, then cancelled, but it saved"). Works for both
	// source kinds: the update is row-scoped and never routes through the
	// parent, unlike the form-editable rows path.

	const canInlineToggle = $derived(values === undefined && can(qualifiedRelation, 'update'));

	/** `rowId:colKey` stamps with an in-flight toggle — disables the button. */
	let inlinePending = $state<Set<string>>(new Set());

	/** Flip a boolean cell and persist it. Optimistic — reverts on failure. */
	async function handleInlineToggle(row: RelationRow, key: string, next: boolean) {
		if (!driver || !relationParts) return;
		const id = row.meta.id;
		const stamp = `${id}:${key}`;
		if (inlinePending.has(stamp)) return;
		const previous = rows;
		inlinePending = new Set(inlinePending).add(stamp);
		rows = (rows ?? []).map((r) =>
			r.meta.id === id ? { ...r, data: { ...r.data, [key]: next } } : r
		);
		try {
			await driver
				.domain(relationParts.domain)
				.doctype(relationParts.doctype)
				.doc(id)
				.update({ [key]: next });
		} catch (e) {
			rows = previous;
			toast({ message: errorMessage(e, m.common_save_failed()), variant: 'error' });
		} finally {
			const rest = new Set(inlinePending);
			rest.delete(stamp);
			inlinePending = rest;
		}
	}

	// ── Editable drafts ──────────────────────────────────────────────────────
	//
	// Draft state lives in the `relationDrafts` controller
	// (lib/doctype/relationDrafts.svelte.ts): user-staged drafts over a
	// rows-derived fallback, tombstone add/remove, and the `$effect.pre` that
	// mirrors the derived `drafts` into `values[DRAFTS_KEY]` so
	// `DocumentForm.persistChildDrafts` can read them at save time. The
	// controller is created during component init so its `$effect.pre` is
	// legal; `load()` resets it when the bound parent document changes.
	// `computeOps()` / `persist()` below stay on the component — that is the
	// `DocumentForm` contract (`bind:this`).

	const draftsKey = $derived(
		template.source.kind === 'children' ? template.source.rel : template.source.field
	);

	const relationDrafts = createRelationDrafts({
		draftsKey: () => draftsKey,
		isEditable: () => isEditable,
		rows: () => rows,
		relationDef: () => relationDef,
		values: () => values
	});

	/** Count shown in the section header. The body renders the staged drafts
	 *  in editable mode and the loaded rows otherwise, so the header counts the
	 *  same list: a create form has no loaded rows, and the count must follow
	 *  the rows the user adds. Tombstoned drafts are not visible, so they do
	 *  not count. */
	const visibleRowCount = $derived(
		isEditable ? relationDrafts.drafts.filter((d) => !d.deleted).length : (rows?.length ?? 0)
	);

	/** Build the fake document the inner `DocumentViewTemplate` reads for one
	 *  draft row. */
	function rowDocument(draft: ChildDraft): DocumentResponse {
		return rowDocumentFor(draft, relationParts, relationDef?.schema_version ?? 1);
	}

	// Expose a stable accessor the inner template can rebind to — the draft's
	// `values` is mutated in place by the inner input nodes (the same mechanism
	// the parent form uses). The returned reference must stay reactive so Svelte
	// re-renders on changes.
	function rowValues(draft: ChildDraft): Record<string, unknown> {
		return draft.values;
	}

	// ── Editable fallback (no child `form` view) ─────────────────────────
	//
	// When the child doctype has no `kind: form` view (`formTemplate ===
	// null`), each row renders a generic field walk over the child
	// definition — the same fallback the parent form uses for a doctype
	// without a DVT. The walk skips computed (`data`), read-only, replicated,
	// and not-visible fields: the patch builders drop them too, so an
	// editable control would only invite a 422. Structured fields render
	// through `StructuredInput`, the same widget the parent fallback form
	// uses. Every other field renders through the auto `input` pipeline —
	// the same controls the `form` template path dispatches to.

	/** Editable fields of the child definition, in declaration order. */
	const fallbackFields = $derived.by<FieldDef[]>(() => {
		if (!relationDef) return [];
		return relationDef.fields.filter(
			(f) => f.type !== 'data' && !f.read_only && !f.replicate && fieldVisible(f)
		);
	});

	/** Auto `input` node for one fallback field — the definition drives the
	 *  control. */
	function fallbackNode(field: FieldDef): InputAutoNode {
		return { type: 'input', field: field.key };
	}

	// ── Persist ──────────────────────────────────────────────────────────────
	//
	// Public entry point called by `DocumentForm` after the parent document has
	// saved. Walks the drafts, computes ops, issues them one by one, and
	// returns a per-relation outcome. Surfaces per-row errors so the form can
	// re-render the failing row's inputs with inline error messaging.

	/** Collection handle for the relation (children) or the doctype (filter).
	 *  A malformed source has no handle — the persist path degrades to the
	 *  schema-unavailable outcome instead of writing to a guessed route. */
	function collection(): DataSource | null {
		if (!driver || !relationParts || malformedSource) return null;
		if (template.source.kind === 'children') {
			// Children route is keyed by the parent's domain + doctype — see `load()`
			// for the routing rationale.
			return driver
				.domain(document.meta.domain)
				.doctype(document.meta.doc_type)
				.doc(parentId)
				.children(template.source.rel);
		}
		return driver.domain(relationParts.domain).doctype(relationParts.doctype);
	}

	/** Existing rows as expected by `computeChildOps`. */
	function existingRows(): ExistingChild[] {
		if (!rows) return [];
		return rows.map((r) => ({ id: r.meta.id, data: r.data ?? {} }));
	}

	/** Compute the per-row ops for this relation. Exposed for the form. */
	export function computeOps(): ChildOp[] {
		if (!relationDef) return [];
		return computeChildOps(relationDrafts.drafts, existingRows(), relationDef);
	}

	/** Persist this relation's drafts. Returns a summary the form surfaces. */
	export async function persist(): Promise<ChildSaveOutcome> {
		const outcome: ChildSaveOutcome = {
			rel: draftsKey,
			label: template.label,
			errors: {},
			saved: 0
		};
		const coll = collection();
		if (!coll || !relationDef) {
			outcome.errors['-1'] = m.doc_relation_schema_unavailable();
			return outcome;
		}
		const ops = computeOps();
		for (const op of ops) {
			try {
				if (op.op === 'create') {
					await coll.create(op.content);
					outcome.saved++;
				} else if (op.op === 'update') {
					await coll.doc(op.id).update(op.patch);
					outcome.saved++;
				} else {
					await coll.doc(op.id).delete();
					outcome.saved++;
				}
			} catch (e) {
				outcome.errors[op.op === 'create' ? '-1' : op.id] = errorMessage(e, m.common_save_failed());
			}
		}
		// Reload the rows so the next render reflects the persisted state.
		await load();
		return outcome;
	}
</script>

<div class="dvt-relation" data-editable={isEditable}>
	<div class="dvt-relation-head">
		<span class="dvt-relation-label">{template.label}</span>
		{#if loading || templatesLoading}
			<span class="dvt-relation-status" aria-live="polite">…</span>
		{:else if rows !== null}
			<span class="dvt-relation-status">{visibleRowCount}</span>
		{/if}
		{#if isEditable && !malformedSource}
			<button
				type="button"
				class="dvt-relation-add"
				onclick={relationDrafts.addDraft}
				aria-label={m.doc_relation_add_aria({ label: template.label })}
			>
				<Plus size={13} strokeWidth={2} aria-hidden="true" />
				{m.common_add()}
			</button>
		{/if}
	</div>

	{#if errorMsg}
		<div class="dvt-relation-error">{errorMsg}</div>
	{:else if !loading && rows !== null && rows.length === 0 && !isEditable}
		<div class="dvt-relation-empty">{m.doc_items_empty()}</div>
	{:else if isEditable}
		{#if relationDrafts.drafts.length === 0}
			<div class="dvt-relation-empty">{m.doc_relation_empty_hint()}</div>
		{:else}
			<div class="dvt-relation-list">
				{#each relationDrafts.drafts as draft (draft.id)}
					{#if !draft.deleted}
						<div class="dvt-relation-row" data-row-id={draft.id}>
							<div class="dvt-relation-row-body">
								{#if formTemplate}
									<DocumentViewTemplate
										template={formTemplate}
										document={rowDocument(draft)}
										values={rowValues(draft)}
										def={relationDef}
										{driver}
									/>
								{:else if formTemplate === null && relationDef}
									<div class="dvt-relation-row-fallback">
										{#each fallbackFields as field (field.key)}
											{#if field.type === 'object' || field.type === 'array' || field.type === 'dictionary'}
												<StructuredInput
													label={field.title ?? field.key}
													required={field.required}
													{field}
													id="rf-{draft.id}-{field.key}"
													bind:value={draft.values[field.key]}
												/>
											{:else}
												<DvtInput
													template={fallbackNode(field)}
													document={rowDocument(draft)}
													values={rowValues(draft)}
													def={relationDef}
													{driver}
												/>
											{/if}
										{/each}
									</div>
								{:else if formTemplate === null}
									<!-- No child definition either — the row can neither render
									     controls nor compute ops on save. Name the state. -->
									<div class="dvt-relation-row-fallback-note">
										{m.doc_relation_schema_unavailable()}
									</div>
								{/if}
							</div>
							<button
								type="button"
								class="dvt-relation-row-remove"
								onclick={() => relationDrafts.removeDraft(draft.id)}
								aria-label={m.doc_relation_remove_aria({ label: template.label })}
							>
								<Trash2 size={13} strokeWidth={2} aria-hidden="true" />
							</button>
						</div>
					{/if}
				{/each}
			</div>
		{/if}
	{:else if rows !== null}
		{#if viewMode === 'table'}
			<DvtRelationTable
				{rows}
				{template}
				{viewMode}
				{parentId}
				{driver}
				{relationDef}
				{onreferenceclick}
				ontoggle={canInlineToggle ? handleInlineToggle : undefined}
				togglePending={inlinePending}
			/>
		{:else}
			<div class="dvt-relation-grid" class:inline={viewMode === 'inline'}>
				{#each rows as row (row.meta.id)}
					{#if viewMode === 'capsule'}
						{@const ref = rowCapsuleReference(row, template.referenceField)}
						{#if ref}
							<Capsule
								{driver}
								reference={ref}
								qualifiedDoctype={qualifiedRelation}
								{onreferenceclick}
							/>
						{:else}
							<Capsule label={row.meta.display_name ?? row.meta.id} />
						{/if}
					{:else if viewMode === 'inline'}
						{#if inlineTemplate}
							<DocumentViewTemplate
								template={inlineTemplate}
								document={row as unknown as DocumentResponse}
								{driver}
								def={relationDef}
								{onreferenceclick}
							/>
						{:else if inlineTemplate === null}
							<!-- No `inline` AND no `quickView` kind for this doctype — fall back
							     to a plain capsule so the row is still visible instead of
							     disappearing. -->
							<Capsule label={row.meta.display_name ?? row.meta.id} />
						{/if}
					{/if}
				{/each}
			</div>
		{/if}
	{/if}
</div>

<style>
	.dvt-relation {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 6px 0;
	}

	.dvt-relation-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 8px;
	}

	.dvt-relation-label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}

	.dvt-relation-status {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.dvt-relation-add {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 2px 8px;
		font-size: 11.5px;
		font-weight: 500;
		color: var(--accent);
		background: transparent;
		border: 1px solid var(--accent-weak);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}

	.dvt-relation-add:hover {
		background: var(--accent-weak);
		border-color: var(--accent);
	}

	.dvt-relation-grid {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	/* Inline mode stacks rows vertically with row separators. */
	.dvt-relation-grid.inline {
		flex-direction: column;
		gap: 8px;
	}

	.dvt-relation-list {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.dvt-relation-row {
		position: relative;
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 8px;
		align-items: start;
		padding: 12px;
		background: var(--surface-2, var(--surface));
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.dvt-relation-row-body {
		min-width: 0;
	}

	/* Generic field walk for a row whose doctype has no `form` view. */
	.dvt-relation-row-fallback {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	/* Degenerate case — no child definition reached the renderer. */
	.dvt-relation-row-fallback-note {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
	}

	.dvt-relation-row-remove {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 26px;
		height: 26px;
		padding: 0;
		color: var(--text-3);
		background: transparent;
		border: 1px solid var(--border);
		border-radius: var(--r);
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s,
			background 0.12s;
	}

	.dvt-relation-row-remove:hover {
		color: var(--danger);
		border-color: var(--danger-weak);
		background: var(--danger-weak);
	}

	.dvt-relation-empty {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 12px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}

	.dvt-relation-error {
		font-size: 12px;
		color: var(--danger);
		padding: 8px 10px;
		border: 1px solid var(--danger-weak);
		border-radius: var(--r);
		background: var(--danger-weak);
	}
</style>
