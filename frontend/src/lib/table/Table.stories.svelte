<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import Table from './Table.svelte';
	import type { Column } from './types.js';
	import { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';

	interface Invoice {
		id: string;
		invoiceNo: string;
		vendor: string;
		amount: number;
		status: string;
		owner: string;
		updated: string;
		confidence: number;
		/** Boolean-flag rows for the InlineBoolean story. */
		paid?: boolean;
		locked?: boolean;
	}

	const sampleData: Invoice[] = [
		{
			id: '1',
			invoiceNo: 'INV-2026-0488',
			vendor: 'Maersk Line A/S',
			amount: 12480.0,
			status: 'Needs review',
			owner: 'SM',
			updated: '2h ago',
			confidence: 0.74
		},
		{
			id: '2',
			invoiceNo: 'INV-2026-0487',
			vendor: 'DHL Global Forwarding',
			amount: 3210.55,
			status: 'Reconciled',
			owner: 'JL',
			updated: '5h ago',
			confidence: 0.96
		},
		{
			id: '3',
			invoiceNo: 'INV-2026-0486',
			vendor: 'Kuehne + Nagel',
			amount: 28900.0,
			status: 'Disputed',
			owner: 'YA',
			updated: 'Yesterday',
			confidence: 0.58
		},
		{
			id: '4',
			invoiceNo: 'INV-2026-0485',
			vendor: 'CEVA Logistics',
			amount: 1044.2,
			status: 'Reconciled',
			owner: 'AM',
			updated: 'Yesterday',
			confidence: 0.91
		},
		{
			id: '5',
			invoiceNo: 'INV-2026-0484',
			vendor: 'DB Schenker',
			amount: 7775.0,
			status: 'Draft',
			owner: 'SM',
			updated: '2d ago',
			confidence: 0.81
		}
	];

	const defaultDs: MockDataSource<Invoice> = new MockDataSource<Invoice>(
		'acme',
		'Invoice',
		sampleData
	);

	/** Build a datasource seeded with many invoices for pagination stories.
	 *  Keep the seed small: the story's a11y scan walks the rendered table and
	 *  its cost grows with the DOM — 248 rows alone put the story past the
	 *  10s test budget. 48 rows still fill the first page and render two
	 *  pages at the 25 seed, and still fit on one page at the 250 seed. */
	function buildPagedDs(_pageSize: number): MockDataSource<Invoice> {
		const many: Invoice[] = [];
		for (let i = 1; i <= 48; i++) {
			many.push({
				id: String(i),
				invoiceNo: `INV-2026-${String(i).padStart(4, '0')}`,
				vendor: `Vendor ${i}`,
				amount: Math.round(Math.random() * 50000 * 100) / 100,
				status: ['Draft', 'Reconciled', 'Needs review', 'Disputed'][i % 4],
				owner: ['SM', 'JL', 'YA', 'AM'][i % 4],
				updated: `${i % 30}d ago`,
				confidence: Math.round((0.3 + Math.random() * 0.7) * 100) / 100
			});
		}
		return new MockDataSource<Invoice>('acme', 'Invoice', many);
	}

	// ── Bounded count footer (B-297) ─────────────────────────────────
	// A paged list answers an offset-relative `meta.count`; with `more` set
	// it is only a lower bound, never a total. The stub mimics the backend:
	// the page call reports 6 with `more: true`, and the `aggregate: count`
	// call reports the capped 1000 with `more: true` too. The footer must
	// render the open-range form, never an exact-looking bound.
	const boundedDs = {
		async list(params?: { page?: number; items?: number; aggregate?: 'count' }) {
			if (params?.aggregate === 'count') {
				return { data: [], meta: { count: 1000, more: true } };
			}
			const items = params?.items ?? 25;
			const offset = ((params?.page ?? 1) - 1) * items;
			const slice = sampleData.slice(offset, offset + items);
			return {
				data: slice.map((d) => ({
					data: d,
					meta: { id: d.id, created_at: '', updated_at: '' }
				})),
				meta: { count: 6, more: true }
			};
		}
	} as unknown as DataSource<Invoice>;

	const { Story } = defineMeta({
		title: 'Components/Data/Table',
		component: Table<Invoice>,
		tags: ['autodocs'],
		args: {
			rowKey: (d: Invoice) => d.id
		}
	});

	// ── Schema-aware boolean cells ─────────────────────────────────────
	// The default cell renderer dispatches on the doctype's field types; a
	// column marked `editable` over a plain boolean field renders as an
	// inline toggle gated on the viewer's `update` permission.

	const flagDef: DoctypeDef = {
		doctype: 'Invoice',
		domain: 'acme',
		fields: [
			{ key: 'invoiceNo', type: 'string', title: 'Invoice' },
			{ key: 'paid', type: 'boolean', title: 'Paid' },
			{ key: 'locked', type: 'boolean', title: 'Locked', read_only: true }
		],
		children: [],
		actions: []
	};

	const flagDs = new MockDataSource<Invoice>('acme', 'Invoice', [
		{
			id: '1',
			invoiceNo: 'INV-2026-0488',
			vendor: 'Maersk Line A/S',
			amount: 0,
			status: 'Draft',
			owner: 'SM',
			updated: '2h ago',
			confidence: 0.74,
			paid: true,
			locked: false
		},
		{
			id: '2',
			invoiceNo: 'INV-2026-0487',
			vendor: 'DHL Global Forwarding',
			amount: 0,
			status: 'Draft',
			owner: 'JL',
			updated: '5h ago',
			confidence: 0.96,
			paid: false,
			locked: true
		}
	]);

	const flagColumns: Column<Invoice>[] = [
		{ key: 'invoiceNo', label: 'Invoice' },
		{ key: 'paid', label: 'Paid', editable: true },
		// Even with the flag set, a `read_only` field never renders a toggle.
		{ key: 'locked', label: 'Locked', editable: true }
	];

	// ── Schema-aware filter toolbar ────────────────────────────────────
	// Load the `crm.Deal` fixture (definition + seed docs) from the mock
	// driver, parse its definition, and hand both to the Table so the
	// toolbar can render search (title__match) + status enum + reference +
	// range/between filters driven by the doctype's `operators` metadata.

	interface Deal {
		id: string;
		title: string;
		value: number;
		currency: string;
		status: string;
		probability: number;
		expected_close_date: string | null;
		actual_close_date: string | null;
		company_id: string;
		primary_contact_id: string;
		stage_id: string;
		owner_id: string;
	}

	const driver = createMockDriver();
	const rawDef = driver.getDoctypeDefinition('crm.Deal');
	const doctype: DoctypeDef | undefined = rawDef
		? parseDoctypeDef(rawDef as Record<string, unknown>)
		: undefined;

	// One `defineMeta` per story file: the meta row type stays `Invoice`,
	// and the two toolbar stories show the `crm.Deal` fixture. Re-type the
	// Deal-typed values to the meta row type — the runtime values do not
	// change.
	const datasource = driver.domain('crm').doctype<Deal>('Deal') as unknown as DataSource<Invoice>;

	// ── Collection reference cell (one Capsule per element) ───────────
	// A `collection: true` reference stores a JSON array of qualified ids.
	// The pre-fix renderer joined the array into one comma-joined string and
	// fetched `/Api/<domain>/<Doctype>/<token,token>` — a guaranteed 404 and
	// a failed capsule per cell. The schema-aware default cell now renders
	// one Capsule per token, each resolving its own show against the fixture
	// driver (`crm.Company.1` / `crm.Company.2` seed 'Acme Corp' /
	// 'Globex Inc').
	interface PartneredDeal {
		id: string;
		name: string;
		partners: string[];
	}

	const collDriver = createMockDriver();
	const collDs = new MockDataSource<PartneredDeal>('crm', 'Deal', [
		{ id: '1', name: 'Northwind retool', partners: ['crm.Company.1', 'crm.Company.2'] },
		{ id: '2', name: 'Initech rollout', partners: [] }
	]);
	const collDef: DoctypeDef = {
		doctype: 'Deal',
		domain: 'crm',
		fields: [
			{ key: 'name', type: 'string', title: 'Deal' },
			{
				key: 'partners',
				type: 'reference',
				title: 'Partners',
				doctype: 'crm.Company',
				collection: true
			}
		],
		children: [],
		actions: []
	};
	const collColumns: Column<PartneredDeal>[] = [
		{ key: 'name', label: 'Deal' },
		{ key: 'partners', label: 'Partners' }
	];

	// ── Dense file cell (F10-07) ───────────────────────────────────────────
	// A `file` field stores a bare artifact id. The show page resolves the
	// filename; the listing cell must not print the opaque ULID when the
	// metadata is already cached. The synthetic fetcher stands in for
	// `GET /Api/core/artifacts/:id`.
	const ARTIFACT_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';
	function syntheticArtifactFetch(id: string) {
		return Promise.resolve({
			id,
			filename: 'contract.pdf',
			mime_type: 'application/pdf',
			url: 'https://artifact.example/a/grant-1?exp=1234&sig=abc'
		});
	}

	interface ContractedInvoice {
		id: string;
		invoiceNo: string;
		contract: string;
	}

	const fileDs = new MockDataSource<ContractedInvoice>('acme', 'Invoice', [
		{ id: '1', invoiceNo: 'INV-2026-0488', contract: ARTIFACT_ID }
	]);
	const fileDef: DoctypeDef = {
		doctype: 'Invoice',
		domain: 'acme',
		fields: [
			{ key: 'invoiceNo', type: 'string', title: 'Invoice' },
			{ key: 'contract', type: 'file', title: 'Contract' }
		],
		children: [],
		actions: []
	};
	const fileColumns: Column<ContractedInvoice>[] = [
		{ key: 'invoiceNo', label: 'Invoice' },
		{ key: 'contract', label: 'Contract' }
	];
</script>

<script lang="ts">
	import Money from '$lib/components/primitives/data/Money.svelte';
	import Badge from '$lib/components/primitives/data/Badge.svelte';

	const moneyColumns: Column<Invoice>[] = [
		{ key: 'invoiceNo', label: 'Invoice' },
		{ key: 'vendor', label: 'Vendor' },
		{ key: 'amount', label: 'Amount', align: 'right', sortable: true, render: renderAmount },
		{ key: 'status', label: 'Status', align: 'center' },
		{ key: 'owner', label: 'Owner' },
		{ key: 'updated', label: 'Updated', align: 'right' }
	];

	// Deal columns for the toolbar stories — re-typed to the meta row type
	// (see the `datasource` note in the module script).
	const columns = [
		{ key: 'title', label: 'Deal' },
		{ key: 'value', label: 'Value', align: 'right', sortable: true, render: renderValue },
		{ key: 'status', label: 'Status', align: 'center', render: renderStatus },
		{ key: 'probability', label: 'Prob.', align: 'right' },
		{ key: 'expected_close_date', label: 'Expected close', align: 'right' }
	] as unknown as Column<Invoice>[];

	// Pre-seed a couple of filters so the chip+operator UI is visible on load.
	const seededFilters: Record<string, unknown> = {
		status__eq: 'open'
	};
</script>

{#snippet renderAmount(item: Invoice)}
	<Money amount={item.amount} />
{/snippet}

{#snippet renderValue(item: Deal)}
	<Money amount={item.value} currency={item.currency ?? 'USD'} />
{/snippet}

{#snippet renderStatus(item: Deal)}
	<Badge variant={item.status === 'won' ? 'ok' : item.status === 'lost' ? 'danger' : 'neutral'}>
		{item.status}
	</Badge>
{/snippet}

<Story
	name="Default"
	args={{ columns: moneyColumns, datasource: defaultDs }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Invoice')).toBeVisible();
		await expect(canvas.getByText('Vendor')).toBeVisible();
		await expect(canvas.getByText('INV-2026-0488')).toBeVisible();
		await expect(canvas.getByText('Maersk Line A/S')).toBeVisible();
	}}
/>

<Story
	name="WithSort"
	args={{ columns: moneyColumns, datasource: defaultDs, sort: { key: 'amount', desc: false } }}
/>

<Story
	name="WithSelection"
	args={{
		columns: moneyColumns,
		datasource: defaultDs,
		selectable: true,
		selected: new Set(['1', '3']),
		onSelect: undefined,
		onSelectAll: undefined
	}}
/>

<Story
	name="Empty"
	args={{
		columns: moneyColumns,
		datasource: new MockDataSource<Invoice>('acme', 'Invoice', [])
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('No records')).toBeVisible();
		await expect(canvas.queryByText((content) => content.includes('0–0 of'))).toBeNull();
	}}
/>

<Story
	name="WithPagination"
	args={{
		columns: moneyColumns,
		datasource: buildPagedDs(25),
		selectable: true,
		selected: new Set(['1']),
		onSelect: undefined,
		onSelectAll: undefined
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// 48 seeded rows at the 25 seed → 2 pages, first page full. The
		// summary span carries a selection suffix ("· 1 selected"), so match
		// by prefix like the Empty story does.
		await expect(canvas.getByText((c) => c.startsWith('1–25 of 48'))).toBeVisible();
		await expect(canvasElement.querySelectorAll('tbody tr').length).toBe(25);

		// The footer selector carries the visible label and the seed value.
		const select = canvas.getByRole('combobox', { name: 'Rows:' });
		await expect(select).toHaveValue('25');

		// Pick 10 → 10 rows per page, summary follows.
		await userEvent.selectOptions(select, '10');
		await waitFor(() => expect(canvas.getByText((c) => c.startsWith('1–10 of 48'))).toBeVisible());
		await waitFor(() => expect(canvasElement.querySelectorAll('tbody tr').length).toBe(10));

		// Pick 250 → everything fits on one page (48 < 250).
		await userEvent.selectOptions(select, '250');
		await waitFor(() => expect(canvas.getByText((c) => c.startsWith('1–48 of 48'))).toBeVisible());
		await waitFor(() => expect(canvasElement.querySelectorAll('tbody tr').length).toBe(48));
	}}
/>

<Story
	name="BoundedCountFooter"
	args={{ columns: moneyColumns, datasource: boundedDs }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The page-relative count (6, more) refines to the capped aggregate
		// (1000, more): the footer renders the open range with a `+`, never
		// the page-relative bound as an exact total. The range end follows
		// the page size (25), not the stub's 5 seeded rows.
		await waitFor(() =>
			expect(canvas.getByText((c) => c.startsWith('1–25 of 1,000+'))).toBeVisible()
		);
		await expect(canvas.queryByText((c) => c.startsWith('1–25 of 6'))).toBeNull();
	}}
/>

<Story
	name="InlineBoolean"
	args={{
		columns: flagColumns,
		datasource: flagDs,
		doctype: flagDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// `paid` is a plain boolean column marked editable and the fixture
		// role holds `update` — each row's cell renders as an inline toggle.
		const toggles = canvas.getAllByRole('button', { name: 'Toggle Paid' });
		expect(toggles.length).toBe(2);
		const toggle = toggles[0]; // first row seeded `paid: true`
		await expect(toggle).toHaveAttribute('aria-pressed', 'true');

		// Click flips the cell and persists through the DataSource.
		await userEvent.click(toggle);
		await waitFor(() => expect(toggle).toHaveAttribute('aria-pressed', 'false'));
		await waitFor(() => expect(flagDs.docs.get('1')?.content.paid).toBe(false));

		// `locked` is declared read_only — no toggle, read-only mark only.
		await expect(canvas.queryByRole('button', { name: 'Toggle Locked' })).toBeNull();
	}}
>
	{#snippet template(args)}
		<CanFixture manifest={{ 'acme.Invoice': ['update'] }}>
			<div style="min-height: 320px; padding: 16px;">
				<Table {...args} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!-- Empty filters — toolbar starts clean, reviewer adds via "+ Add filter". -->
<Story
	name="WithSearchAndFilters"
	args={{
		columns,
		datasource,
		doctype,
		driver,
		selectable: true,
		selected: new Set<string>(),
		onSelect: undefined,
		onSelectAll: undefined
	}}
/>

<!-- Pre-seeded with an enum equality filter so the chip UI shows on load. -->
<Story
	name="WithActiveFilters"
	args={{
		columns,
		datasource,
		doctype,
		driver,
		filters: seededFilters,
		selectable: true,
		selected: new Set<string>(),
		onSelect: undefined,
		onSelectAll: undefined
	}}
/>

<!-- A `collection: true` reference cell renders one Capsule per element —
     never one capsule with the comma-joined array (the 404 bug). -->
<Story
	name="CollectionReferenceCell"
	args={{
		columns: collColumns as unknown as Column<Invoice>[],
		datasource: collDs as unknown as DataSource<Invoice>,
		doctype: collDef,
		driver: collDriver
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Row 1: one Capsule per array element, each hydrated from its own
		// show fetch against the fixture driver.
		await waitFor(() => {
			expect(canvas.getByText('Acme Corp')).toBeVisible();
			expect(canvas.getByText('Globex Inc')).toBeVisible();
		});
		// The comma-joined form (the pre-fix fetch payload) never renders.
		await expect(canvas.queryByText('crm.Company.1, crm.Company.2')).toBeNull();
		// Row 2: an empty array renders the blank dash, not an empty capsule.
		const row2 = canvas.getByText('Initech rollout').closest('tr');
		expect(row2?.querySelector('.fv-blank')).not.toBeNull();
	}}
/>

<!-- A `file` cell resolves the artifact filename when the metadata is
     cached, and keeps the id as the tooltip. The show page and the listing
     then read the same way. -->
<Story
	name="FileCellResolvesFilename"
	args={{
		columns: fileColumns as unknown as Column<Invoice>[],
		datasource: fileDs as unknown as DataSource<Invoice>,
		doctype: fileDef,
		fetchArtifact: syntheticArtifactFetch
	}}
	play={async ({ canvasElement }) => {
		// The label flips from the bare id to the filename once the metadata
		// lands. The id stays the tooltip so the stored value is readable.
		await waitFor(() => {
			const cell = canvasElement.querySelector('td .cell-text[title]');
			expect(cell?.textContent?.trim()).toBe('contract.pdf');
		});
		const cell = canvasElement.querySelector('td .cell-text[title]');
		await expect(cell).toHaveAttribute('title', ARTIFACT_ID);
	}}
/>
