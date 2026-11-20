<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, waitFor, within } from 'storybook/test';
	import DvtInput from './DvtInput.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types';
	import type { InputAutoNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInput',
		component: DvtInput,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): the dispatched
		// reference picker carries the known nested-interactive violation.
		parameters: { a11y: { test: 'todo' } }
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	// One definition exercising every dispatch row: derived enum options,
	// derived reference target, sub-typed scalars, and the not-editable
	// containers.
	const def: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [
			{ key: 'name', type: 'string', title: 'Name', required: true },
			{ key: 'headcount', type: 'integer', title: 'Headcount' },
			{
				key: 'industry',
				type: 'enum',
				title: 'Industry',
				values: [{ key: 'technology', label: 'Technology' }, { key: 'finance' }]
			},
			{ key: 'active', type: 'boolean', title: 'Active' },
			{ key: 'starts_at', type: 'datetime', title: 'Starts At' },
			{ key: 'closes_on', type: 'date', title: 'Closes On' },
			{ key: 'window', type: 'period', title: 'Window' },
			{ key: 'days', type: 'dateperiod', title: 'Days' },
			{ key: 'notes', type: 'longtext', title: 'Notes' },
			{ key: 'revenue', type: 'money', title: 'Revenue', currency: 'EUR' },
			{ key: 'brand_color', type: 'color', title: 'Brand Color' },
			{ key: 'logo', type: 'file', title: 'Logo' },
			{ key: 'api_key', type: 'secret', title: 'API Key' },
			{ key: 'owner_id', type: 'reference', title: 'Owner', doctype: 'iam.Account' },
			{
				key: 'dept_name',
				type: 'string',
				title: 'Dept Name',
				replicate: { via: 'department', field: 'name' }
			},
			{ key: 'website', type: 'url', title: 'Website' },
			{ key: 'phone', type: 'phone', title: 'Phone' },
			{ key: 'tags', type: 'array', title: 'Tags' },
			{ key: 'address', type: 'object', title: 'Address' },
			{ key: 'metadata', type: 'dictionary', title: 'Metadata' },
			{ key: 'computed', type: 'data', title: 'Computed', compute: 'build' }
		],
		children: [],
		actions: []
	};

	// Seeded mock driver — the dispatched reference picker searches through it.
	const refDriver = new MockDataDriver();
	refDriver
		.domain('iam')
		.doctype('Account', [{ id: 'iam.Account.owner-1', name: 'Kim Patel', email: 'kim@acme.com' }]);

	const auto = (field: string, extra: Partial<InputAutoNode> = {}): InputAutoNode => ({
		type: 'input',
		field,
		...extra
	});
</script>

<Story
	name="TextFromType"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Label derives from the field title; the required flag derives from the def.
		await expect(canvas.getByText('Name')).toBeVisible();
	}}
	args={{
		template: auto('name'),
		document: doc({ name: 'Acme' }),
		values: { name: 'Acme' },
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="NumberFromInteger"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Headcount')).toBeVisible();
		const input = canvas.getByRole('spinbutton');
		await expect(input).toHaveValue(42);
	}}
	args={{
		template: auto('headcount'),
		document: doc({ headcount: 42 }),
		values: { headcount: 42 },
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SelectFromEnum"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Industry')).toBeVisible();
		// The current value flows into the combobox input — options came from
		// the definition's values, not from template props.
		await expect(canvas.getByDisplayValue('Technology')).toBeVisible();
	}}
	args={{
		template: auto('industry'),
		document: doc({ industry: 'technology' }),
		values: { industry: 'technology' },
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ToggleFromBoolean"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Active')).toBeVisible();
		const toggle = canvas.getByRole('switch');
		await expect(toggle).toBeChecked();
	}}
	args={{
		template: auto('active'),
		document: doc({ active: true }),
		values: { active: true },
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceFromDef"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Owner')).toBeVisible();
		// The picker renders its combobox chrome; the target doctype comes
		// from the definition (`iam.Account`), not from template props.
		await expect(canvas.getByRole('combobox')).toBeVisible();
	}}
	args={{
		template: auto('owner_id'),
		document: doc({ owner_id: 'iam.Account.owner-1' }),
		values: { owner_id: 'iam.Account.owner-1' },
		def,
		driver: refDriver
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
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
	name="ReadOnlyLongtext"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No values bag — every specialized component has a read-only branch.
		await expect(canvas.getByText('Notes')).toBeVisible();
		// The read-only markdown mounts asynchronously through the Milkdown
		// engine (same wait as the DvtInputLongtext story).
		await waitFor(() => {
			expect(canvas.getByText('Long-form body')).toBeVisible();
		});
	}}
	args={{
		template: auto('notes'),
		document: doc({ notes: 'Long-form body' }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="NotEditableArray"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The auto node never binds a container — a diagnostic names the fix.
		await expect(canvas.getByRole('alert')).toBeVisible();
		await expect(canvas.getByText(/input-list/)).toBeVisible();
	}}
	args={{
		template: auto('tags'),
		document: doc({ tags: ['a'] }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="NotEditableObject"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('alert')).toBeVisible();
		await expect(canvas.getByText(/'object' node/)).toBeVisible();
	}}
	args={{
		template: auto('address'),
		document: doc({}),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="NotEditableComputed"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('alert')).toBeVisible();
		await expect(canvas.getByText(/read-only/)).toBeVisible();
	}}
	args={{
		template: auto('computed'),
		document: doc({}),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="ReplicatedRendersReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A replicated field is server-populated: even with a `values` bag the
		// form renders its value read-only, never an editable control.
		await expect(canvas.getByText('Dept Name')).toBeVisible();
		await expect(canvas.getByText('Engineering')).toBeVisible();
		await expect(canvas.queryByRole('textbox')).toBeNull();
		await expect(canvas.getByText(/populated by replication/)).toBeVisible();
	}}
	args={{
		template: auto('dept_name'),
		document: doc({ dept_name: 'Engineering' }),
		values: { dept_name: 'Engineering' },
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="MissingDefFallsBackToText"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Display safety: without a definition the node still renders an
		// editable text control, labelled from the humanized key.
		await expect(canvas.getByText('Mystery')).toBeVisible();
	}}
	args={{
		template: auto('mystery'),
		document: doc({ mystery: 'x' }),
		values: { mystery: 'x' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInput
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
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
