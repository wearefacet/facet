<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import type { CollectionSurface, CollectionView } from '$lib/collectionView/types.js';
	import { page } from '$app/state';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import { isSortableField, type DoctypeDef } from '$lib/doctype/types.js';
	import { resolveColumnLabel } from '$lib/doctype/columnLabel.js';
	import { SYSTEM_TIMESTAMP_FIELD_DEFS } from '$lib/doctype/filters.js';
	import Table from '$lib/table/Table.svelte';
	import Calendar from '$lib/calendar/Calendar.svelte';
	import Kanban from '$lib/kanban/Kanban.svelte';
	import type { Column, ToolbarActionsArgs } from '$lib/table/types.js';
	import IconButton from '$lib/components/primitives/actions/IconButton.svelte';
	import Tabs from '$lib/components/primitives/navigation/Tabs.svelte';
	import CollectionViewEditor from './CollectionViewEditor.svelte';
	import RestoreButton from './RestoreButton.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import QuickViewHost from '$lib/components/primitives/surfaces/QuickViewHost.svelte';
	import { collectionViewsCache } from '$lib/datasource/clientCache.js';
	import { getPinnedCollectionViews, togglePinnedCollectionView } from '$lib/settings.svelte.js';
	import { collectionViewDeepLinkSlugs } from '$lib/collectionView/slug.js';

	let {
		driver,
		doctype,
		parentDocId,
		active = $bindable(0),
		pageSize = 25,
		/** Account id of the current user — needed to create personal views. */
		viewerId,
		/**
		 * Trash mode: list tombstones (`?deleted=true`) instead of live rows and
		 * render a Restore action per row. The owning page derives this from the
		 * `?deleted=` URL param (a mode, not a saved view). Defaults to the
		 * live listing.
		 */
		includeDeleted = false,
		/**
		 * Render the `core.CollectionView` tab strip. `false` gives a plain
		 * doctype listing: no tabs, no saved-view CRUD affordances, columns
		 * always from the doctype's fallback rule. For admin surfaces that
		 * standardize on the default table (e.g. `/Configure/access/accounts`).
		 */
		showTabs = true,
		/**
		 * Callback invoked to toggle a pinned view. When omitted the component
		 * reads and writes the settings store directly; inject it (together with
		 * `pinnedViewIds`) to control persistence externally (e.g. stories).
		 */
		onTogglePin = null,
		/**
		 * CollectionView projection ids the user pinned. Only read when
		 * `onTogglePin` is provided — otherwise the settings store is the live
		 * source of truth.
		 */
		pinnedViewIds = [],
		/**
		 * Bump to force a listing refetch (e.g. after an import job lands).
		 * The value rides the `datasource` derivation, so each change swaps the
		 * wrapper identity and the `Table` reloads from the backend.
		 */
		refreshSignal = 0,
		/**
		 * Initial filter map for the listing (`field__op` → value) — e.g. parsed
		 * from `filters[...]` URL params by the owning page (B-376). Forwarded
		 * to the `Table`; toolbar edits then own the map until the prop changes.
		 */
		filters = {},
		/** Right-aligned action affordances rendered beside the table toolbar's filters. */
		toolbarActions
	}: {
		/**
		 * Driver used to (a) fetch the `core.CollectionView` children of the
		 * parent `core.DocType` projection and (b) feed the document listing
		 * `Table` (including reference-filter comboboxes). Any `DataDriver`
		 * works — `MockDataDriver` in Storybook, `DocumentDataDriver` in the app.
		 */
		driver: DataDriver;
		/** The doctype being listed (drives fallback columns + the listing source). */
		doctype: DoctypeDef;
		/** Projection id of the parent `core.DocType` (e.g. `"crm.Deal"`). */
		parentDocId: string;
		/** Index of the currently active view tab. */
		active?: number;
		/** Rows per page, forwarded to the `Table`. */
		pageSize?: number;
		/** Account id of the current user — set as `owner_id` for personal views. */
		viewerId?: string;
		/** Trash mode — list tombstones and render a Restore action per row. */
		includeDeleted?: boolean;
		/** Render the saved-view tab strip. `false` = plain fallback-columns listing. */
		showTabs?: boolean;
		/** Toggle a pinned view. When omitted, the settings store is used. */
		onTogglePin?: ((viewId: string) => void | Promise<void>) | null;
		/** CollectionView projection ids the user pinned. */
		pinnedViewIds?: string[];
		/** Bump to force a listing refetch (e.g. after an import job lands). */
		refreshSignal?: number;
		/** Initial filter map for the listing (`field__op` → value). */
		filters?: Record<string, unknown>;
		/** Right-aligned action affordances rendered beside the table toolbar's
		 * filters. Forwarded to the `Table` unchanged; the snippet receives the
		 * table's current state (columns, compacted filters, sort). */
		toolbarActions?: import('svelte').Snippet<[ToolbarActionsArgs<Record<string, unknown>>]>;
	} = $props();

	/**
	 * The `?view=` deep-link slugs for a saved view. The URL token comes from
	 * the view's name — runtime view ids are opaque ULIDs, so the id itself
	 * carries no slug (convention-following fixture ids keep answering to
	 * their id slug too). See `$lib/collectionView/slug.ts`.
	 */
	function viewSlugs(item: ViewItem): string[] {
		return collectionViewDeepLinkSlugs(item.id, item.data.name);
	}

	async function defaultTogglePin(viewId: string): Promise<void> {
		await togglePinnedCollectionView(viewId);
	}

	/** The pinned-id list — the live settings store by default, or the prop. */
	const effectivePinned = $derived(
		onTogglePin ? (pinnedViewIds ?? []) : getPinnedCollectionViews()
	);
	const togglePin = $derived(onTogglePin ?? defaultTogglePin);
	const isPinned = (viewId: string): boolean => effectivePinned.includes(viewId);

	interface ViewItem {
		/** Projection id (child route id) — needed for PATCH on edit. */
		id: string;
		/** The CollectionView content. */
		data: CollectionView;
	}

	let views = $state<ViewItem[]>([]);
	let loading = $state(true);
	/** Bumped after a create/update so the views `$effect` refetches. */
	let refreshKey = $state(0);
	/** When set, the views fetch resolves by selecting the tab with this name. */
	let focusName = $state<string | null>(null);

	// Fetch saved views as children of the parent core.DocType projection.
	// Errors are non-fatal: the listing falls back to a synthetic "Default" tab.
	//
	// The collection_view list goes through the 60s TTL cache so multiple tabs /
	// detail components listing the same doctype share one round-trip. After a
	// create/update, `handleSaved` invalidates the entry for this `parentDocId`
	// and bumps `refreshKey` to refetch.
	$effect(() => {
		// Touch `refreshKey` so this re-runs after a create/update.
		void refreshKey;
		// Tab-less mode: no saved views exist and none are fetched — the listing
		// renders the fallback columns straight away.
		if (!showTabs) {
			views = [];
			loading = false;
			return;
		}
		const d = driver;
		const pid = parentDocId;
		loading = true;
		let cancelled = false;
		collectionViewsCache
			.get(pid, async () => {
				// The nested child list route takes no `page` / `items` — it serves
				// the whole child collection (see `RestRoutes.render_child_list`).
				const res = await d
					.domain('core')
					.doctype('DocType')
					.doc(pid)
					.children<CollectionView>('collection_view')
					.list();
				return res.data.map((item) => ({ id: item.meta.id, data: item.data as CollectionView }));
			})
			.then((items) => {
				if (cancelled) return;
				views = items as unknown as ViewItem[];
				if (focusName != null) {
					const idx = views.findIndex((v) => v.data.name === focusName);
					if (idx >= 0) active = idx;
					focusName = null;
					// Reflect the just-focused tab in the URL so the deep-link matches —
					// the focus path bypasses `selectView`, so it would otherwise leave
					// the URL pointing at the previous view.
					syncUrlToActive();
				}
			})
			.catch(() => {
				if (cancelled) return;
				views = [];
			})
			.finally(() => {
				if (!cancelled) loading = false;
			});
		return () => {
			cancelled = true;
		};
	});

	// Tab descriptors — one per view, or a synthetic "Default" when none exist.
	// We never auto-create a DB row for the Default tab.
	const tabs = $derived(
		views.length > 0
			? views.map((v) => ({ label: v.data.name }))
			: [{ label: m.list_view_default() }]
	);

	// Clamp the active index when the view set changes (e.g. after a refetch).
	// Gated on `!loading`: on first mount `views` is empty so `tabs` is just the
	// synthetic Default tab (length 1) — without this guard the clamp would
	// reset a legitimate parent-supplied `active` (e.g. active={1} for "Open")
	// back to 0 before the saved views arrive.
	$effect(() => {
		if (!loading && active > tabs.length - 1) active = 0;
	});

	// ── URL sync — `?view=<slug>` reflects and drives the active tab ───────
	//
	// The URL is the source of truth only when a `?view=` is present. This lets
	// a deep link (`/crm/Deal?view=open`) land on the right tab, and keeps the
	// browser back/forward in sync. When `?view=` is absent, the parent
	// `active` prop / click / `focusName` flow is left untouched — so stories
	// that pass `active={1}` (no router attached) keep working unchanged.
	$effect(() => {
		if (!showTabs) return;
		if (loading) return;
		const slug = page.url.searchParams.get('view');
		if (slug === null) return;

		let idx: number;
		if (views.length === 0) {
			// Only the synthetic Default tab exists; `?view=default` or empty
			// selects it, anything else falls back to it too (there is no other
			// tab to pick).
			idx = 0;
		} else {
			idx = views.findIndex((v) => viewSlugs(v).includes(slug));
		}
		if (idx >= 0 && idx !== active) active = idx;
	});

	/** The active view item, or null when on the synthetic Default tab. */
	const activeItem = $derived(views.length > 0 ? (views[active] ?? null) : null);
	/** Convenience: the active view data (or null). */
	const activeView = $derived(activeItem?.data ?? null);

	// Field types excluded from the synthetic "Default" tab's fallback
	// columns. Mirrors the backend seed rule in
	// `src/doctype/collection_view_defaults.cr` (CollectionView::Defaults):
	// the seeded "All Records" view keeps scalar primitive types plus
	// `reference`, and excludes blob/non-scalar types. `longtext` is a
	// primitive but its bulk makes it a poor default column. Both sides
	// must agree — every newly-created doctype's seeded view comes from
	// the backend rule; this frontend set is only hit when a doctype has
	// zero views (legacy data, or all views deleted).
	const skipTypes = new Set([
		'object',
		'array',
		'dictionary',
		'child',
		'data',
		'any',
		'file',
		'longtext',
		'secret'
	]);

	/** Fallback columns derived from the doctype's flat (top-level) fields. */
	function fallbackColumns(): Column<Record<string, unknown>>[] {
		const visible = doctype.fields.filter((f) => !skipTypes.has(f.type));
		const capped = visible.slice(0, 8);
		return capped.map((f) => ({
			key: f.key,
			label: f.title ?? f.key,
			sortable: isSortableField(f)
		}));
	}

	/**
	 * True when the backend list sort accepts the column key: a doctype
	 * field of a sortable type, or the system timestamp columns a saved
	 * view's config may carry. Unknown keys (removed fields) never sort —
	 * the backend answers `422 unknown_sort_field` for them.
	 */
	function isSortableColumnKey(key: string): boolean {
		const def =
			doctype.fields.find((f) => f.key === key) ??
			SYSTEM_TIMESTAMP_FIELD_DEFS.find((f) => f.key === key);
		return def !== undefined && isSortableField(def);
	}

	/** Columns shown in the active tab — from the view's config, or fallback.
	 * In trash mode a trailing Restore action column is appended.
	 *
	 * A saved column may carry no `label` — a view written by REST, an agent, or
	 * an import stores the key alone, while the editor resolves `key → title`
	 * before saving. `resolveColumnLabel` applies one rule at render time so both
	 * doors show the same header: `label ?? field.title ?? humanize(key)`. */
	const columns = $derived.by<Column<Record<string, unknown>>[]>(() => {
		const cfg = activeView?.config?.columns;
		const cols: Column<Record<string, unknown>>[] =
			cfg && cfg.length > 0
				? cfg.map((c) => ({
						key: c.key,
						label: resolveColumnLabel(doctype, c.key, c.label),
						width: c.width,
						sortable: isSortableColumnKey(c.key),
						// Inline boolean edit rides the view config; tombstone rows
						// cannot be updated, so trash mode never offers it.
						...(includeDeleted || c.editable !== true ? {} : { editable: true })
					}))
				: fallbackColumns();
		if (includeDeleted) {
			cols.push({
				key: '__restore',
				label: '',
				sortable: false,
				width: '180px',
				render: restoreCell
			});
		}
		return cols;
	});

	// One DataSource scoped to this doctype. Switching tabs only changes
	// columns (v1) — the data source and current page are preserved.
	const baseDatasource = $derived(
		driver.domain(doctype.domain).doctype<Record<string, unknown>>(doctype.doctype) as DataSource<
			Record<string, unknown>
		>
	);

	/** Bumped after a row restore so the trash table refetches (the Table
	 * reloads whenever its `datasource` input changes identity). */
	let restoreSeq = $state(0);

	// All modes re-wrap the base DataSource in a fresh object. The `Table`
	// reloads when its `datasource` input changes identity, so a `refreshSignal`
	// bump (import job landed), a `restoreSeq` bump (row restored), a trash-mode
	// toggle, or a driver/doctype swap must produce a new wrapper object.
	// B-106: live mode returned the base directly, so the signal bump kept the
	// same reference and the listing never reloaded.
	// Tradeoff: the wrapper rebuilds on every tracked dependency change, as
	// trash mode already did — these are the only tracked dependencies, so
	// unrelated reactivity causes no refetch.
	const datasource = $derived.by<DataSource<Record<string, unknown>>>(() => {
		void restoreSeq;
		// The import-completion signal: a bump re-wraps the source so the Table's
		// reload effect re-runs and the listing shows the imported rows.
		void refreshSignal;
		const base = baseDatasource;
		if (includeDeleted) {
			return {
				list: (params) => base.list({ ...params, includeDeleted: true }),
				create: (content) => base.create(content),
				doc: (id) => base.doc(id)
			};
		}
		return {
			list: (params) => base.list(params),
			create: (content) => base.create(content),
			doc: (id) => base.doc(id)
		};
	});

	const qualifiedDoctype = $derived(`${doctype.domain}.${doctype.doctype}`);

	const rowKey = (item: Record<string, unknown>) => String(item.id ?? '');

	function activeSlug(): string {
		const item = views.length > 0 ? views[active] : null;
		if (!item) return 'default';
		return viewSlugs(item)[0] ?? 'default';
	}

	/**
	 * Write the current active tab into `?view=<slug>` without pushing history
	 * (mirrors the `?field=` precedent). Shared by the click handler and the
	 * post-save focus path so the deep-link always matches the active tab.
	 */
	function syncUrlToActive(): void {
		setSearchParams({ view: activeSlug() });
	}

	function selectView(index: number) {
		active = index;
		syncUrlToActive();
	}

	/** Surface of a tab, for the lead icon. Defaults to `table`. */
	function tabSurface(index: number): CollectionSurface {
		const item = views.length > 0 ? views[index] : null;
		if (item?.data.surface === 'calendar') return 'calendar';
		if (item?.data.surface === 'kanban') return 'kanban';
		return 'table';
	}

	// ── Editor dialog state ────────────────────────────────────────────
	let editorOpen = $state(false);
	let editingView = $state<CollectionView | null>(null);
	let editingViewId = $state<string | null>(null);

	function openCreate() {
		editingView = null;
		editingViewId = null;
		editorOpen = true;
	}

	function openEdit() {
		// Only a real (saved) view can be edited — not the synthetic Default tab.
		if (!activeItem) {
			// On the Default tab: open the create form so the user can save
			// the fallback configuration as a new saved view.
			openCreate();
			return;
		}
		editingView = activeItem.data;
		editingViewId = activeItem.id;
		editorOpen = true;
	}

	function handleSaved(view: CollectionView) {
		editorOpen = false;
		editingView = null;
		// The cached children list is now stale — drop it so the refetch below
		// actually hits the backend.
		collectionViewsCache.invalidate(parentDocId);
		// Refetch views, then focus the saved/created view by its name.
		focusName = view.name;
		refreshKey++;
	}
</script>

<QuickViewHost {driver} rootDef={doctype} rootParentDocId={parentDocId}>
	{#snippet trigger(api)}
		<div class="listview">
			{#if showTabs}
				<Tabs {tabs} bind:active onchange={selectView}>
					{#snippet icon(i: number)}
						<span class="surface-icon" aria-hidden="true">
							{#if tabSurface(i) === 'calendar'}
								<svg
									viewBox="0 0 24 24"
									width="14"
									height="14"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
								>
									<rect x="3" y="4" width="18" height="18" rx="2" />
									<path d="M16 2v4M8 2v4M3 10h18" />
								</svg>
							{:else if tabSurface(i) === 'kanban'}
								<svg
									viewBox="0 0 24 24"
									width="14"
									height="14"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
								>
									<rect x="3" y="4" width="6" height="16" rx="1" />
									<rect x="10" y="4" width="6" height="11" rx="1" />
									<rect x="17" y="4" width="4" height="8" rx="1" />
								</svg>
							{:else}
								<svg
									viewBox="0 0 24 24"
									width="14"
									height="14"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
								>
									<path d="M3 6h18M3 12h18M3 18h18" />
								</svg>
							{/if}
						</span>
					{/snippet}
					{#snippet trailing()}
						<Can doctype="core.CollectionView" action="create">
							<button
								class="tab-add"
								aria-label={m.list_view_create()}
								title={m.list_view_create()}
								onclick={() => openCreate()}
							>
								<svg
									viewBox="0 0 24 24"
									width="15"
									height="15"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
								>
									<path d="M12 5v14M5 12h14" />
								</svg>
							</button>
						</Can>
						{#if activeItem}
							<IconButton
								label={isPinned(activeItem.id) ? m.list_view_unpin() : m.list_view_pin()}
								aria-pressed={isPinned(activeItem.id)}
								class={isPinned(activeItem.id) ? 'tab-pinned' : ''}
								onclick={() => togglePin(activeItem.id)}
							>
								<svg
									viewBox="0 0 24 24"
									width="15"
									height="15"
									fill={isPinned(activeItem.id) ? 'currentColor' : 'none'}
									stroke="currentColor"
									stroke-width="2"
								>
									<path d="M12 17v5" />
									<path
										d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6a1 1 0 0 0 0-2 1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1 1 1 0 0 0 0 2Z"
									/>
								</svg>
							</IconButton>
							{#if activeView || (!loading && views.length === 0)}
								<Can doctype="core.CollectionView" action={activeView ? 'update' : 'create'}>
									<IconButton
										label={activeView ? m.list_view_edit() : m.list_view_save_default()}
										onclick={() => openEdit()}
									>
										<svg
											viewBox="0 0 24 24"
											width="15"
											height="15"
											fill="none"
											stroke="currentColor"
											stroke-width="2"
										>
											<path d="M12 20h9" />
											<path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
										</svg>
									</IconButton>
								</Can>
							{/if}
						{/if}
					{/snippet}
				</Tabs>
			{/if}

			{#if loading}
				<div class="listview-loading">{m.list_views_loading()}</div>
			{:else if activeView?.surface === 'calendar' && activeView.config?.calendar}
				<Calendar
					{driver}
					{doctype}
					config={activeView.config.calendar}
					onChipClick={(id) => {
						if (typeof id === 'string' && id.length > 0) api.openRootDoc(id);
					}}
				/>
			{:else if activeView?.surface === 'kanban' && activeView.config?.kanban}
				<Kanban
					{driver}
					{doctype}
					config={activeView.config.kanban}
					onCardClick={(id) => api.openRootDoc(id)}
				/>
			{:else}
				<Table
					{datasource}
					{columns}
					{rowKey}
					{pageSize}
					{doctype}
					{driver}
					{filters}
					{toolbarActions}
					onRowClick={includeDeleted
						? undefined
						: (row) => {
								const id = row.id;
								if (typeof id === 'string' && id.length > 0) api.openRootDoc(id);
							}}
					onReferenceClick={api.openReference}
				/>
			{/if}
		</div>
	{/snippet}
</QuickViewHost>

<!-- Trailing cell renderer for the trash-mode Restore action column.
	 Referenced from the `columns` derivation in the script. -->
{#snippet restoreCell(item: Record<string, unknown>, _col: Column<Record<string, unknown>>)}
	{@const id = item.id}
	{#if typeof id === 'string' && id.length > 0}
		<RestoreButton
			doctype={qualifiedDoctype}
			doc={datasource.doc(id)}
			onRestored={() => {
				restoreSeq += 1;
			}}
		/>
	{/if}
{/snippet}

{#if editorOpen}
	<CollectionViewEditor
		{driver}
		{doctype}
		{parentDocId}
		view={editingView}
		viewId={editingViewId ?? undefined}
		{viewerId}
		onclose={() => {
			editorOpen = false;
			editingView = null;
			editingViewId = null;
		}}
		onsaved={handleSaved}
	/>
{/if}

<style>
	/* ── List view — tab row renders through the shared Tabs component ── */
	.listview {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		overflow: hidden;
	}

	/* Lead icon rendered through the Tabs `icon` snippet. The tab-on class
	   lives on the tab button rendered inside Tabs, so scope through :global. */
	.surface-icon {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: var(--text-3);
		flex: none;
		transition: color 0.12s;
	}

	:global(.tab-on) .surface-icon {
		color: var(--accent-ink);
	}

	.tab-add {
		width: 34px;
		height: 34px;
		align-self: center;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		color: var(--text-3);
		border: none;
		background: none;
		border-radius: var(--r);
		cursor: pointer;
		flex-shrink: 0;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.tab-add:hover {
		background: var(--sunken);
		color: var(--accent-ink);
	}

	.tab-add:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	:global(.tab-pinned) {
		color: var(--accent-ink);
	}

	:global(.tab-pinned svg) {
		transform: rotate(45deg);
	}

	.listview-loading {
		padding: 32px 14px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
	}
</style>
