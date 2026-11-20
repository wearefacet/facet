<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import DvtRelationTable from './DvtRelationTable.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { RelationRow } from '$lib/doctype/relationColumns.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { RelationNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtRelationTable',
		component: DvtRelationTable,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): the relation-table
		// surface carries the same violations as the DvtRelation meta
		// (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/**
	 * Mock driver seeded with one contact. `MockDataSource` synthesises
	 * `display_name` from `name`, so the hydrated reference capsules carry a
	 * meaningful label without a doctype-def round-trip.
	 */
	function buildDriver(): MockDataDriver {
		const driver = new MockDataDriver();
		driver
			.domain('crm')
			.doctype('Contact', [
				{ id: 'crm.Contact.1', name: 'Alice Johnson', email: 'alice@acme.com' }
			]);
		return driver;
	}
	const driver = buildDriver();

	const relationDef: DoctypeDef = {
		doctype: 'CompanyMembership',
		domain: 'crm',
		fields: [
			{ key: 'contact', type: 'reference', doctype: 'crm.Contact' },
			{
				key: 'role',
				type: 'enum',
				values: [
					{ key: 'primary', label: 'Primary', color: '#0089a7' },
					{ key: 'secondary', label: 'Secondary', color: '#97751a' },
					{ key: 'observer', label: 'Observer', color: '#b25e5e' }
				]
			},
			{ key: 'billing_contact', type: 'boolean' }
		],
		children: [],
		actions: []
	};

	// Two memberships share crm.Contact.1 (one fetch for both cells); the
	// third row carries a blank reference (em-dash cell).
	const rows: RelationRow[] = [
		{
			meta: { id: 'm1', display_name: null },
			data: { contact: 'crm.Contact.1', role: 'primary', billing_contact: true }
		},
		{
			meta: { id: 'm2', display_name: null },
			data: { contact: 'crm.Contact.1', role: 'secondary' }
		},
		{
			meta: { id: 'm3', display_name: null },
			data: { contact: '', role: 'observer' }
		}
	];

	const referenceColumnTemplate: RelationNode = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: [
			{ key: 'contact', label: 'Contact' },
			{ key: 'contact.email', label: 'Email', width: '200px' },
			{ key: 'role', label: 'Role', width: '120px' }
		]
	};

	// A template stored before column validation existed: two columns are
	// bare strings. The renderer coerces them at the boundary — the table
	// renders rows instead of crashing on duplicate each-keys (B-114).
	const malformedColumnsTemplate = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: ['contact.email', 'role', { key: 'billing_contact', label: 'Billing' }]
	} as unknown as RelationNode;

	// The validator requires only `key` per column, so a stored column can
	// legally carry no label. The header and the boolean toggle's accessible
	// name must fall back to the key, never render empty or "undefined".
	// The frontend type declares `label` required; the stored template is
	// cast, mirroring the malformed-columns fixture above.
	const unlabeledColumnTemplate = {
		type: 'relation',
		label: 'Memberships',
		doctype: 'crm.CompanyMembership',
		source: { kind: 'children', rel: 'memberships' },
		view: 'table',
		limit: 25,
		columns: [
			{ key: 'role', label: 'Role' },
			{ key: 'billing_contact', editable: true }
		]
	} as unknown as RelationNode;

	function sleep(ms: number): Promise<void> {
		return new Promise((resolve) => setTimeout(resolve, ms));
	}
</script>

<Story
	name="MalformedStringColumns"
	args={{
		template: malformedColumnsTemplate,
		rows,
		parentId: 'crm.Company.1',
		viewMode: 'table',
		relationDef,
		driver
	}}
	play={async ({ canvasElement }) => {
		await sleep(200);
		const canvas = within(canvasElement);
		// The string columns coerce to object columns with humanized labels.
		await expect(canvas.getByText('Contact.Email')).toBeVisible();
		await expect(canvas.getByText('Role')).toBeVisible();
		await expect(canvas.getByText('Billing')).toBeVisible();
		// Rows still render — no each_key_duplicate crash.
		await expect(canvas.getAllByRole('row').length).toBe(4); // header + 3
		await expect(canvas.getByText('Primary')).toBeVisible();
		// The coerced dotted column hydrates through the traversal pass.
		await expect(canvas.getAllByText('alice@acme.com').length).toBe(2);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelationTable
				rows={args.rows}
				template={args.template}
				viewMode={args.viewMode}
				parentId={args.parentId}
				{driver}
				relationDef={args.relationDef}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceColumnRendersCapsule"
	args={{
		template: referenceColumnTemplate,
		rows,
		parentId: 'crm.Company.1',
		viewMode: 'table',
		relationDef,
		driver,
		onreferenceclick: fn()
	}}
	play={async ({ canvasElement, args }) => {
		await sleep(200);
		const canvas = within(canvasElement);
		// The leaf reference column hydrates to the target document's label —
		// not the raw URN (B-116). Two rows share crm.Contact.1 → two capsules.
		await waitFor(() => {
			expect(canvas.getAllByText('Alice Johnson').length).toBe(2);
		});
		await expect(canvas.queryByText('crm.Contact.1')).toBeNull();
		// The dotted column beside it still resolves through the traversal pass.
		await expect(canvas.getAllByText('alice@acme.com').length).toBe(2);
		// A blank reference value renders the em-dash blank.
		await expect(canvas.getAllByText('—').length).toBeGreaterThan(0);
		// Click-through fires the reference click with the target's parts.
		await userEvent.click(canvas.getAllByRole('button', { name: 'Alice Johnson' })[0]);
		await expect(args.onreferenceclick).toHaveBeenCalledWith({
			domain: 'crm',
			doctype: 'Contact',
			id: 'crm.Contact.1'
		});
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelationTable
				rows={args.rows}
				template={args.template}
				viewMode={args.viewMode}
				parentId={args.parentId}
				{driver}
				relationDef={args.relationDef}
				onreferenceclick={args.onreferenceclick}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="UnlabeledColumnFallsBackToKey"
	args={{
		template: unlabeledColumnTemplate,
		rows,
		parentId: 'crm.Company.1',
		viewMode: 'table',
		relationDef,
		driver,
		ontoggle: fn()
	}}
	play={async ({ canvasElement }) => {
		await sleep(200);
		const canvas = within(canvasElement);
		// The label-less column's header shows the key, not an empty cell.
		await expect(canvas.getByText('Role')).toBeVisible();
		await expect(canvas.getByText('billing_contact')).toBeVisible();
		// The toggle's accessible name interpolates the same fallback —
		// never "Toggle undefined".
		const toggles = canvas.getAllByRole('button', { name: 'Toggle billing_contact' });
		await expect(toggles.length).toBe(3);
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRelationTable
				rows={args.rows}
				template={args.template}
				viewMode={args.viewMode}
				parentId={args.parentId}
				{driver}
				relationDef={args.relationDef}
				ontoggle={args.ontoggle}
			/>
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}
</style>
