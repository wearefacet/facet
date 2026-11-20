<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import DvtInputText from './DvtInputText.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputTextNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputText',
		component: DvtInputText,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>, id = 'test.1'): DocumentResponse {
		return {
			data,
			meta: {
				id,
				mid: id,
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	/** A minimal def exposing `website` as a `url` field so the read-only path
	 *  routes through `DvtValue`'s URL branch (renders via `UrlLink`). */
	const urlDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Test',
		schema_version: 1,
		aggregate_root: false,
		fields: [{ key: 'website', type: 'url', title: 'Website' }],
		children: [],
		actions: []
	};
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Company Name')).toBeVisible();
		await expect(canvas.getByDisplayValue('Acme Corp')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'name',
			label: 'Company Name',
			required: true
		} satisfies InputTextNode,
		document: doc({ name: 'Acme Corp' }),
		values: { name: 'Acme Corp' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Name is required')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'name',
			label: 'Company Name',
			required: true
		} satisfies InputTextNode,
		document: doc({}),
		values: { name: '' },
		fieldErrors: { name: [{ message: 'Name is required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithPrefix"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A non-url field's declared prefix renders as an inline adornment
		// before the input value.
		const affix = canvas.getByText('PRJ-');
		await expect(affix).toBeVisible();
		// The input reserves room for the measured affix width, so the value
		// never slides under the adornment's opaque box.
		const input = canvas.getByDisplayValue('0042');
		await waitFor(() => {
			const padLeft = parseFloat(getComputedStyle(input).paddingLeft);
			expect(padLeft).toBeGreaterThanOrEqual(affix.getBoundingClientRect().width);
		});
		// Editing the bound value still flows into the values bag.
		await userEvent.clear(input);
		await userEvent.type(input, '0099');
		await expect(canvas.getByDisplayValue('0099')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'code',
			label: 'Project Code',
			inputType: 'text',
			prefix: 'PRJ-'
		} satisfies InputTextNode,
		document: doc({ code: '0042' }),
		values: { code: '0042' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithSchemeValue"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A self-describing url value carries its scheme — the implied-scheme
		// chrome would only duplicate it, so it is not rendered and the value
		// keeps the full width.
		await expect(canvas.queryByText('https://')).toBeNull();
		await expect(canvas.getByDisplayValue('https://www.acme.com')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website',
			inputType: 'url',
			prefix: 'https://'
		} satisfies InputTextNode,
		document: doc({ website: 'https://www.acme.com' }),
		values: { website: 'https://www.acme.com' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="BareHostCommit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// While editing a dotted bare host the chrome stays visible — it is
		// the hint for the scheme the field will commit (B-294).
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'www.acme.tld');
		await expect(canvas.getByText('https://')).toBeVisible();
		// On commit (blur) the value is rewritten to the absolute form the
		// backend stores, and the chrome steps aside.
		await userEvent.tab();
		await waitFor(() => {
			expect(canvas.getByDisplayValue('https://www.acme.tld')).toBeVisible();
		});
		await expect(canvas.queryByText('https://')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website',
			inputType: 'url',
			prefix: 'https://'
		} satisfies InputTextNode,
		document: doc({}),
		values: { website: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SchemelessRefused"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// B-294: a dotless scheme-less value is refused, not completed into
		// `https://not-a-url`. On commit (blur) the raw text stays in the
		// field and the field reads invalid — the same value a REST client
		// sends gets a 422 from the backend.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'not-a-url');
		// The chrome still hints at the scheme the stored form would carry.
		await expect(canvas.getByText('https://')).toBeVisible();
		await userEvent.tab();
		await expect(
			canvas.getByText(
				'Not a valid URL (expected an absolute http(s):// address with a valid host).'
			)
		).toBeVisible();
		await expect(canvas.getByDisplayValue('not-a-url')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website',
			inputType: 'url'
		} satisfies InputTextNode,
		document: doc({}),
		values: { website: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="UrlCommitAccepted"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A self-describing url value is stored verbatim: no chrome, and the
		// blur commit validates it without rewriting anything.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'https://www.acme.com');
		await expect(canvas.queryByText('https://')).toBeNull();
		await userEvent.tab();
		await expect(canvas.queryByText(/Not a valid URL/)).toBeNull();
		await expect(canvas.getByDisplayValue('https://www.acme.com')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website',
			inputType: 'url'
		} satisfies InputTextNode,
		document: doc({}),
		values: { website: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="MalformedUrlShowsError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// B-174/B-294: a value the backend would refuse never becomes committed
		// data. The raw text stays in the field and the field reads invalid
		// instead of silently holding `https://ht!tp://bad url`.
		const input = canvas.getByRole('textbox');
		await userEvent.type(input, 'ht!tp://bad url');
		await userEvent.tab();
		await expect(
			canvas.getByText(
				'Not a valid URL (expected an absolute http(s):// address with a valid host).'
			)
		).toBeVisible();
		await expect(canvas.getByDisplayValue('ht!tp://bad url')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website',
			inputType: 'url'
		} satisfies InputTextNode,
		document: doc({}),
		values: { website: '' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Website')).toBeVisible();
		// A read-only url field renders the value through `UrlLink` (external
		// link capsule), not as an editable textbox.
		await expect(canvas.getByText('acme.com')).toBeVisible();
		await expect(canvas.queryByRole('textbox')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-text',
			field: 'website',
			label: 'Website'
		} satisfies InputTextNode,
		document: doc({ website: 'acme.com' }),
		def: urlDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputText template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="UniqueIdsAcrossRows"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Two inline child rows render the same field label. The row document's
		// meta.id scopes the synthesized id, so the ids stay unique and every
		// <label for> association holds (B-394).
		const inputs = canvas.getAllByLabelText('Qty');
		expect(inputs).toHaveLength(2);
		const ids = inputs.map((el) => el.id);
		expect(ids).toEqual(['input-crm.Line.1-Qty', 'input-crm.Line.2-Qty']);
		expect(new Set(ids).size).toBe(ids.length);
		for (const id of ids) {
			expect(canvasElement.querySelectorAll(`[id="${id}"]`)).toHaveLength(1);
		}
	}}
>
	{#snippet template()}
		<div class="dvt-story-frame">
			<DvtInputText
				template={{ type: 'input-text', field: 'qty', label: 'Qty' } satisfies InputTextNode}
				document={doc({ qty: '2' }, 'crm.Line.1')}
				values={sessionBag({ qty: '2' })}
			/>
			<DvtInputText
				template={{ type: 'input-text', field: 'qty', label: 'Qty' } satisfies InputTextNode}
				document={doc({ qty: '5' }, 'crm.Line.2')}
				values={sessionBag({ qty: '5' })}
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
