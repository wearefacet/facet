<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DoctypeDefinitionRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import DoctypeFieldList from './DoctypeFieldList.svelte';
	import DoctypeFieldEditor from './DoctypeFieldEditor.svelte';
	import DoctypeEditorHeader from './DoctypeEditorHeader.svelte';
	import DoctypeChildrenTab from './DoctypeChildrenTab.svelte';
	import DoctypeActionsTab from './DoctypeActionsTab.svelte';
	import DoctypeLogicTab from './DoctypeLogicTab.svelte';
	import DoctypeSettingsTab from './DoctypeSettingsTab.svelte';
	import DoctypeViewsTab from './DoctypeViewsTab.svelte';
	import { nextUniqueKey } from '$lib/doctype/keys.js';
	import { defaultFilterCapabilities } from '$lib/doctype/capabilities.js';
	import { createIconPicker } from '$lib/doctype/iconPicker.svelte.js';
	import {
		parseDoctypeDef,
		type DoctypeDef,
		type FieldDef,
		type ActionDef,
		type ChildDef,
		type ArgDef
	} from '$lib/doctype/types.js';
	import { serializeDoctypeDef } from '$lib/doctype/serialize.js';
	import { parseExportedSymbols } from '$lib/doctype/lua-symbols.js';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { untrack } from 'svelte';
	import { apiFetch } from '$lib/session.svelte';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import { createSaveFlash } from '$lib/utils/saveFlash.svelte.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { tagsInUse } from './domainGrants.js';
	import { VIEW_KINDS, type ViewKind } from '$lib/doctype/previewDocument.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import * as m from '$lib/paraglide/messages';

	type Tab = 'general' | 'fields' | 'children' | 'actions' | 'logic' | 'views';

	let {
		registry,
		qualifiedName,
		readonly = false,
		tab = 'general',
		allowMetadataEdit = false,
		selectedFieldKey,
		selectedViewKey,
		views: viewsProp = {},
		viewIds: viewIdsProp = {},
		recordsHref
	}: {
		/** Doctype-definition registry. Satisfied by `MockDataDriver` (stories)
		 *  or `DoctypeRegistry` wrapping a real `DocumentDataDriver` (app). */
		registry: DoctypeDefinitionRegistry;
		/** Qualified doctype name, e.g. "crm.Deal" */
		qualifiedName: string;
		/** When true, disables all shape-change controls and shows a
		 *  "Create draft" banner. Used in the Configure shell where the
		 *  doctype belongs to a published domain. */
		readonly?: boolean;
		/** Active tab — URL-driven via the Builder route. The Configure shell
		 *  relies on the `general` default. */
		tab?: Tab;
		/** Published-surface escape hatch: when `readonly` is set together with
		 *  this flag, the General tab's presentation fields (label, plural
		 *  label, icon, color, description) stay editable and the header shows
		 *  Save — a metadata-only PUT on a live domain passes the same-version
		 *  guards. Shape fields still need a draft. */
		allowMetadataEdit?: boolean;
		/** Selected field key from the `?field=` query param. */
		selectedFieldKey?: string;
		/** Selected view kind from the `?view=` query param (views tab). */
		selectedViewKey?: string;
		/** `core.DocumentView` templates keyed by kind, loaded by the Builder
		 *  route. Absent kinds render a default fallback in the preview. */
		views?: Partial<Record<ViewKind, TemplateNode | null>>;
		/** `core.DocumentView` child ids keyed by kind, loaded by the same route
		 *  as `views`. The Views tab PATCHes a stored view by this id; a kind
		 *  without an id is created on first save. */
		viewIds?: Partial<Record<ViewKind, string>>;
		/** Workspace surface of this doctype's records (`/{domain}/{doctype}`).
		 *  Rendered as an `Open records` link in the header when set — the
		 *  Configure shell passes it so published doctypes stay reachable
		 *  from the config side (the workspace sidebar hides `core`). */
		recordsHref?: string;
	} = $props();

	// ── Parse the doctype definition ───────────────────────────────────────

	// The registry is treated as read-only (it will be fetched from the backend).
	// The editor works on an isolated copy so mutations never leak back into it.
	const rawDef = $derived(registry.doctypeDefinitions.get(qualifiedName));

	/**
	 * Single source of truth for the editor: a working copy of the doctype
	 * definition. Built once per `qualifiedName` change and never resynced.
	 */
	let doctypeDef = $state() as DoctypeDef | undefined;

	/**
	 * The raw record the working copy was built from. Kept so the save
	 * serializer can round-trip keys the editor does not surface (scopes,
	 * identifier, …). Set alongside `doctypeDef` so
	 * they stay in sync across `qualifiedName` changes.
	 */
	let rawDefPreserved = $state<Record<string, unknown> | undefined>(undefined);

	$effect(() => {
		const raw = rawDef;
		if (raw) {
			// `color` and `script` are optional on DoctypeDef; CodeEditor and ColorInput
			// declare `value = $bindable(...)` with a fallback, and Svelte 5 rejects
			// `bind:value={undefined}` when the prop has a fallback (props_invalid_value).
			// Coerce to '' on the working copy so the bindings never see undefined.
			// Normalize on a local before assigning to `doctypeDef` to avoid reading
			// `doctypeDef.*` inside this effect (which would form a read/write cycle).
			const parsed = parseDoctypeDef(structuredClone(raw));
			parsed.color ??= '';
			parsed.icon ??= '';
			parsed.label ??= '';
			parsed.plural_label ??= '';
			parsed.script ??= '';
			// The migrations section mutates the map in place; an empty map is
			// valid (the serializer drops it from the save body).
			parsed.migrations ??= {};
			// The document templates live in dedicated state: `display_name` is
			// not part of the typed `DoctypeDef`, and an empty input must save
			// as an absent key (see handleSave).
			displayNameTemplate = typeof raw['display_name'] === 'string' ? raw['display_name'] : '';
			searchTemplate = parsed.search ?? '';
			rawDefPreserved = structuredClone(raw);
			doctypeDef = parsed;
		} else {
			doctypeDef = undefined;
			rawDefPreserved = undefined;
		}
		selectedFieldRef = undefined;
	});

	// ── Tab state ──────────────────────────────────────────────
	//
	// The active tab is a prop derived from the URL (e.g. /Builder/_abc/Company/logic).
	// Tab switches navigate via `goto` so the URL reflects the user's location and
	// browser back/forward works. We hold a local copy so the UI updates
	// optimistically on click — `goto` is a no-op in Storybook, and even in the
	// app it resolves asynchronously; local state keeps the switch instant.
	// The effect below resyncs whenever the URL-driven prop changes (real
	// navigation, back/forward, deep-link load).

	// `activeTab` is a writable derived over the URL-driven `tab` prop: it
	// reads the prop until `selectTab` assigns an optimistic override, and a
	// real navigation (back/forward, deep-link) drops the override. (The old
	// `$state` + sync `$effect` pair tripped `svelte/prefer-writable-derived`.)
	let activeTab = $derived(untrack(() => tab));

	/** Presentation fields (label, plural label, icon, color, description) are
	 *  editable when the doctype is not readonly (Builder) or when the host
	 *  granted the published-surface metadata edit (`allowMetadataEdit`). */
	const metadataEditable = $derived(!readonly || allowMetadataEdit);

	// Tags already in use across this domain's doctypes — the field form's
	// suggestion chips. A shared label set keeps grants stable across
	// fields; free-form input stays the primary entry. Read straight from
	// the raw definitions (a full parse per def buys nothing here).
	const domainTagSuggestions = $derived.by(() => {
		const dot = qualifiedName.indexOf('.');
		const prefix = dot > 0 ? `${qualifiedName.slice(0, dot)}.` : '';
		if (!prefix) return [];
		const defs: { fields: { tags?: string[] }[] }[] = [];
		for (const [name, raw] of registry.doctypeDefinitions) {
			if (!name.startsWith(prefix)) continue;
			const fields = raw['fields'];
			if (!fields || typeof fields !== 'object') continue;
			defs.push({ fields: Object.values(fields) as { tags?: string[] }[] });
		}
		return tagsInUse(defs);
	});

	// ── Icon picker (general tab) ────────────────────────────────────────
	// Factory-owned instance; the general tab renders it (iconPicker.svelte.ts).
	const picker = createIconPicker();

	// Prime the icon picker's first page when the general tab opens, and when
	// the doctype changes. Subsequent typing re-queries.
	let iconPrimedFor = $state('');
	$effect(() => {
		if (activeTab !== 'general' || iconPrimedFor === qualifiedName) return;
		iconPrimedFor = qualifiedName;
		picker.search('');
	});

	// ── Document templates (general tab) ─────────────────────────────────
	// Jinja2 templates the backend renders at mutation time into the
	// projection's `display_name` / `search` columns. `display_name` is not
	// part of the typed `DoctypeDef`, so both templates live in dedicated
	// state; handleSave writes them onto the save body (set or delete).
	let displayNameTemplate = $state('');
	let searchTemplate = $state('');

	// ── Check notices (General tab) ──────────────────────────
	// `GET /Api/core/DocType/:id/check` is the authoring diagnostics
	// endpoint (backend `Doctype::Check`). Its informational defaults
	// notices tell the author what a missing template costs at runtime —
	// a doctype with no `search` template stays out of the cross-doctype
	// search endpoint. They render next to the template inputs they
	// describe. The call is diagnostic: any failure (403 on a published
	// doctype without update rights, 404, network) shows nothing.
	interface DoctypeCheckIssue {
		severity: 'info' | 'warning' | 'error';
		category: string;
		message: string;
		field?: string;
	}

	let checkNotices = $state<DoctypeCheckIssue[]>([]);
	let checkSeq = 0;
	// Bumped after every successful save, so a notice the save fixed
	// disappears without a reload.
	let checkToken = $state(0);

	$effect(() => {
		if (activeTab !== 'general') return;
		if (!doctypeDef) return;
		const name = qualifiedName;
		// The read registers the save counter as a dependency: a successful
		// save re-runs this fetch. The value itself is not used.
		const _token = checkToken;
		const seq = ++checkSeq;
		void loadCheckNotices(name, seq);
	});

	async function loadCheckNotices(name: string, seq: number) {
		try {
			const res = await apiFetch(`/Api/core/DocType/${encodeURIComponent(name)}/check`);
			if (seq !== checkSeq) return;
			if (!res.ok) {
				checkNotices = [];
				return;
			}
			const body = (await res.json()) as { data?: { issues?: DoctypeCheckIssue[] } };
			if (seq !== checkSeq) return;
			// Only the informational defaults notices fit here — the warning
			// issues stay on the domain Check tab, and the view-kind notices
			// describe the Views tab, not the templates.
			checkNotices = (body.data?.issues ?? []).filter(
				(issue) => issue.severity === 'info' && issue.category === 'defaults'
			);
		} catch {
			if (seq === checkSeq) checkNotices = [];
		}
	}

	// The view kind shown in the Views tab. URL-driven via the `?view=` query
	// param so the assistant can deep-link to a specific view kind. Falls back
	// to the first kind when the param is absent or not a valid kind.
	let selectedViewKind = $state<ViewKind>(VIEW_KINDS[0]);
	$effect(() => {
		const key = selectedViewKey;
		if (key && (VIEW_KINDS as readonly string[]).includes(key)) {
			selectedViewKind = key as ViewKind;
		}
	});

	// ── Field selection ────────────────────────────────────────────────────
	//
	// Selection is tracked by object reference (not by key string) so that
	// renaming a field's key in the editor does NOT lose the selection.
	// Both cases are handled:
	//   - Renaming the currently-selected field → same object, selection persists
	//   - Renaming a *different* field          → same object, selection persists

	let selectedFieldRef: FieldDef | undefined = $state(undefined);
	let selectedField: FieldDef | undefined = $derived(
		doctypeDef?.fields.find((f) => f === selectedFieldRef)
	);

	// Sync selection from the `?field=` query param when it changes (e.g. on
	// initial deep-link load or browser navigation). The query param stores the
	// field key; we resolve it to the object reference for reactive tracking.
	$effect(() => {
		const key = selectedFieldKey;
		if (key === undefined || !doctypeDef) return;
		const match = doctypeDef.fields.find((f) => f.key === key);
		if (match && match !== selectedFieldRef) {
			selectedFieldRef = match;
		}
	});

	function selectField(field: FieldDef) {
		selectedFieldRef = field;
		// Update the ?field= query param without polluting browser history.
		setSearchParams({ field: field.key || null });
	}

	function selectView(kind: ViewKind) {
		selectedViewKind = kind;
		// Update the ?view= query param without polluting browser history.
		setSearchParams({ view: kind });
	}

	function selectTab(newTab: Tab) {
		activeTab = newTab;
		if (readonly) return;
		const dot = qualifiedName.indexOf('.');
		goto(
			resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
				draftDomain: qualifiedName.slice(0, dot),
				doctype: qualifiedName.slice(dot + 1),
				tab: newTab
			})
		);
	}

	function addField() {
		if (!doctypeDef || readonly) return;
		const keys = doctypeDef.fields.map((f) => f.key);
		const key = nextUniqueKey(keys, 'new_field');
		// A new field starts filterable by default (the type's typical
		// capabilities) — a field without capabilities derives no operators
		// and is invisible to every filter surface.
		const field: FieldDef = {
			key,
			type: 'string',
			filters: [...defaultFilterCapabilities('string')]
		};
		doctypeDef.fields.push(field);
		doctypeDef.fields.sort((a, b) => a.key.localeCompare(b.key));
		// Read back through the proxy so the stored proxy identity matches
		// the reference held in selectedFieldRef (avoids state_proxy_equality_mismatch).
		selectedFieldRef = doctypeDef.fields.find((f) => f.key === key);
	}

	function deleteField() {
		if (!doctypeDef || !selectedFieldRef || readonly) return;
		doctypeDef.fields = doctypeDef.fields.filter((f) => f !== selectedFieldRef);
		selectedFieldRef = doctypeDef.fields[0];
	}

	const fieldCount = $derived(doctypeDef?.fields.length ?? 0);
	const childCount = $derived(doctypeDef?.children.length ?? 0);
	const actionCount = $derived(doctypeDef?.actions.length ?? 0);

	// The stored `core.DocumentView` templates and their child ids. The route
	// load seeds them; a save in the Views tab writes the new maps back through
	// these writable deriveds, so the tab badge (and the next tab open) reflect
	// the write without a reload — a tab switch does not re-run the layout load.
	let views = $derived(untrack(() => viewsProp));
	let viewIds = $derived(untrack(() => viewIdsProp));

	/** Take the Views tab's post-save maps: they are the new source of truth
	 *  for the badge and for the tab's own props. */
	function handleViewsSaved(
		nextViews: Partial<Record<ViewKind, TemplateNode | null>>,
		nextIds: Partial<Record<ViewKind, string>>
	) {
		views = nextViews;
		viewIds = nextIds;
	}

	const viewCount = $derived(VIEW_KINDS.filter((k) => views[k] != null).length);

	// ── Children tab ────────────────────────────────────────────────────
	function addChild() {
		if (!doctypeDef || readonly) return;
		const keys = doctypeDef.children.map((c) => c.key);
		const key = nextUniqueKey(keys, 'new_child');
		doctypeDef.children.push({ key, doctype: '', collection: true });
		doctypeDef.children.sort((a, b) => a.key.localeCompare(b.key));
	}

	function deleteChild(child: ChildDef) {
		if (!doctypeDef || readonly) return;
		doctypeDef.children = doctypeDef.children.filter((c) => c !== child);
	}

	// ── Actions tab ─────────────────────────────────────────────────────
	function addAction() {
		if (!doctypeDef || readonly) return;
		const keys = doctypeDef.actions.map((a) => a.key);
		const key = nextUniqueKey(keys, 'new_action');
		doctypeDef.actions.push({ key, args: [] });
		doctypeDef.actions.sort((a, b) => a.key.localeCompare(b.key));
	}

	function deleteAction(action: ActionDef) {
		if (!doctypeDef || readonly) return;
		doctypeDef.actions = doctypeDef.actions.filter((a) => a !== action);
	}

	function addArg(action: ActionDef) {
		if (readonly) return;
		const keys = action.args.map((arg) => arg.key);
		const key = nextUniqueKey(keys, 'new_arg');
		action.args.push({ key, type: 'string' });
	}

	function deleteArg(action: ActionDef, arg: ArgDef) {
		if (readonly) return;
		action.args = action.args.filter((a) => a !== arg);
	}

	// ── Logic tab ───────────────────────────────────────────────────────
	// Symbols reflect exactly what the Lua script exports on its module table
	// — not a wishlist derived from the doctype definition.
	const exportedSymbols = $derived(parseExportedSymbols(doctypeDef?.script ?? '', doctypeDef));

	// ── Danger zone ──────────────────────────────────────────────────────
	// Soft-deletes the doctype via `DELETE /Api/core/DocType/:id` (same
	// endpoint family as the assistant's `delete_doctype` tool, which calls
	// `Document::Delete` on `core.DocType`). On success the cached registry
	// entry is dropped and the user is returned to the domain's doctype list.
	let deleting = $state(false);
	let deleteError = $state<string | undefined>(undefined);

	async function handleDelete() {
		if (!doctypeDef || !qualifiedName || readonly) return;
		if (deleting) return;

		deleting = true;
		deleteError = undefined;
		try {
			const { apiFetch } = await import('$lib/session.svelte');
			const res = await apiFetch(`/Api/core/DocType/${encodeURIComponent(qualifiedName)}`, {
				method: 'DELETE'
			});
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				deleteError = body.error ?? m.builder_draft_failed_status({ status: res.status });
				return;
			}
			const reg = registry as unknown as {
				doctypeDefinitions?: Map<string, Record<string, unknown>>;
			};
			reg.doctypeDefinitions?.delete(qualifiedName);
			await goto(
				resolve('/Builder/[draftDomain]/(editor)/doctypes', { draftDomain: doctypeDef.domain })
			);
		} catch (err) {
			deleteError = errorMessage(err);
		} finally {
			deleting = false;
		}
	}

	// ── Create draft from published domain (readonly mode) ───────────────
	//
	// Branches a draft domain from the published domain that owns this
	// doctype, then navigates to the Builder so the user can edit the
	// schema. Uses the same `POST /Api/core/Domain/{sourceId}/draft`
	// endpoint as the root layout's `handleEditDomain`.
	let draftCreating = $state(false);

	async function handleCreateDraft() {
		if (!doctypeDef || draftCreating) return;
		draftCreating = true;
		try {
			const domainId = doctypeDef.domain;
			const doctypeLabel = doctypeDef.doctype;
			const res = await apiFetch(`/Api/core/Domain/${encodeURIComponent(domainId)}/draft`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: '{}'
			});
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				flash.failed(body.error ?? m.builder_draft_failed_status({ status: res.status }));
				return;
			}
			const newDraft = await res.json();
			const newDraftId = newDraft.id ?? newDraft.meta?.id;
			await goto(
				resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
					draftDomain: newDraftId,
					doctype: encodeURIComponent(doctypeLabel),
					tab: 'fields'
				})
			);
		} catch (err) {
			flash.failed(errorMessage(err));
		} finally {
			draftCreating = false;
		}
	}

	// ── Save ───────────────────────────────────────────────────────────────
	//
	// Persists the working copy via `PUT /Api/core/DocType/:id` (the endpoint
	// is shared with the assistant's `update_doctype` tool). The body is the
	// full doctype definition; `serializeDoctypeDef` rebuilds the JSON shape
	// the backend expects and passes through keys the editor cannot edit so a
	// save does not silently clobber existing config.
	//
	// On a published domain (`readonly` + `allowMetadataEdit`) the save is a
	// metadata-only same-version edit: label, plural label, icon, color and
	// description are presentation metadata the live version gate does not
	// shape-check. The live guard rejects a body that carries `migrations`
	// (the backend merges the stored map itself, B-301), so the transport
	// body strips it — the cached registry entry keeps the stored map so
	// other readers never see it vanish.
	//
	// `savedFlash` (createSaveFlash) mirrors `DomainEditor.handleSave` so the
	// two surfaces share the same affordance. On success we invalidate the
	// registry cache (and re-run SvelteKit loaders) so the next read reflects
	// the saved state.

	const flash = createSaveFlash();

	async function handleSave() {
		if (!doctypeDef || !qualifiedName) return;
		if (readonly && !allowMetadataEdit) return;
		if (flash.status === 'saving') return;

		flash.saving();
		try {
			const { apiFetch } = await import('$lib/session.svelte');
			const body = serializeDoctypeDef(doctypeDef, rawDefPreserved ?? {});
			// Template keys ride the save body explicitly: a filled input writes
			// the template, an empty one deletes the key. Absent is the backend's
			// empty state (round-trip spec; `''` would store an empty template).
			// A whitespace-only input counts as empty. The trim guards the
			// emptiness only — the stored template keeps the typed form.
			if (displayNameTemplate.trim()) body.display_name = displayNameTemplate;
			else delete body.display_name;
			if (searchTemplate.trim()) body.search = searchTemplate;
			else delete body.search;
			// Published-domain save: same-version live guard forbids a carried
			// migrations map. The Builder (draft domains) skips that guard, so
			// the strip applies to the readonly path only.
			if (readonly) delete body.migrations;
			const res = await apiFetch(`/Api/core/DocType/${encodeURIComponent(qualifiedName)}`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(body)
			});
			if (!res.ok) {
				const errBody = await res.json().catch(() => ({}));
				const message = errBody.error ?? m.builder_draft_failed_status({ status: res.status });
				// The backend answers 422 when the submitted definition diffs empty.
				// The stored definition already matches the working copy, so this is
				// a neutral outcome. Flash success, not a failure.
				if (
					res.status === 422 &&
					typeof message === 'string' &&
					message.startsWith('No changes detected')
				) {
					flash.saved();
					return;
				}
				flash.failed(message);
				return;
			}
			patchCachedRegistryEntry(
				readonly && rawDefPreserved?.migrations
					? { ...body, migrations: rawDefPreserved.migrations }
					: body
			);
			flash.saved();
			// A save can add or remove a template — the notices refresh so a
			// fixed one disappears at once.
			checkToken += 1;
		} catch (err) {
			flash.failed(errorMessage(err));
		}
	}

	function patchCachedRegistryEntry(savedBody: Record<string, unknown>): void {
		const reg = registry as unknown as {
			doctypeDefinitions?: Map<string, Record<string, unknown>>;
		};
		reg.doctypeDefinitions?.set(qualifiedName, savedBody);
	}
</script>

{#if doctypeDef}
	<div class="page">
		<div class="dhead">
			<DoctypeEditorHeader
				domain={doctypeDef.domain}
				doctypeLabel={doctypeDef.label?.trim() || doctypeDef.doctype}
				{qualifiedName}
				icon={doctypeDef.icon}
				color={doctypeDef.color}
				aggregateRoot={doctypeDef.aggregate_root}
				schemaVersion={doctypeDef.schema_version}
				{recordsHref}
				{readonly}
				metadataEdit={readonly && allowMetadataEdit}
				{flash}
				{draftCreating}
				onsave={handleSave}
				oncreatedraft={handleCreateDraft}
			/>

			<div class="dtabs">
				<button class:on={activeTab === 'general'} onclick={() => selectTab('general')}>
					{m.configure_doctypes_tab_general()}
				</button>
				<button class:on={activeTab === 'fields'} onclick={() => selectTab('fields')}>
					{m.configure_doctypes_tab_fields()} <span class="n">{fieldCount}</span>
				</button>
				<button class:on={activeTab === 'children'} onclick={() => selectTab('children')}>
					{m.configure_doctypes_tab_children()} <span class="n">{childCount}</span>
				</button>
				<button class:on={activeTab === 'actions'} onclick={() => selectTab('actions')}>
					{m.configure_doctypes_tab_actions()} <span class="n">{actionCount}</span>
				</button>
				<button class:on={activeTab === 'logic'} onclick={() => selectTab('logic')}>
					{m.configure_doctypes_tab_logic()} <span class="n">Lua</span>
				</button>
				<button class:on={activeTab === 'views'} onclick={() => selectTab('views')}>
					{m.configure_doctypes_tab_views()} <span class="n">{viewCount}</span>
				</button>
			</div>
		</div>

		<div class="content">
			<!-- ============ FIELDS ============ -->
			{#if activeTab === 'fields'}
				<div class="pane on">
					<div class="flayout">
						<DoctypeFieldList
							fields={doctypeDef.fields}
							{selectedField}
							{readonly}
							onselect={selectField}
							onadd={addField}
						/>
						<DoctypeFieldEditor
							field={selectedField}
							allFields={doctypeDef?.fields ?? []}
							tagSuggestions={domainTagSuggestions}
							domain={doctypeDef.domain}
							{readonly}
							ondelete={deleteField}
						/>
					</div>
				</div>

				<!-- ============ CHILDREN ============ -->
			{:else if activeTab === 'children'}
				<div class="pane on">
					<DoctypeChildrenTab
						children={doctypeDef.children}
						doctypeLabel={doctypeDef.doctype}
						{readonly}
						onadd={addChild}
						ondelete={deleteChild}
					/>
				</div>

				<!-- ============ ACTIONS ============ -->
			{:else if activeTab === 'actions'}
				<div class="pane on">
					<DoctypeActionsTab
						actions={doctypeDef.actions}
						{readonly}
						onadd={addAction}
						ondelete={deleteAction}
						onaddarg={addArg}
						ondeletearg={deleteArg}
					/>
				</div>

				<!-- ============ LOGIC (LUA) ============ -->
			{:else if activeTab === 'logic'}
				<div class="pane on">
					<DoctypeLogicTab
						bind:script={doctypeDef.script}
						doctypeLabel={doctypeDef.doctype}
						symbols={exportedSymbols}
						{readonly}
					/>
				</div>

				<!-- ============ GENERAL (identity + metadata) ============ -->
			{:else if activeTab === 'general'}
				<div class="pane on">
					<div class="general-col">
						<div class="general-main">
							<DoctypeSettingsTab
								name={doctypeDef.doctype}
								domain={doctypeDef.domain}
								{qualifiedName}
								bind:schemaVersion={doctypeDef.schema_version}
								bind:migrations={doctypeDef.migrations}
								{exportedSymbols}
								bind:color={doctypeDef.color}
								bind:icon={doctypeDef.icon}
								bind:label={doctypeDef.label}
								bind:pluralLabel={doctypeDef.plural_label}
								bind:description={doctypeDef.description}
								{picker}
								{metadataEditable}
								{readonly}
								{deleting}
								{deleteError}
								ondelete={handleDelete}
							/>
						</div>
						<section class="tmpl-sec">
							<div class="tmpl-inner">
								<h4>{m.configure_doctypes_templates_title()}</h4>
								<div class="tmpl-grid">
									<div class="f">
										<label for="dt-display-name">{m.configure_doctypes_display_name_label()}</label>
										<input
											id="dt-display-name"
											class="inp mono"
											type="text"
											bind:value={displayNameTemplate}
											placeholder={'{{ name }}'}
											disabled={!metadataEditable}
										/>
										<span class="lbl-hint">
											{m.configure_doctypes_display_name_helper()}
										</span>
									</div>
									<div class="f">
										<label for="dt-search">{m.configure_doctypes_search_label()}</label>
										<input
											id="dt-search"
											class="inp mono"
											type="text"
											bind:value={searchTemplate}
											placeholder={'{{ name }}'}
											disabled={!metadataEditable}
										/>
										<span class="lbl-hint">
											{m.configure_doctypes_search_helper()}
										</span>
									</div>
								</div>
								<!-- Stale-rows note (F02-03): the backend applies template
									edits to new writes only; existing rows keep the old
									display_name/search until a reproject runs. -->
								<p class="tmpl-stale-note">
									{m.configure_doctypes_templates_reproject_hint()}
								</p>
								{#if checkNotices.length > 0}
									<!-- Check notices from `/check` reuse the check-issue
										row pattern (category chip + message) — no new panel. -->
									<div class="tmpl-notices">
										<span class="notices-title">{m.configure_domains_check_notices_group()}</span>
										<ul>
											{#each checkNotices as notice, i (`${i}-${notice.category}`)}
												<li>
													<span class="cat">{notice.category}</span>
													<span class="msg">{notice.message}</span>
												</li>
											{/each}
										</ul>
									</div>
								{/if}
							</div>
						</section>
					</div>
				</div>

				<!-- ============ VIEWS ============ -->
			{:else if activeTab === 'views'}
				<div class="pane on">
					<DoctypeViewsTab
						def={doctypeDef}
						{views}
						{viewIds}
						{registry}
						{qualifiedName}
						{readonly}
						{selectedViewKind}
						onselect={selectView}
						onsaved={handleViewsSaved}
					/>
				</div>
			{/if}
		</div>
	</div>
{:else}
	<div class="not-found">
		<p>{m.errors_doctype_not_found({ name: qualifiedName })}</p>
	</div>
{/if}

<style>
	.page {
		display: flex;
		flex-direction: column;
		height: 100%;
		overflow: hidden;
	}

	.dhead {
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
		padding: 16px 24px 0;
		flex: none;
	}

	.dtabs {
		display: flex;
		gap: 0;
	}
	.dtabs button {
		padding: 9px 18px;
		border: none;
		background: transparent;
		font: inherit;
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
		cursor: pointer;
		border-bottom: 2px solid transparent;
		margin-bottom: -1px;
		transition: color 0.1s;
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}
	.dtabs button:hover {
		color: var(--text);
	}
	.dtabs button.on {
		color: var(--accent-ink);
		border-bottom-color: var(--accent);
	}
	.dtabs button .n {
		font-size: 10.5px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0 7px;
		line-height: 1.6;
	}
	.dtabs button.on .n {
		background: var(--accent-weak);
		border-color: var(--accent);
	}

	.content {
		flex: 1;
		overflow: hidden;
	}
	.pane {
		height: 100%;
		overflow: hidden;
	}
	.pane.on {
		display: block;
	}

	.flayout {
		display: grid;
		grid-template-columns: 220px 1fr;
		height: 100%;
	}

	/* General tab: the settings tab scrolls above; the document templates
	   stay pinned below so both template fields are always reachable. */
	.general-col {
		display: flex;
		flex-direction: column;
		height: 100%;
	}
	.general-main {
		flex: 1;
		min-height: 0;
	}
	.tmpl-sec {
		flex: none;
		border-top: 1px solid var(--border);
		background: var(--surface-2);
	}
	.tmpl-inner {
		max-width: 720px;
		padding: 16px 24px 20px;
	}
	.tmpl-sec h4 {
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0 0 13px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
	}
	.tmpl-grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 15px 18px;
	}
	.tmpl-grid .f {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.tmpl-grid label {
		font-size: 12.5px;
		font-weight: 600;
	}
	.tmpl-grid .lbl-hint {
		font-size: 11.5px;
		color: var(--text-3);
	}
	.tmpl-grid .inp {
		padding: 8px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		font: inherit;
		font-size: 13px;
		color: var(--text);
		width: 100%;
	}
	.tmpl-grid .inp.mono {
		font-family: var(--font-mono);
	}
	.tmpl-grid .inp:disabled {
		opacity: 0.55;
		cursor: not-allowed;
	}
	/* Stale-rows note under the template inputs — the backend applies
	   template edits to new writes only (doc/backend/doctype-system.md). */
	.tmpl-stale-note {
		margin: 12px 0 0;
		font-size: 11.5px;
		line-height: 1.5;
		color: var(--text-3);
	}
	/* Check notices under the template inputs — same row pattern as the
	   domain Check tab (category chip + message), sized for the section. */
	.tmpl-notices {
		margin-top: 12px;
	}
	.tmpl-notices .notices-title {
		display: block;
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
		margin-bottom: 6px;
	}
	.tmpl-notices ul {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.tmpl-notices li {
		display: flex;
		align-items: baseline;
		gap: 10px;
		padding: 4px 0;
		font-size: 12px;
		line-height: 1.45;
	}
	.tmpl-notices .cat {
		flex: none;
		font-family: var(--font-mono);
		font-size: 10px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
	}
	.tmpl-notices .msg {
		color: var(--text-2);
	}

	.not-found {
		padding: 24px 32px;
		font-size: 13px;
		color: var(--text-3);
	}
</style>
