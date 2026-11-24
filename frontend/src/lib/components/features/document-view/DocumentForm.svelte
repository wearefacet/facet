<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { Save } from '@lucide/svelte';
	import DocumentViewTemplate from '$lib/components/features/document-view/DocumentViewTemplate.svelte';
	import DvtRelation from '$lib/components/features/document-view/DvtRelation.svelte';
	import DvtInputSecret from '$lib/components/features/document-view/DvtInputSecret.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import DurationInput from '$lib/components/primitives/forms/DurationInput.svelte';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import PeriodPicker from '$lib/components/primitives/forms/PeriodPicker.svelte';
	import MoneyInput from '$lib/components/primitives/forms/MoneyInput.svelte';
	import StructuredInput from '$lib/components/primitives/forms/StructuredInput.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import DoctypeHeader from '$lib/components/primitives/content/DoctypeHeader.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import ReferenceListEditor from '$lib/components/primitives/forms/ReferenceListEditor.svelte';
	import { buildFormCreate, buildFormPatch } from '$lib/doctype/formDiff.js';
	import { ensureAbsoluteUrl, urlAdornment, urlFieldError } from '$lib/doctype/urlValue.js';
	import { seedCreateValues, seedEditValues } from '$lib/doctype/formSeed.js';
	import { groupFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import { splitQualifiedRef } from '$lib/datasource/qualifiedRef.js';
	import { resolveParentRel } from '$lib/doctype/parentLink.js';
	import { DataSourceError } from '$lib/datasource/types';
	import { toBannerError, errorMessage } from '$lib/datasource/bannerError.js';
	import type { DocumentResponse, ValidationError } from '$lib/datasource/types';
	import type { TemplateNode, InputSecretNode, RelationNode } from '$lib/template-types';
	import type { FieldDef, DoctypeDef, MoneyValue, PeriodValue } from '$lib/doctype/types.js';
	import { humanize, parseDoctypeDef } from '$lib/doctype/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { computeChildOps, type ChildSaveOutcome } from '$lib/doctype/childDrafts.js';
	import { buildFallbackChildRelations } from './fallbackChildRelations.js';
	import { registerRouteShortcuts } from '$lib/shortcuts.svelte';
	import { fieldVisible } from '$lib/permissions.svelte';
	import type { FieldStageRegistrar } from './fieldStage.js';

	/**
	 * Create/Edit document form surface.
	 *
	 * Both the `/{domain}/{doctype}/new` and `.../{id}/edit` routes render a
	 * form driven by the doctype's `kind: form` DocumentView template (falling
	 * back to one input per scalar field when no template exists). The only
	 * differences between the two modes are how the values bag is seeded and
	 * which mutation is issued on save — this component owns the rest.
	 */

	let {
		mode,
		def,
		view,
		driver,
		document
	}: {
		mode: 'create' | 'edit';
		/** Doctype definition — drives the fallback form and field typing. */
		def: DoctypeDef;
		/** Resolved `kind: form` view (template may be null → fallback form). */
		view: { kind: string; template: TemplateNode | null };
		driver: DataDriver;
		/** Persisted document — required in `edit` mode, ignored in `create`. */
		document?: DocumentResponse<Record<string, unknown>>;
	} = $props();

	const doc = $derived((document ?? null) as DocumentResponse<Record<string, unknown>> | null);

	/**
	 * Return path carried by the `?from=` query param — set by the surfaces
	 * that open the form from another route (the QuickView peek's edit
	 * pencil, a configure listing's New button). After a successful save the
	 * form navigates there instead of the show page, so a currency edited
	 * from `/Configure/currencies` lands back in Configure rather than in
	 * the app domain. Same-origin absolute paths only (an open-redirect
	 * guard: `//host` and scheme-relative forms are rejected).
	 */
	const returnHref = $derived.by<string | null>(() => {
		const raw = page.url.searchParams.get('from');
		if (!raw || !raw.startsWith('/') || raw.startsWith('//')) return null;
		return raw;
	});

	const listHref = $derived(
		`/${encodeURIComponent(def.domain)}/${encodeURIComponent(def.doctype)}`
	);
	const showHref = $derived(
		doc
			? `/${encodeURIComponent(def.domain)}/${encodeURIComponent(def.doctype)}/${encodeURIComponent(doc.meta.id)}`
			: listHref
	);
	const backHref = $derived(returnHref ?? (mode === 'edit' ? showHref : listHref));
	const headerTitle = $derived(
		mode === 'edit'
			? m.doc_edit_title({ name: doc?.meta.display_name ?? doc?.meta.id ?? '' })
			: m.doc_new_title({ doctype: def.doctype })
	);

	// Editable values bag — seeded from field defaults on create, or (on edit)
	// the persisted content over neutral per-type seeds for keys it does not
	// contain. Input nodes bind to this object; on save it is coerced and
	// POSTed/PATCHed as the content.
	// svelte-ignore state_referenced_locally — intentional snapshot: a form owns
	// the values it loaded (later `document` changes must not clobber user
	// edits), and this component is remounted per SvelteKit route.
	const values = $state<Record<string, unknown>>(
		mode === 'edit' ? seedEditValues(def, doc?.data) : seedCreateValues(def)
	);

	// Synthetic empty document for `create`: `DocumentViewTemplate` requires a
	// `document` prop (display nodes read `document.data[...]`). Input nodes
	// bind to `values`, so the empty data bag does not affect editing.
	// `$derived` keeps the meta columns in sync if the definition is replaced.
	const emptyDoc = $derived({
		data: {},
		meta: {
			id: '',
			mid: '',
			domain: def.domain,
			doc_type: def.doctype,
			version: 0,
			schema_version: def.schema_version ?? 1,
			display_name: null,
			created_at: '',
			updated_at: ''
		}
	} as DocumentResponse<Record<string, unknown>>);

	// ── Composition parent (create mode on a `member_of` child) ───────────
	//
	// A composition child is created through the parent's nested route
	// (`doc(parentId).children(rel)`) — the backend stamps the system-managed
	// `meta.parent_id` and rejects the flat create with a 422. When the child
	// doctype is `nav_visible`, its listing page links here, so the form owns
	// a required parent picker and routes the save through the nested route.
	// `?parent=<id>` (bare id or qualified ref) preselects the picker for a
	// deep link from a parent surface.
	const parentQualified = $derived(def.member_of ? `${def.domain}.${def.member_of}` : null);
	const isChildCreate = $derived(mode === 'create' && parentQualified !== null);

	// svelte-ignore state_referenced_locally — intentional snapshot: the picker
	// seeds once from the `?parent=` deep link (the form is remounted per
	// SvelteKit route, same contract as the `values` bag above).
	let parentValue = $state(
		mode === 'create' && def.member_of ? seedParentValue(def.domain, def.member_of) : ''
	);
	/** Relation key on the parent whose target is this child doctype. */
	let parentRel = $state<string | null>(null);
	let parentDefState = $state<'loading' | 'ready' | 'missing'>('loading');
	/** Save-gate error — set when the user submits without a usable parent. */
	let parentGateError = $state<string | null>(null);
	let parentRelSeq = 0;

	function seedParentValue(domain: string, memberOf: string): string {
		const raw = page.url.searchParams.get('parent');
		if (!raw) return '';
		const parts = splitQualifiedRef(raw);
		return parts ? `${parts.domain}.${parts.doctype}.${parts.id}` : `${domain}.${memberOf}.${raw}`;
	}

	async function loadParentRawDef(qualified: string): Promise<Record<string, unknown> | undefined> {
		const local = driver.getDoctypeDefinition(qualified);
		if (local) return local;
		const reg = await DoctypeRegistry.cached(driver);
		return reg.doctypeDefinitions.get(qualified);
	}

	$effect(() => {
		if (!isChildCreate || !parentQualified) return;
		const my = ++parentRelSeq;
		parentDefState = 'loading';
		void (async () => {
			const raw = await loadParentRawDef(parentQualified);
			if (my !== parentRelSeq) return;
			if (!raw) {
				parentRel = null;
				parentDefState = 'missing';
				return;
			}
			parentRel = resolveParentRel(raw, def.doctype);
			parentDefState = 'ready';
		})();
	});

	// Pick a parent again → the stale save-gate error no longer applies.
	$effect(() => {
		if (parentValue && parentGateError) parentGateError = null;
	});

	/** Picker error: the save gate first, then the structural link breaks. */
	const parentPickerError = $derived.by<string | undefined>(() => {
		if (parentGateError) return parentGateError;
		if (parentDefState === 'missing') {
			return m.doc_form_parent_missing({ doctype: def.member_of ?? '' });
		}
		if (parentDefState === 'ready' && !parentRel) {
			return m.doc_form_parent_broken({ doctype: def.member_of ?? '' });
		}
		return undefined;
	});

	// Fallback form: when no `kind: form` DocumentView exists, render one input
	// per editable field straight from the doctype definition. Read-only fields
	// cannot be sent in the patch (backend 422) and are skipped. Fields the
	// caller cannot see are skipped too (B-176): the presented definition
	// carries every declared field, but the write guard refuses invisible-field
	// writes with 403 — offering the input (the secret "Set value" affordance
	// included) invites an action the caller can never take. The show page
	// renders only stored fields, which the read mask already filtered.
	// Secret fields render through `DvtInputSecret` (B-129) — the same stage/adopt
	// affordance the template form's `input-secret` node uses — so the persisted
	// `{mode, version, set_at}` marker never binds into a plain text input.
	// Structured fields (object / array / dictionary) edit as schema-checked
	// JSON through `StructuredInput` (B-105): the object/array pair rendered
	// no widget at all before, and the dictionary one submitted raw text the
	// backend always rejected.
	const fallbackFields = $derived.by<FieldDef[]>(() =>
		def.fields.filter((f) => f.type !== 'data' && !f.read_only && !f.replicate && fieldVisible(f))
	);

	/** Build the `input-secret` node the fallback form feeds to `DvtInputSecret`. */
	function secretNode(field: FieldDef): InputSecretNode {
		return {
			type: 'input-secret',
			field: field.key,
			label: field.title ?? humanize(field.key),
			required: field.required
		};
	}

	/** Qualified target doctype of a single-value reference field — bare names
	 *  qualify against the field's own domain, the same contract as
	 *  `DvtInputReference` (the picker needs the canonical `{domain}.{Doctype}`
	 *  form for its forced mode). */
	function refTargetDoctype(field: FieldDef): string | undefined {
		if (!field.doctype) return undefined;
		return field.doctype.includes('.') ? field.doctype : `${def.domain}.${field.doctype}`;
	}

	let saving = $state(false);
	let errorMsg = $state<string | null>(null);
	let fieldErrors = $state<FieldErrorMap>({});
	let generalErrors = $state<ValidationError[]>([]);

	// ── In-flight field stages (B-191) ──────────────────────────────────
	//
	// An async field widget (the secret input today) registers each stage
	// attempt here: one entry per field, the latest attempt replaces the
	// previous one. The handle reaches the shared values bag only when the
	// stage round-trip resolves, so handleSave awaits every entry before it
	// diffs — sending earlier would silently keep the stored value and look
	// like a successful save.
	//
	// A settled stage leaves the map on success. A failed one stays: its
	// rejection re-surfaces on every later save attempt until the field's
	// next attempt (a re-stage, or a clear, which registers a resolved
	// stage) supersedes it. Saving over a failed stage would drop the typed
	// plaintext without any handle to adopt.
	const pendingFieldStages = new Map<string, Promise<void>>();

	const registerFieldStage: FieldStageRegistrar = (field, stage) => {
		pendingFieldStages.set(field, stage);
		stage.then(
			() => {
				if (pendingFieldStages.get(field) === stage) pendingFieldStages.delete(field);
			},
			() => {
				// Keep: the failed stage blocks the next save until superseded.
				// This handler also marks the rejection consumed, so a stage that
				// fails without a save never surfaces as an unhandled rejection.
			}
		);
	};

	// Parse validity of the fallback form's structured fields, reported by
	// each StructuredInput (B-118). A key present here marks text the widget
	// cannot parse — invalid JSON or a schema mismatch. In that state the
	// values bag still holds the last valid structure (or the cleared
	// sentinel), so a save would silently send stale content or drop the
	// field; handleSave gates on this map (the ActionArgsDialog pattern:
	// client-side checks block the submit, the backend 422 stays the final
	// guard).
	let structuredInvalid = $state<Record<string, boolean>>({});

	function setStructuredValidity(key: string, ok: boolean): void {
		if (ok) delete structuredInvalid[key];
		else structuredInvalid[key] = true;
	}

	const saveLabel = $derived(
		mode === 'create'
			? saving
				? m.common_creating()
				: m.common_create()
			: saving
				? m.common_saving()
				: m.common_save()
	);

	function fieldError(fieldKey: string): string | undefined {
		const list = fieldErrors[fieldKey];
		return list && list.length > 0 ? list.map((e) => e.message).join(' · ') : undefined;
	}

	// Fallback form url fields run the same commit the template form's
	// `input-text` node uses (B-294): the implied `https://` chrome shows
	// while the text carries no scheme, and on blur a dotted bare host is
	// completed while an unstorageable value keeps the user's raw text and
	// shows its field error, before the save 422 lands in the same slot.
	// The commit error takes precedence over a backend error, like
	// `DvtInputText` does.
	let urlBlurErrors = $state<Record<string, string>>({});

	function commitFallbackUrl(fieldKey: string): void {
		const v = values[fieldKey];
		if (typeof v !== 'string') return;
		delete urlBlurErrors[fieldKey];
		const fixed = ensureAbsoluteUrl(v);
		const invalid = urlFieldError(fixed);
		if (invalid !== null) {
			urlBlurErrors[fieldKey] = invalid;
			return;
		}
		if (fixed !== v) values[fieldKey] = fixed;
	}

	function fallbackFieldError(fieldKey: string): string | undefined {
		return urlBlurErrors[fieldKey] ?? fieldError(fieldKey);
	}

	/** Navigate after a successful save — back to `?from=` when present
	 * (the form entry is replaced, so it never stays in history), otherwise
	 * to the show page. */
	async function navigateAfterSave(savedId: string) {
		await invalidateAll();
		if (returnHref) {
			// eslint-disable-next-line svelte/no-navigation-without-resolve -- returnHref is the sanitized `?from=` pathname of the host surface, not a route id; the rule cannot see through the query param.
			await goto(returnHref, { replaceState: true });
			return;
		}
		await goto(
			resolve('/[domain=notApi]/[doctype]/[id]', {
				domain: encodeURIComponent(def.domain),
				doctype: encodeURIComponent(def.doctype),
				id: encodeURIComponent(savedId)
			})
		);
	}

	async function handleSave() {
		errorMsg = null;
		fieldErrors = {};
		urlBlurErrors = {};
		generalErrors = [];
		// Client-side gate (B-118): a structured field whose text does not
		// parse must not reach the wire. Block the save; each offending
		// widget keeps its field error visible, and the banner names the
		// block for a field the header button may have scrolled away.
		if (Object.keys(structuredInvalid).length > 0) {
			errorMsg = m.doc_form_structured_invalid();
			return;
		}
		saving = true;
		try {
			// B-191: wait for every in-flight field stage so the handles sit in
			// `values` before the diff runs. A stage that starts while we wait
			// (a change event the save click itself committed) joins the wait on
			// the next pass. A failed stage stops the save loudly — the inline
			// field error carries the reason.
			for (;;) {
				const stages = [...pendingFieldStages.values()];
				if (stages.length === 0) break;
				const results = await Promise.allSettled(stages);
				if (results.some((r) => r.status === 'rejected')) {
					errorMsg = m.doc_secret_stage_failed();
					return;
				}
			}
			let savedId: string | null = null;
			if (mode === 'create') {
				const patch = buildFormCreate(values, def);
				// Strip the `__relation_drafts__` bag — it is a synthetic key the form
				// uses to stage editable-relation drafts, not a real content field.
				delete patch[DRAFTS_KEY];
				const memberOf = def.member_of;
				if (isChildCreate && memberOf) {
					// parentValue holds the picked record id (the bare projection id)
					// or the `?parent=` deep-link token. Both forms address the parent
					// row on the nested route — the route resolves the id shapes like
					// the backend's canonical_doc_id. An empty value still gates the
					// save. Do not strip a prefix here: a seeded row id already
					// carries the `{domain}.{Doctype}.` prefix, and stripping it
					// would address a row that does not exist.
					if (!parentValue) {
						parentGateError = m.doc_form_parent_required({ doctype: memberOf });
						return;
					}
					// A broken link already shows in the picker — do not send a
					// doomed nested call (the backend would 404 on the rel).
					if (!parentRel) return;
					const created = await driver
						.domain(def.domain)
						.doctype(memberOf)
						.doc(parentValue)
						.children(parentRel)
						.create(patch);
					savedId = created.meta.id;
				} else {
					const created = await driver.domain(def.domain).doctype(def.doctype).create(patch);
					savedId = created.meta.id;
				}
			} else if (doc) {
				// The persisted content is the diff baseline: the bag was seeded from
				// it, so an untouched save emits an empty patch — Lua-guarded
				// immutable fields (iam.Roles.name, app.App.slug, …) refuse any
				// patch that carries the key, even unchanged.
				const patch = buildFormPatch(values, def, doc.data);
				delete patch[DRAFTS_KEY];
				await driver.domain(def.domain).doctype(def.doctype).doc(doc.meta.id).update(patch);
				savedId = doc.meta.id;
			}

			// Children persistence runs only when the parent saved successfully —
			// a failed parent create (e.g. validation 422) skips child mutation
			// since the parent id is not yet known / stable.
			if (savedId) {
				const outcomes = await persistChildDrafts(savedId);
				if (outcomes.length > 0) {
					// Surface per-relation errors in the banner — keep the user on the
					// edit page so they can fix the failing rows in place.
					const messages = outcomes.flatMap((o) =>
						Object.entries(o.errors).map(([rowId, msg]) => `${o.label} (${rowId}): ${msg}`)
					);
					if (messages.length > 0) {
						errorMsg = m.doc_form_children_failed();
						generalErrors = messages.map((m) => ({ message: m }) as ValidationError);
					} else {
						await navigateAfterSave(savedId);
						return;
					}
				} else {
					await navigateAfterSave(savedId);
					return;
				}
			}
		} catch (e) {
			// Surface backend validation details when the backend returns a
			// structured 422. Field-scoped errors go inline on each input;
			// non-field errors (script/RBAC/compute/schema) go in the banner.
			if (e instanceof DataSourceError) {
				const banner = toBannerError(e);
				errorMsg = banner.message;
				const grouped = groupFieldErrors(e.details);
				fieldErrors = grouped.fieldErrors;
				// Surface every structured detail in the banner too — not just the
				// non-field errors. A bare "Document validation failed" headline is
				// unhelpful when the failing inputs are not visible (e.g. a template
				// mismatch), and the field-scoped lines make the failure actionable.
				generalErrors = banner.details.map((m) => ({ message: m }) as ValidationError);
			} else {
				errorMsg = errorMessage(
					e,
					mode === 'create' ? m.common_create_failed() : m.common_save_failed()
				);
				fieldErrors = {};
				generalErrors = [];
			}
		} finally {
			saving = false;
		}
	}

	// `Mod+S` / `Mod+Enter` save — the same path as the Save button. Mod-combos
	// fire from typing targets by design (the focus sits in a field when the
	// user saves); `handleSave` guards itself against double submits.
	$effect(() => {
		return registerRouteShortcuts([
			{
				id: 'form.save',
				keys: 'Mod+S',
				label: m.shortcuts_doc_save(),
				group: 'document',
				handler: () => {
					if (saving) return false;
					void handleSave();
					return true;
				}
			},
			{
				id: 'form.save-enter',
				keys: 'Mod+Enter',
				label: m.shortcuts_doc_save(),
				group: 'document',
				handler: () => {
					if (saving) return false;
					void handleSave();
					return true;
				}
			}
		]);
	});

	// ── Editable relation persistence ───────────────────────────────────────
	//
	// Walks the rendered view template for `relation` nodes marked `editable: true`,
	// reads each one's drafts (staged by `DvtRelation` under `values[DRAFTS_KEY]`),
	// and issues the per-row create / update / delete calls against
	// `doc(parentId).children(rel)`. The contract honors the event-sourcing model —
	// each child mutation is independent, and partial failures are reported back
	// to the caller so the form can surface them without losing successful saves.

	const DRAFTS_KEY = '__relation_drafts__';

	/** A `relation` node discovered in the form template. */
	interface EditableRelation {
		rel: string;
		label: string;
		qualifiedDoctype: string;
	}

	/** DFS the view template for editable `relation` nodes. */
	function collectEditableRelations(node: TemplateNode | null): EditableRelation[] {
		if (!node) return [];
		const out: EditableRelation[] = [];
		const stack: TemplateNode[] = [node];
		while (stack.length > 0) {
			const n = stack.pop()!;
			if (n.type === 'relation' && n.editable && n.source.kind === 'children') {
				out.push({
					rel: n.source.rel,
					label: n.label,
					qualifiedDoctype: n.doctype
				});
			}
			// Recurse into all child slots. Each structural node has its own
			// `children?: TemplateNode[]` (or, for `tabs`, `tabs[].children`).
			if (n.type === 'tabs') {
				for (const tab of n.tabs) stack.push(...tab.children);
			} else if ('children' in n && Array.isArray(n.children)) {
				stack.push(...(n.children as TemplateNode[]));
			} else if ('else' in n && Array.isArray(n.else)) {
				stack.push(...(n.else as TemplateNode[]));
			}
		}
		return out;
	}

	/**
	 * Fallback-form children (B-314): one editable `DvtRelation` per
	 * `def.children` entry, rendered straight from the definition. The node
	 * objects are memoised in the derived so a parent re-render does not
	 * hand `DvtRelation` a fresh template and re-fetch its rows.
	 */
	const fallbackChildRelations = $derived.by<
		Array<{ entry: EditableRelation; node: RelationNode }>
	>(() =>
		buildFallbackChildRelations(def, true).map((r) => ({
			entry: { rel: r.rel, label: r.label, qualifiedDoctype: r.qualifiedDoctype },
			node: r.node
		}))
	);

	/** All editable relations discovered in the form view template. Without a
	 *  template (the fallback form), every `def.children` entry becomes an
	 *  editable relation section instead (B-314) — the same drafts-bag
	 *  persistence serves both paths. */
	const editableRelations = $derived(
		view.template
			? collectEditableRelations(view.template)
			: fallbackChildRelations.map((r) => r.entry)
	);

	/** Fetch the relation doctype's parsed definition. Memoised per qualified id. */
	const childDefCache = $state<Map<string, DoctypeDef>>(new Map());
	async function loadChildDef(qualified: string): Promise<DoctypeDef | undefined> {
		const cached = childDefCache.get(qualified);
		if (cached) return cached;
		const raw = driver.getDoctypeDefinition(qualified);
		if (raw) {
			const def = parseDoctypeDef(raw);
			childDefCache.set(qualified, def);
			return def;
		}
		const reg = await DoctypeRegistry.cached(driver);
		const registered = reg.doctypeDefinitions.get(qualified);
		if (registered) {
			const def = parseDoctypeDef(registered);
			childDefCache.set(qualified, def);
			return def;
		}
		return undefined;
	}

	/**
	 * Persist every editable relation's drafts. Walks `values[DRAFTS_KEY]` to find
	 * the staged drafts, fetches each relation doctype's definition (cached after
	 * first load), and issues the per-child operations.
	 *
	 * Returns an empty array when the form has no editable relations; otherwise a
	 * per-relation outcome summary the caller surfaces in the error banner.
	 */
	async function persistChildDrafts(parentId: string): Promise<ChildSaveOutcome[]> {
		if (editableRelations.length === 0) return [];

		const bag = values[DRAFTS_KEY] as
			| Record<string, Array<{ id: string; values: Record<string, unknown>; deleted?: boolean }>>
			| undefined;
		if (!bag) return [];

		const outcomes: ChildSaveOutcome[] = [];
		for (const rel of editableRelations) {
			const drafts = bag[rel.rel];
			if (!drafts || drafts.length === 0) continue;
			const childDef = await loadChildDef(rel.qualifiedDoctype);
			if (!childDef) {
				outcomes.push({
					rel: rel.rel,
					label: rel.label,
					errors: { '-1': m.doc_form_schema_unavailable() },
					saved: 0
				});
				continue;
			}

			// Fetch current rows so `computeChildOps` can diff drafts against them.
			// The children REST route is keyed by the PARENT's domain + doctype
			// (`/Api/:parentDomain/:parentDoctype/:id/:rel`), not the child's.
			// `rel.qualifiedDoctype` is the child doctype name — using it here would
			// produce `/Api/.../:childDoctype/:parentId/:rel`, which the backend's
			// RestRoutes rejects with 404 "Unknown child". The parent's domain /
			// doctype come from `def` (already in scope — the parent doctype
			// definition).
			const parentDomain = def.domain;
			const parentDoctype = def.doctype;
			let existing: Array<{ id: string; data: Record<string, unknown> }> = [];
			try {
				const res = await driver
					.domain(parentDomain)
					.doctype(parentDoctype)
					.doc(parentId)
					.children(rel.rel)
					.list({ items: 200 });
				existing = (
					res.data as unknown as Array<{
						meta: { id: string };
						data: Record<string, unknown>;
					}>
				).map((r) => ({ id: r.meta.id, data: r.data ?? {} }));
			} catch {
				// Swallow — we proceed with an empty existing set; new rows create
				// fresh children, and update/delete diffs no-op when a row is gone.
				// Most rows in an edit form were seeded from `DvtRelation`'s own list,
				// so this is only a fallback for the unusual case where the listing
				// has been pruned between load and save.
			}

			const ops = computeChildOps(drafts, existing, childDef);
			const outcome: ChildSaveOutcome = {
				rel: rel.rel,
				label: rel.label,
				errors: {},
				saved: 0
			};
			for (const op of ops) {
				try {
					const childColl = driver
						.domain(parentDomain)
						.doctype(parentDoctype)
						.doc(parentId)
						.children(rel.rel);
					if (op.op === 'create') {
						await childColl.create(op.content);
						outcome.saved++;
					} else if (op.op === 'update') {
						await childColl.doc(op.id).update(op.patch);
						outcome.saved++;
					} else {
						await childColl.doc(op.id).delete();
						outcome.saved++;
					}
				} catch (e) {
					outcome.errors[op.op === 'create' ? '-1' : op.id] = errorMessage(
						e,
						m.common_save_failed()
					);
				}
			}
			outcomes.push(outcome);
		}
		return outcomes;
	}
</script>

<svelte:head>
	<title>{headerTitle}</title>
</svelte:head>

<div class="doctype-form">
	<DoctypeHeader
		title={headerTitle}
		color={def.color}
		{backHref}
		backLabel={def.doctype}
		version={mode === 'edit' ? doc?.meta.version : undefined}
	>
		{#snippet actions()}
			<Button href={backHref} variant="ghost" size="sm" disabled={saving}
				>{m.common_cancel()}</Button
			>
			<Button variant="primary" size="sm" disabled={saving} onclick={handleSave}>
				{#snippet iconLeft()}
					<Save size={14} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{saveLabel}
			</Button>
		{/snippet}
	</DoctypeHeader>

	{#if errorMsg}
		<AlertBanner message={errorMsg} details={generalErrors.map((e) => e.message)} />
	{/if}

	<div class="doctype-form-body">
		<div class="doctype-form-content">
			{#if isChildCreate}
				<div class="parent-picker">
					<ReferencePicker
						label={m.doc_form_parent_label({ doctype: def.member_of ?? '' })}
						helper={m.doc_form_parent_helper({ doctype: def.member_of ?? '' })}
						required
						doctype={parentQualified ?? undefined}
						{driver}
						bind:value={parentValue}
						error={parentPickerError}
						disabled={saving}
					/>
				</div>
			{/if}
			{#if view.template}
				<DocumentViewTemplate
					template={view.template}
					document={mode === 'create' ? emptyDoc : (doc as DocumentResponse)}
					{values}
					{def}
					{fieldErrors}
					{registerFieldStage}
					{driver}
				/>
			{:else}
				<div class="fallback-form">
					{#each fallbackFields as field (field.key)}
						{#if field.type === 'boolean'}
							<Toggle
								label={field.title ?? humanize(field.key)}
								error={fieldError(field.key)}
								bind:checked={values[field.key] as boolean}
							/>
						{:else if field.type === 'enum'}
							<Select
								label={field.title ?? humanize(field.key)}
								required={field.required}
								placeholder={m.doc_form_select_placeholder()}
								options={(field.values ?? []).map((v) => ({
									value: v.key,
									label: v.label ?? humanize(v.key)
								}))}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string}
							/>
						{:else if field.type === 'longtext'}
							<label class="fallback-label" for="ff-{field.key}"
								>{field.title ?? humanize(field.key)}</label
							>
							<textarea
								id="ff-{field.key}"
								class="fallback-longtext"
								class:fallback-longtext-err={fieldError(field.key)}
								rows="5"
								aria-invalid={fieldError(field.key) ? true : undefined}
								bind:value={values[field.key] as string}></textarea>
							{#if fieldError(field.key)}
								<span class="fallback-err" role="alert">{fieldError(field.key)}</span>
							{/if}
						{:else if field.type === 'duration'}
							<DurationInput
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								bind:value={values[field.key] as number | ''}
							/>
						{:else if field.type === 'datetime'}
							<DatetimePicker
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string}
							/>
						{:else if field.type === 'date'}
							<DatetimePicker
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								granularity="date"
								bind:value={values[field.key] as string}
							/>
						{:else if field.type === 'period'}
							<PeriodPicker
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								mode="datetime"
								bind:value={values[field.key] as PeriodValue}
							/>
						{:else if field.type === 'dateperiod'}
							<PeriodPicker
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								mode="date"
								bind:value={values[field.key] as PeriodValue}
							/>
						{:else if field.type === 'money'}
							<MoneyInput
								label={field.title ?? humanize(field.key)}
								required={field.required}
								preferredCurrency={field.currency}
								error={fieldError(field.key)}
								bind:value={values[field.key] as MoneyValue | ''}
							/>
						{:else if field.type === 'reference' && field.collection}
							<!-- Collection reference — stores a JSON array of qualified ids,
							     edited as a chip list, never as raw text. -->
							<ReferenceListEditor
								label={field.title ?? humanize(field.key)}
								required={field.required}
								doctype={refTargetDoctype(field)}
								filter={field.filter}
								{driver}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string[]}
							/>
						{:else if field.type === 'array' && field.items?.type === 'reference'}
							<!-- Array-of-reference stores the same token array (the show
							     side renders it through the reference kind) — same editor,
							     with the target declared on the item definition. -->
							<ReferenceListEditor
								label={field.title ?? humanize(field.key)}
								required={field.required}
								doctype={refTargetDoctype(field.items)}
								filter={field.items.filter}
								{driver}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string[]}
							/>
						{:else if field.type === 'object' || field.type === 'array' || field.type === 'dictionary'}
							<StructuredInput
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								{field}
								id="ff-{field.key}"
								bind:value={values[field.key]}
								onvaliditychange={(ok) => setStructuredValidity(field.key, ok)}
							/>
						{:else if field.type === 'secret'}
							<DvtInputSecret
								template={secretNode(field)}
								document={mode === 'create' ? emptyDoc : (doc as DocumentResponse)}
								{values}
								{def}
								{fieldErrors}
								{registerFieldStage}
							/>
						{:else if field.type === 'url'}
							<Input
								label={field.title ?? humanize(field.key)}
								required={field.required}
								prefix={urlAdornment(
									typeof values[field.key] === 'string' ? (values[field.key] as string) : undefined
								)}
								error={fallbackFieldError(field.key)}
								oninput={() => delete urlBlurErrors[field.key]}
								onchange={() => commitFallbackUrl(field.key)}
								bind:value={values[field.key] as string}
							/>
						{:else if field.type === 'reference' && !field.collection}
							<!-- Single-value references only: the picker binds one scalar.
							     A collection reference binds the chip list editor above. -->
							<ReferencePicker
								label={field.title ?? humanize(field.key)}
								required={field.required}
								doctype={refTargetDoctype(field)}
								filter={field.filter}
								{driver}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string}
							/>
						{:else}
							<Input
								type={field.type === 'integer' ? 'number' : 'text'}
								label={field.title ?? humanize(field.key)}
								required={field.required}
								error={fieldError(field.key)}
								bind:value={values[field.key] as string}
							/>
						{/if}
					{/each}
					{#each fallbackChildRelations as rel (rel.entry.rel)}
						<DvtRelation
							template={rel.node}
							document={mode === 'create' ? emptyDoc : (doc as DocumentResponse)}
							{driver}
							{values}
							{def}
							{fieldErrors}
						/>
					{/each}
				</div>
			{/if}
		</div>
	</div>
</div>

<style>
	/* The form grows naturally; AppShell's `.main` owns the page scrollbar.
	   The content wrapper (not the scroll container) caps the line length so
	   inputs stay usable on wide screens. */
	.doctype-form {
		position: relative;
		min-height: 100%;
		display: flex;
		flex-direction: column;
	}

	.doctype-form-body {
		flex: 1;
		padding: 24px;
	}

	.doctype-form-content {
		max-width: 1040px;
	}

	/* ── Fallback form (no `kind: form` template) ── */
	.fallback-form {
		display: flex;
		flex-direction: column;
		gap: 14px;
	}

	/* Composition parent picker — sits above the template/fallback form. */
	.parent-picker {
		margin-bottom: 14px;
	}

	.fallback-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.fallback-longtext {
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		resize: vertical;
		min-height: 80px;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.fallback-longtext:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.fallback-longtext-err {
		border-color: var(--danger);
	}

	.fallback-longtext-err:focus {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	.fallback-err {
		font-size: 11.5px;
		color: var(--danger);
		margin-top: 2px;
	}
</style>
