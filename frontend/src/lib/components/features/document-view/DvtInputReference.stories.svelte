<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtInputReference from './DvtInputReference.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputReferenceNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputReference',
		component: DvtInputReference,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/**
	 * Mock driver seeded with a single `iam.Account` document so the read-only
	 * path can hydrate a capsule label for the `owner_id` reference.
	 *
	 * `MockDataSource` synthesises `display_name` from `name` so hydrated
	 * capsules have a meaningful label without a doctype-def round-trip.
	 */
	function buildDriver(): MockDataDriver {
		const driver = new MockDataDriver();
		driver
			.domain('iam')
			.doctype('Account', [
				{ id: 'iam.Account.owner-1', name: 'Kim Patel', email: 'kim@acme.com' }
			]);
		driver.registerDoctype('iam', 'Account', {
			domain: 'iam',
			doctype: 'Account',
			fields: { name: { type: 'string' }, email: { type: 'string' } }
		});
		return driver;
	}

	const driver = buildDriver();

	const ownerDef: DoctypeDef = {
		domain: 'crm',
		doctype: 'Company',
		schema_version: 1,
		aggregate_root: true,
		fields: [
			{
				key: 'owner_id',
				type: 'reference',
				doctype: 'iam.Account',
				title: 'Owner'
			}
		],
		children: [],
		actions: []
	};

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'crm.Company.1',
				mid: 'crm.Company.1',
				domain: 'crm',
				doc_type: 'Company',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Owner')).toBeVisible();
		// The bound value is reflected in the picker's hidden value channel —
		// we assert the label is wired, not the search interaction (the
		// search path needs a fuller mock harness and is out of scope here).
		await expect(canvas.getByText('Owner')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-reference',
			field: 'owner_id',
			label: 'Owner',
			doctype: 'iam.Account',
			placeholder: 'Search owners…'
		} satisfies InputReferenceNode,
		document: doc({ owner_id: 'iam.Account.owner-1' }),
		values: { owner_id: 'iam.Account.owner-1' },
		def: ownerDef,
		driver
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputReference
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				driver={args.driver}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Owner is required')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-reference',
			field: 'owner_id',
			label: 'Owner',
			doctype: 'iam.Account',
			required: true
		} satisfies InputReferenceNode,
		document: doc({}),
		values: { owner_id: '' },
		def: ownerDef,
		driver,
		fieldErrors: { owner_id: [{ message: 'Owner is required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputReference
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				driver={args.driver}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Owner')).toBeVisible();
		// A read-only reference renders the hydrated capsule label.
		await expect(canvas.getByText('Kim Patel')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-reference',
			field: 'owner_id',
			label: 'Owner',
			doctype: 'iam.Account'
		} satisfies InputReferenceNode,
		document: doc({ owner_id: 'iam.Account.owner-1' }),
		def: ownerDef,
		driver
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputReference
				template={args.template}
				document={args.document}
				def={args.def}
				driver={args.driver}
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
		min-height: 80px;
	}
</style>
