<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DocumentCard from './DocumentCard.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { TemplateNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/DocumentCard',
		component: DocumentCard,
		tags: ['autodocs']
	});

	/**
	 * One driver per fixture family. `crm.Customer` carries a definition and
	 * a `card` document-view template — card mode renders the template
	 * through `DocumentViewTemplate`. `crm.Vendor` carries a definition but
	 * no document views — card mode falls back to the identity body
	 * (display name + updated time), because the fallback chain is gone.
	 * Every display value resolves from the driver's records; the card only
	 * receives the document identity. The view cache keys on the doctype id,
	 * so the two kinds must use distinct doctypes.
	 */
	function makeDriver(): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Customer', {
			doctype: 'Customer',
			domain: 'crm',
			icon: 'building-2',
			fields: {
				name: { key: 'name', type: 'text', title: 'Name' },
				status: { key: 'status', type: 'enum', title: 'Status' }
			}
		});
		driver.registerDoctype('crm', 'Vendor', {
			doctype: 'Vendor',
			domain: 'crm',
			icon: 'truck',
			fields: {
				name: { key: 'name', type: 'text', title: 'Name' },
				status: { key: 'status', type: 'enum', title: 'Status' }
			}
		});
		void driver.domain('crm').doctype('Customer', [
			{
				id: 'crm.Customer.aurora',
				name: 'Aurora Print Studio',
				status: 'active'
			},
			{
				id: 'crm.Customer.northwind',
				name: 'Northwind Supply Co',
				status: 'active'
			}
		]);
		void driver.domain('crm').doctype('Vendor', [
			{
				id: 'crm.Vendor.vendmax',
				name: 'Vendmax Logistics',
				status: 'active'
			}
		]);
		void driver.domain('core').doctype('DocType', [
			{
				id: 'crm.Customer',
				doctype: 'Customer',
				domain: 'crm'
			},
			{
				id: 'crm.Vendor',
				doctype: 'Vendor',
				domain: 'crm'
			}
		]);
		void driver.domain('core').doctype('DocumentView', [
			{
				id: 'crm.Customer.document_view.card',
				kind: 'card',
				template: {
					type: 'col',
					children: [
						{
							type: 'section',
							label: 'Identity',
							children: [
								{ type: 'field', label: 'Name', value: '$name' },
								{ type: 'field', label: 'Status', value: '$status' }
							]
						}
					]
				} as TemplateNode
			}
		]);
		return driver;
	}

	const driver = makeDriver();

	const aurora = { domain: 'crm', doctype: 'Customer', id: 'crm.Customer.aurora' };
	const northwind = { domain: 'crm', doctype: 'Customer', id: 'crm.Customer.northwind' };
	const vendmax = { domain: 'crm', doctype: 'Vendor', id: 'crm.Vendor.vendmax' };
	const missing = { domain: 'crm', doctype: 'Customer', id: 'crm.Customer.gone' };

	/** Wait long enough for the show + definition + view fetches to settle. */
	const settle = (ms = 120): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<Story
	name="InlineRow"
	play={async ({ canvasElement }) => {
		// Compact mode: display_name from the resolved record plus identity
		// badges — not the payload id.
		await settle();
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Aurora Print Studio')).toBeVisible();
		await expect(canvas.getByText('Customer')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 320px; padding: 12px; background: var(--bg, var(--surface));">
			<DocumentCard ref={aurora} display="inline" {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="CardWithViewTemplate"
	play={async ({ canvasElement }) => {
		// Card mode renders the doctype's `card` kind template through
		// DocumentViewTemplate; the field values resolve from the real record.
		await settle();
		const canvas = within(canvasElement);
		// The header and the template's Name field both show the resolved label.
		await expect(canvas.getAllByText('Northwind Supply Co').length).toBeGreaterThanOrEqual(2);
		// The template's section heading proves the DVT mounted.
		await expect(canvas.getByText('Identity')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 340px; padding: 12px; background: var(--bg, var(--surface));">
			<DocumentCard ref={northwind} display="card" {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="CardWithoutCardTemplate"
	play={async ({ canvasElement }) => {
		// No `card` kind for the doctype: no fallback chain — the body stays
		// the identity text (display name + updated time); the template
		// surface never mounts.
		await settle();
		const canvas = within(canvasElement);
		// Header + identity body both carry the resolved label.
		await expect(canvas.getAllByText('Vendmax Logistics').length).toBeGreaterThanOrEqual(2);
		await expect(canvas.queryByText('Identity')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="width: 340px; padding: 12px; background: var(--bg, var(--surface));">
			<DocumentCard ref={vendmax} display="card" {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingDocument"
	play={async ({ canvasElement }) => {
		// Error state: the target is gone — the row falls back to the bare id
		// with an alert marker in the notes slot; the hover title carries the
		// failure reason.
		await settle(300);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('crm.Customer.gone')).toBeVisible();
		const row = canvas.getByTitle(/not found/i);
		await expect(row).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 320px; padding: 12px; background: var(--bg, var(--surface));">
			<DocumentCard ref={missing} display="inline" {driver} />
		</div>
	{/snippet}
</Story>
