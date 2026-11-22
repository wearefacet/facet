<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtField from './DvtField.svelte';
	import { setVisibleTags } from '$lib/permissions.svelte';
	import { artifactMetadataCache } from '$lib/datasource/clientCache.js';
	import type { DocumentMeta } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtField',
		component: DvtField,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>) {
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

	/** A minimal doctype def carrying just the `end` datetime field. */
	const datetimeDef: DoctypeDef = {
		doctype: 'CandidateExperience',
		domain: 'hr',
		schema_version: 1,
		aggregate_root: false,
		description: '',
		children: [],
		actions: [],
		fields: [{ key: 'end', type: 'datetime', title: 'End Date' }]
	};

	/** A minimal doctype def carrying `phone` and `website` fields. */
	const contactDef: DoctypeDef = {
		doctype: 'Contact',
		domain: 'crm',
		schema_version: 1,
		aggregate_root: true,
		description: '',
		children: [],
		actions: [],
		fields: [
			{ key: 'phone', type: 'phone', title: 'Phone' },
			{ key: 'website', type: 'url', title: 'Website' }
		]
	};

	/** A minimal doctype def carrying an `avatar` file field. */
	const fileDef: DoctypeDef = {
		doctype: 'Asset',
		domain: 'core',
		schema_version: 1,
		aggregate_root: false,
		description: '',
		children: [],
		actions: [],
		fields: [{ key: 'avatar', type: 'file', title: 'Avatar' }]
	};

	/** A def pairing an untagged field with a salary field tagged
	 * `['compensation']` — the B-176 tag-mask pair. */
	const taggedDef: DoctypeDef = {
		doctype: 'Employee',
		domain: 'hr',
		schema_version: 1,
		aggregate_root: true,
		description: '',
		children: [],
		actions: [],
		fields: [
			{ key: 'name', type: 'string', title: 'Name' },
			{ key: 'salary', type: 'integer', title: 'Salary', tags: ['compensation'] }
		]
	};

	const FILE_ARTIFACT_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';
</script>

<Story
	name="SimpleField"
	args={{
		template: { type: 'field', label: 'Name', value: '$name' },
		document: doc({ name: 'Alice Johnson' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="LiteralValue"
	args={{
		template: { type: 'field', label: 'Invoice #', value: 'INV-2024-001' },
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="NestedField"
	args={{
		template: { type: 'field', label: 'City', value: '$address.city' },
		document: doc({ address: { city: 'San Francisco' } })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingField"
	args={{
		template: { type: 'field', label: 'Unknown', value: '$missing_field' },
		document: doc({ name: 'Alice' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="FieldWithChildren"
	args={{
		template: {
			type: 'field',
			label: 'Email',
			value: '$email',
			children: [{ type: 'email', label: '$email_label', href: 'mailto:$email' }]
		},
		document: doc({ email: 'alice@example.com', email_label: 'alice@example.com' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="PhoneField"
	args={{
		template: { type: 'field', label: 'Phone', value: '$phone' },
		document: doc({ phone: '+1-555-0100' }),
		def: contactDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A phone-typed field renders a copy capsule, not plain text.
		await expect(canvas.getByRole('button', { name: /Copy/ })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="UrlField"
	args={{
		template: { type: 'field', label: 'Website', value: '$website' },
		document: doc({ website: 'https://acme.com' }),
		def: contactDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A url-typed field renders an external link that opens in a new tab.
		const link = canvas.getByRole('link', { name: /acme\.com/ });
		await expect(link).toHaveAttribute('target', '_blank');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="NullDatetime"
	args={{
		template: { type: 'field', label: 'End Date', value: '$end' },
		document: doc({ end: null }),
		def: datetimeDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A null datetime renders as a muted dash, never a "NaNi ago" label.
		await expect(canvas.getByText('—')).toBeVisible();
		await expect(canvas.queryByText(/ago/)).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="FileField"
	args={{
		template: { type: 'field', label: 'Avatar', value: '$avatar' },
		document: doc({ avatar: FILE_ARTIFACT_ID }),
		def: fileDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The artifact metadata cache is shared across stories; drop the entry so
		// this story renders the pre-fetch state (the id as the label) whatever
		// an earlier story resolved.
		artifactMetadataCache.invalidate(FILE_ARTIFACT_ID);
		// A file-typed field renders an artifact download link labelled with
		// the stored id; the grant URL is minted lazily on click, never on
		// render, so the link starts as the in-page anchor `#`.
		const link = canvas.getByRole('link');
		await expect(link).toHaveTextContent(FILE_ARTIFACT_ID);
		await expect(link).toHaveAttribute('target', '_blank');
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<!-- F10-05: a tag-masked field renders no row on the template display path
	— the same `fieldVisible` filter the fallback form applies. The backend
	read mask omitted the masked field's key from `content`, so the row would
	only ever draw the generic blank dash. The store is set (and reset) inside
	the play, so other stories keep the fail-open null-store default. -->
<Story
	name="SkipsInvisibleField"
	args={{
		template: { type: 'field', label: 'Name', value: '$name' },
		// The read mask omitted `salary`; the visible field keeps its value.
		document: doc({ name: 'Alice Johnson' }),
		def: taggedDef
	}}
	play={async ({ canvasElement }) => {
		setVisibleTags(['default']);
		try {
			const canvas = within(canvasElement);
			await expect(canvas.getByText('Name')).toBeVisible();
			await expect(canvas.getByText('Alice Johnson')).toBeVisible();
			// The masked field renders nothing at all — no label, no dash.
			expect(canvas.queryByText('Salary')).toBeNull();
			expect(canvas.queryByText('—')).toBeNull();
		} finally {
			setVisibleTags(null);
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
			<!-- The masked sibling: same def, same document. -->
			<DvtField
				template={{ type: 'field', label: 'Salary', value: '$salary' }}
				document={args.document}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<!-- F10-05 counterpart: a field whose tags the active role holds renders
	as usual even though it is tagged — the mask is per-tag, not per-tagged. -->
<Story
	name="ShowsTaggedFieldWhenVisible"
	args={{
		template: { type: 'field', label: 'Salary', value: '$salary' },
		document: doc({ salary: 120000 }),
		def: taggedDef
	}}
	play={async ({ canvasElement }) => {
		setVisibleTags(['default', 'compensation']);
		try {
			const canvas = within(canvasElement);
			await expect(canvas.getByText('Salary')).toBeVisible();
			await expect(canvas.getByText('120000')).toBeVisible();
		} finally {
			setVisibleTags(null);
		}
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtField template={args.template} document={args.document} def={args.def} />
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
