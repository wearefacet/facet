<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ListView from './ListView.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import ConfirmDialog from '$lib/components/primitives/surfaces/ConfirmDialog.svelte';
	import * as m from '$lib/paraglide/messages';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import { resolveColumnLabel } from '$lib/doctype/columnLabel.js';
	import Table from '$lib/table/Table.svelte';
	import type { Column } from '$lib/table/types.js';
	import type { DataDriver, Domain } from '$lib/datasource/driver.js';
	import type { DataSource, DocumentRef } from '$lib/datasource/interface.js';

	// ── F10-06 fixture: a saved column without a `label` ──────────────────────
	//
	// A view written by REST, an agent, or an import stores the column `key`
	// alone. `label` is optional in the schema, so `ListView` resolves the
	// header at render time as `label ?? field.title ?? humanize(key)`. The
	// story drives `resolveColumnLabel` for the saved-column shape, and the
	// `Table` below renders the resolved headers.
	const bareDealDef: DoctypeDef = {
		doctype: 'Deal',
		domain: 'crm',
		fields: [
			{ key: 'title', type: 'string', title: 'Deal Title' },
			{ key: 'value', type: 'money', title: 'Deal Value', currency: 'USD' },
			{ key: 'probability', type: 'integer', title: 'Probability' },
			{ key: 'lost_reason', type: 'string' }
		],
		children: [],
		actions: []
	};
	// One column per fallback step: a declared title, a declared title, and a
	// key with no declared title (the humanized form). `label` is left out, the
	// shape a REST or import write stores.
	const bareDealColumns: Column<Record<string, unknown>>[] = (
		['title', 'value', 'probability', 'lost_reason'] as const
	).map((key) => ({ key, label: resolveColumnLabel(bareDealDef, key, undefined) }));
	const bareDealDs = new MockDataSource<Record<string, unknown>>('crm', 'Deal', [
		{
			id: 'crm.Deal.1',
			title: 'Acme Corp — Platform License',
			value: { value: '120000', currency: 'USD' },
			probability: 60,
			lost_reason: ''
		}
	]);

	// Single mock driver seeded with all fixtures (doctype defs + documents,
	// including the core.CollectionView children of crm.Deal).
	const driver = createMockDriver();

	// Separate driver for the TrashMode story: tombstoning a fixture document
	// on the shared driver would leak into every other story. Mock mutations
	// run synchronously, so the delete lands before the story mounts.
	const trashDriver = createMockDriver();
	void trashDriver.domain('crm').doctype('Deal').doc('crm.Deal.1').delete();

	function defFor(qualified: string) {
		const raw = driver.getDoctypeDefinition(qualified);
		if (!raw) throw new Error(`Missing doctype definition for ${qualified}`);
		return parseDoctypeDef(raw);
	}

	const dealDef = defFor('crm.Deal');
	const companyDef = defFor('crm.Company');
	const contactDef = defFor('crm.Contact');

	/** Unrestricted creator/updater — the `+` and edit buttons are visible. */
	const adminManifest = { '*.*': ['*'] };

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/ListView',
		component: ListView,
		tags: ['autodocs'],
		args: {
			driver,
			doctype: dealDef,
			parentDocId: 'crm.Deal',
			pageSize: 25,
			viewerId: 'iam.Account.viewer'
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** Wait long enough for the async views fetch to settle in Storybook. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	// ── B-106 regression fixture ──────────────────────────────────────────
	//
	// A driver wrapper that counts every listing `list()` call. The
	// saved-views fetch goes through `.doc().children()`, which delegates to
	// the base source, so the count tracks the `Table` reload path only.
	const listingCalls = { count: 0 };

	/** Wrap a driver so each `domain().doctype()` source counts its `list()` calls. */
	function countingDriverOf(base: DataDriver, counter: { count: number }): DataDriver {
		function wrapDomain(name: string): Domain {
			const domain = base.domain(name);
			return {
				doctype<T>(docName: string, seedData?: T[]): DataSource<T> {
					const ds = domain.doctype<T>(docName, seedData);
					return {
						list: async (params) => {
							counter.count += 1;
							return ds.list(params);
						},
						create: (content) => ds.create(content),
						doc: (id) => ds.doc(id)
					};
				}
			};
		}
		return {
			getDoctypeDefinition: (qualifiedName) => base.getDoctypeDefinition(qualifiedName),
			domain: wrapDomain
		};
	}

	const countedDriver = countingDriverOf(driver, listingCalls);

	// ── DeleteView fixture ──────────────────────────────────────────────
	//
	// Mock mutations are synchronous and stay in the driver instance, so the
	// delete flow gets its own driver (same isolation as `trashDriver`). The
	// wrapper also bridges two mock gaps so the play can assert the real
	// backend behaviour:
	// 1. The mock's child list keeps tombstones; the backend serves live rows
	//    only (`deleted_at IS NULL`). The wrapper drops the ids recorded
	//    deleted, so the deleted tab really vanishes from the refetch.
	// 2. The play must see the delete reach the driver — deletes are logged.
	const viewDeleteLog: string[] = [];

	function deleteTestDriverOf(base: DataDriver): DataDriver {
		// Wrap one child collection: drop tombstoned rows from `list()`.
		function wrapChild<C>(rel: string, child: DataSource<C>): DataSource<C> {
			return {
				list: async (params) => {
					const res = await child.list(params);
					return {
						...res,
						data: res.data.filter((row) => !viewDeleteLog.includes(row.meta.id))
					};
				},
				create: (content) => child.create(content),
				doc: (id) => wrapRef(id, child.doc(id))
			};
		}
		// Wrap one document ref: record `delete`, delegate everything else.
		function wrapRef<T>(id: string, ref: DocumentRef<T>): DocumentRef<T> {
			return {
				show: () => ref.show(),
				update: (diff) => ref.update(diff),
				delete: async () => {
					viewDeleteLog.push(id);
					await ref.delete();
				},
				action: (name, args) => ref.action(name, args),
				invalidate: () => ref.invalidate(),
				history: (params) => ref.history(params),
				rollback: (mutationId) => ref.rollback(mutationId),
				restore: () => ref.restore(),
				backrefs: (params) => ref.backrefs(params),
				children: <C,>(rel: string) => wrapChild(rel, ref.children<C>(rel)),
				sidecars: <C,>(segment: string) => ref.sidecars<C>(segment)
			};
		}
		function wrapDomain(name: string): Domain {
			const domain = base.domain(name);
			return {
				doctype<T>(docName: string, seedData?: T[]): DataSource<T> {
					const ds = domain.doctype<T>(docName, seedData);
					return {
						list: (params) => ds.list(params),
						create: (content) => ds.create(content),
						doc: (id) => wrapRef(id, ds.doc(id))
					};
				}
			};
		}
		return {
			getDoctypeDefinition: (qualifiedName) => base.getDoctypeDefinition(qualifiedName),
			domain: wrapDomain
		};
	}

	const deleteDriver = deleteTestDriverOf(createMockDriver());
</script>

<script lang="ts">
	import { expect, within, fireEvent, userEvent, waitFor } from 'storybook/test';

	// Local state for the DoctypeChangeClosesQuickView story. The story
	// mounts ListView against one doctype, opens the drawer, then swaps the
	// props — asserting the drawer auto-closes (no stale document leaks
	// across doctypes).
	let swapDoctype = $state(dealDef);
	let swapParentDocId = $state('crm.Deal');

	// Local state for the PinView story — the pinned set and the toggle
	// callback are injected so the story does not touch the real settings
	// store (which would need the backend).
	let pinnedIds = $state<string[]>([]);
	let pinLog = $state<string[]>([]);
	function handleTogglePin(viewId: string) {
		pinnedIds = pinnedIds.includes(viewId)
			? pinnedIds.filter((id) => id !== viewId)
			: [...pinnedIds, viewId];
		pinLog = [...pinLog, viewId];
	}

	// Local state for the RefreshSignalRelists story. The template button bumps
	// it the same way the doctype page bumps `importRefresh` when an import
	// job lands (`onimported` → `importRefresh++`).
	let refreshSignal = $state(0);
</script>

<!--
	Each story is wrapped in `<CanFixture>` so the `<Can>` gates inside
	ListView (the `+` create button and the edit button) render with a
	deterministic RBAC state — without a manifest they are fail-closed.
-->

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('tab', { name: 'All Deals' })).toBeVisible();
		await expect(canvas.getByRole('tab', { name: 'Open' })).toBeVisible();
		await expect(canvas.getByRole('tab', { name: 'Won' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Create a new view' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	Tab-less mode (`showTabs={false}`): no saved-view strip, no view CRUD
	affordances — the listing renders the fallback columns straight away.
	Used by admin surfaces that standardize on the default table.
-->

<Story
	name="Tabless"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('tab')).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Create a new view' })).toBeNull();
		// Tab-less mode always renders the table — never the zero-views starter.
		await expect(canvas.queryByText('No views yet')).toBeNull();
		await expect(canvas.getByRole('table')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					showTabs={false}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="KeyOnlyColumnUsesFieldTitle"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The saved view's columns carry keys with no `label` — the same shape a
		// REST or import write stores. The header falls back to the field's
		// declared title. The table header uppercases through CSS, so the DOM
		// text keeps the declared casing.
		const headers = canvas.getAllByRole('columnheader');
		const labels = headers.map((h) => h.textContent?.trim() ?? '');
		await expect(labels).toContain('Deal Title');
		await expect(labels).toContain('Deal Value');
		await expect(labels).toContain('Probability');
		// A key with no declared title humanizes ('lost_reason' → 'Lost Reason').
		await expect(labels).toContain('Lost Reason');
		// The raw key never prints.
		await expect(labels).not.toContain('Title');
		await expect(labels).not.toContain('LOST_REASON');
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<Table
					columns={bareDealColumns}
					datasource={bareDealDs}
					doctype={bareDealDef}
					rowKey={(item) => String((item as Record<string, unknown>)['id'])}
					pageSize={25}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="SecondViewActive"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Select the 'Open' saved view by name — the tab index depends on the
		// fixture set, so the story must not hardcode an index.
		const openTab = canvas.getByRole('tab', { name: 'Open' });
		await fireEvent.click(openTab);
		await sleep(120);
		await expect(openTab).toHaveAttribute('aria-selected', 'true');
		// The edit button is visible (admin can update), since the active tab
		// is a real saved view.
		await expect(canvas.getByRole('button', { name: 'Edit current view' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					active={1}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CalendarView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The Timeline tab is a calendar surface — selecting it renders the
		// Calendar grid instead of the table.
		const timelineTab = canvas.getByRole('tab', { name: 'Timeline' });
		await fireEvent.click(timelineTab);
		await sleep(120);
		await expect(timelineTab).toHaveAttribute('aria-selected', 'true');
		// The calendar toolbar (Month/Week segmented control) is visible.
		await expect(canvas.getByRole('tab', { name: 'Month' })).toBeVisible();
		await expect(canvas.getByRole('tab', { name: 'Week' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="KanbanView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The Pipeline tab is a kanban surface — selecting it renders the
		// kanban board instead of the table.
		const pipelineTab = canvas.getByRole('tab', { name: 'Pipeline' });
		await fireEvent.click(pipelineTab);
		await sleep(300);
		await expect(pipelineTab).toHaveAttribute('aria-selected', 'true');
		// The lane headers render inside the ListView (one per status enum
		// value, in declaration order).
		const laneLabels = [...canvasElement.querySelectorAll('.kb-col-label')].map((e) =>
			e.textContent?.trim()
		);
		await expect(laneLabels).toEqual(['Open', 'Won', 'Lost', 'Abandoned']);
		// Switching back to a table tab renders the table again.
		await fireEvent.click(canvas.getByRole('tab', { name: 'All Deals' }));
		await sleep(200);
		await expect(canvas.getByRole('table')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="GridView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The Sheet tab is a grid surface — selecting it renders the
		// spreadsheet grid instead of the table.
		const sheetTab = canvas.getByRole('tab', { name: 'Sheet' });
		await fireEvent.click(sheetTab);
		await sleep(400);
		await expect(sheetTab).toHaveAttribute('aria-selected', 'true');
		// The grid surface renders (role="grid"), not a table.
		await expect(canvas.getByRole('grid')).toBeVisible();
		await expect(canvas.queryByRole('table')).toBeNull();
		// The grid fixture freezes the first column (`grid.frozen: 1`) and
		// carries the authored headers.
		const frozenHeader = canvasElement.querySelector('.head-cell.frozen');
		expect(frozenHeader).not.toBeNull();
		const headerText = [...canvasElement.querySelectorAll('.head-cell')].map((e) =>
			e.textContent?.trim()
		);
		await expect(headerText).toContain('Deal');
		await expect(headerText).toContain('Value');
		// Rows render as gridcells keyed per row.
		const cells = canvasElement.querySelectorAll('[role="gridcell"][data-row]');
		expect(cells.length).toBeGreaterThan(0);
		// Switching back to a table tab renders the table again.
		await fireEvent.click(canvas.getByRole('tab', { name: 'All Deals' }));
		await sleep(300);
		await expect(canvas.getByRole('table')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 560px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="PinView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The active tab is 'All Deals' (a real saved view) so the pin toggle
		// is visible and unpinned.
		const pin = canvas.getByRole('button', { name: 'Pin current view' });
		await expect(pin).toHaveAttribute('aria-pressed', 'false');
		await fireEvent.click(pin);
		await sleep(40);
		// After pinning, the toggle flips to unpin and the callback fired.
		await expect(canvas.getByRole('button', { name: 'Unpin current view' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);
		expect(pinLog.length).toBe(1);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
					pinnedViewIds={pinnedIds}
					onTogglePin={handleTogglePin}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ZeroViewsStarter"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// No saved views → the starter screen: no tab strip, no synthetic tab.
		await expect(canvas.getByRole('heading', { name: 'No views yet' })).toBeVisible();
		await expect(canvas.queryByRole('tab')).toBeNull();
		// The three surface cards are the create affordance.
		await expect(canvas.getByRole('button', { name: /Table/ })).toBeVisible();
		await expect(canvas.getByRole('button', { name: /Kanban/ })).toBeVisible();
		await expect(canvas.getByRole('button', { name: /Calendar/ })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={contactDef}
					parentDocId="crm.Contact"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="StarterCreateFlow"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The CollectionViewEditor dialog is Bits-portalled to document.body.
		const body = within(document.body);
		// Picking a card opens the editor with the surface preselected — the
		// config step renders directly (the surface step is skipped).
		await fireEvent.click(canvas.getByRole('button', { name: /Table/ }));
		await sleep(40);
		await expect(body.getByRole('heading', { name: 'New view' })).toBeVisible();
		await expect(body.queryByRole('button', { name: 'Next' })).toBeNull();
		await userEvent.type(body.getByRole('textbox', { name: /Name/ }), 'First view');
		await sleep(10);
		await fireEvent.click(body.getByRole('button', { name: 'Create view' }));
		await sleep(60);

		// The saved view becomes the first (and only) tab, focused.
		await expect(canvas.getByRole('tab', { name: 'First view' })).toHaveAttribute(
			'aria-selected',
			'true'
		);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={contactDef}
					parentDocId="crm.Contact"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="CreateFlow"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The CollectionViewEditor dialog is Bits-portalled to document.body.
		const body = within(document.body);
		// Clicking "+" opens the CollectionViewEditor modal (create mode).
		const before = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });

		await fireEvent.click(canvas.getByRole('button', { name: 'Create a new view' }));
		await sleep(40);
		await expect(body.getByRole('heading', { name: 'New view' })).toBeVisible();
		await fireEvent.click(body.getByRole('button', { name: 'Next' }));
		await sleep(20);
		await userEvent.type(body.getByRole('textbox', { name: /Name/ }), 'Quarterly review');
		await sleep(10);
		await fireEvent.click(body.getByRole('button', { name: 'Create view' }));
		await sleep(60);

		// A new tab is focused and a new CollectionView child exists.
		await expect(canvas.getByRole('tab', { name: 'Quarterly review' })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		const after = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Deal')
			.children('collection_view')
			.list({ items: 500 });
		expect(after.data.length).toBe(before.data.length + 1);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="NoPermissionsHidesActions"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// With no manifest, `can()` is fail-closed: no view action is shown.
		await expect(canvas.queryByRole('button', { name: 'Create a new view' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Edit current view' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: m.list_view_delete() })).toBeNull();
		// …but the tabs and table still render.
		await expect(canvas.getByRole('tab', { name: 'All Deals' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={null}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ClickRowOpensQuickView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Clicking a body row (not a header) opens the QuickView peek drawer.
		const before = canvas.queryByRole('button', { name: /Close/ });
		await expect(before).toBeNull();

		// The first body row is a deal row. Click anywhere on the row.
		const rows = canvas.getAllByRole('row');
		// rows[0] is the header row; rows[1] is the first body row.
		await fireEvent.click(rows[1]);
		await sleep(80);

		// The QuickView drawer appears, scoped to the clicked deal.
		const closeBtn = await canvas.findByRole('button', { name: 'Close' });
		await expect(closeBtn).toBeVisible();

		// Closing the drawer slides it out; the host drops it (and its Close
		// button) when the slide-out finishes.
		await fireEvent.click(closeBtn);
		await waitFor(() => expect(canvas.queryByRole('button', { name: 'Close' })).toBeNull());
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					{driver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="DoctypeChangeClosesQuickView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);

		// Open the peek drawer by clicking a body row.
		const rows = canvas.getAllByRole('row');
		await fireEvent.click(rows[1]);
		await sleep(80);
		const closeBtn = await canvas.findByRole('button', { name: 'Close' });
		await expect(closeBtn).toBeVisible();

		// Switching the doctype (as happens when the user clicks another
		// doctype in the left NavPanel while the drawer is open) must reset
		// all QuickView state so no stale document/id leaks into the URL.
		await fireEvent.click(canvas.getByRole('button', { name: 'Switch doctype' }));
		await sleep(60);
		await expect(canvas.queryByRole('button', { name: 'Close' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<button
					onclick={() => {
						swapDoctype = companyDef;
						swapParentDocId = 'crm.Company';
					}}
				>
					Switch doctype
				</button>
				<ListView
					{driver}
					doctype={swapDoctype}
					parentDocId={swapParentDocId}
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="TrashMode"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);

		// Trash mode lists tombstones only — the deleted Deal row is present
		// (its title survives the delete) and a Restore action column is
		// rendered per row.
		await expect(canvas.getByText('Acme Corp — Platform License')).toBeVisible();
		await expect(canvas.getByText('Restore')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					driver={trashDriver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
					includeDeleted
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	B-106 regression: a `refreshSignal` bump must swap the `datasource`
	identity in every mode, so the `Table` reload effect refetches. The play
	asserts the counted source's `list()` call count grows after the bump —
	an identity-only assertion would pass even when the listing never
	reloads (the inert-fix failure shape).
-->
<Story
	name="RefreshSignalRelists"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('table')).toBeVisible();
		const before = listingCalls.count;
		// Bump the signal the way the doctype page does after an import.
		await userEvent.click(canvas.getByRole('button', { name: 'Bump refresh signal' }));
		await waitFor(() => expect(listingCalls.count).toBeGreaterThan(before));
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<button onclick={() => (refreshSignal += 1)}>Bump refresh signal</button>
				<ListView
					driver={countedDriver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
					{refreshSignal}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	The `toolbarActions` snippet receives the table's live state: the current
	columns, the compacted filter map the datasource receives (a freshly added
	empty-value chip must NOT ride it), and the current sort. The snippet
	dumps the args into a data block the play reads back.
-->

<Story
	name="ToolbarActionsCarryTableState"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);

		const stateBlock = () =>
			JSON.parse(
				canvasElement.querySelector('[data-testid=export-state]')?.textContent ?? '{}'
			) as {
				columns: { key: string }[];
				filters: Record<string, unknown>;
				sort: { key: string; desc: boolean } | null;
			};

		// Columns: the args carry exactly the table's rendered headers (the
		// fallback column rule stays internal — the count ties the two).
		const headers = canvas.getAllByRole('columnheader');
		await expect(stateBlock().columns.length).toBe(headers.length);

		// Sort: a header click reorders the table and the args agree.
		const nameHeader = headers.find((h) => h.textContent?.includes('Company Name'));
		await nameHeader?.click();
		await sleep(60);
		expect(stateBlock().sort).toEqual({ key: 'name', desc: false });
		await expect(nameHeader).toHaveAttribute('aria-sort', 'ascending');

		// Filters: a search term reaches the args after the debounce; a
		// freshly added chip (seeded with an empty value) does not — the
		// compacted map is what the datasource list call receives.
		await userEvent.type(canvas.getByRole('textbox'), 'acme');
		await sleep(400); // the search debounce is 250 ms
		// The "+ Add filter" menu's pointer path trips the Bits UI
		// pointer-events restore race (see the testing strategy) — drive the
		// trigger and the item with scripted clicks, as the running-guard
		// story does.
		canvas
			.getByRole('button', { name: '+ Add filter' })
			.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
		const menuItem = await waitFor(
			() => {
				// The Bits UI dropdown portals its content to document.body,
				// outside the story canvas — query the document.
				const el = [...document.body.querySelectorAll('[role=menuitem], .menu-item')].find(
					(n) => n.textContent?.trim() === 'Company Name'
				);
				if (!el) throw new Error('add-filter item not rendered yet');
				return el as HTMLElement;
			},
			{ timeout: 2000 }
		);
		menuItem.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
		await sleep(60);
		// The chip is visible on the table…
		await expect(canvas.getAllByText('Company Name').length).toBeGreaterThan(0);
		// …but its empty value never reaches the export args.
		expect(stateBlock().filters).toEqual({ search: 'acme' });
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<!-- The play drives sort and filter interactions; persistence
				     would restore them on the next run and break the asserted
				     state. Opt out — the Table stories cover persistence. -->
				<ListView
					{driver}
					doctype={companyDef}
					parentDocId="crm.Company"
					pageSize={25}
					viewerId="iam.Account.viewer"
					persistKey={null}
				>
					{#snippet toolbarActions(args)}
						<div data-testid="export-state">
							{JSON.stringify({
								columns: args.columns.map((c) => ({ key: c.key })),
								filters: args.filters,
								sort: args.sort
							})}
						</div>
					{/snippet}
				</ListView>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
DeleteView: the tab-strip delete affordance. Opens the shared confirm
dialog — the app mounts the host in the root layout, so the story mounts
its own `<ConfirmDialog />`. Cancel keeps the view. Confirm soft-deletes
the CollectionView child, the strip refetches, and the tab disappears.
-->
<Story
	name="DeleteView"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The strip opens on a real saved view, so the delete control shows.
		const activeTab = canvas.getByRole('tab', { selected: true });
		const activeName = activeTab.textContent?.trim() ?? '';
		const deleteBtn = canvas.getByRole('button', { name: m.list_view_delete() });
		await expect(deleteBtn).toBeVisible();

		// Cancel path: the dialog opens, Cancel closes it, nothing deletes.
		await fireEvent.click(deleteBtn);
		const dialog = await waitFor(() => {
			const el = within(document.body).getByRole('dialog');
			expect(el).toBeVisible();
			return el;
		});
		// The copy names the view the user is about to remove.
		await expect(
			within(dialog).getByRole('heading', {
				name: m.list_view_delete_confirm_title({ name: activeName })
			})
		).toBeVisible();
		await expect(within(dialog).getByText(m.list_view_delete_confirm_body())).toBeVisible();
		await fireEvent.click(within(dialog).getByRole('button', { name: m.common_cancel() }));
		await waitFor(() => expect(within(document.body).queryByRole('dialog')).toBeNull());
		await expect(canvas.getByRole('tab', { name: activeName })).toBeVisible();
		const deletesBefore = viewDeleteLog.length;

		// Confirm path: the delete fires, the strip refetches, the tab goes.
		await fireEvent.click(canvas.getByRole('button', { name: m.list_view_delete() }));
		const confirmDialog = await waitFor(() => within(document.body).getByRole('dialog'));
		await fireEvent.click(within(confirmDialog).getByRole('button', { name: m.common_delete() }));
		await waitFor(() => expect(canvas.queryByRole('tab', { name: activeName })).toBeNull());
		// The remaining tabs stay, and the strip serves the new active view.
		await expect(canvas.getByRole('tab', { name: 'Open' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: m.list_view_delete() })).toBeVisible();
		expect(viewDeleteLog.length).toBe(deletesBefore + 1);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div
				style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden; padding: 24px;"
			>
				<ListView
					driver={deleteDriver}
					doctype={dealDef}
					parentDocId="crm.Deal"
					pageSize={25}
					viewerId="iam.Account.viewer"
				/>
				<!-- The confirm host lives in the root layout in the app; the
		     story must mount it explicitly or confirm() never renders. -->
				<ConfirmDialog />
			</div>
		</CanFixture>
	{/snippet}
</Story>
