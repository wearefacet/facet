<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import DvtInputMoney from './DvtInputMoney.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputMoneyNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputMoney',
		component: DvtInputMoney,
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

	const dealDef: DoctypeDef = {
		domain: 'crm',
		doctype: 'Deal',
		schema_version: 1,
		aggregate_root: true,
		fields: [{ key: 'value', type: 'money', currency: 'USD', title: 'Deal Value', required: true }],
		children: [],
		actions: []
	};

	function doc(data: Record<string, unknown>): DocumentResponse {
		return {
			data,
			meta: {
				id: 'crm.Deal.1',
				mid: 'crm.Deal.1',
				domain: 'crm',
				doc_type: 'Deal',
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
		await expect(canvas.getByText('Deal Value')).toBeVisible();
		// The amount input reflects the seeded value, formatted with `'` grouping.
		const amountInput = canvas.getByDisplayValue("4'200") as HTMLInputElement;
		await expect(amountInput).toBeVisible();
		// The currency is internalized as a left-side button showing symbol + code.
		await expect(canvas.getByText('USD')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({ value: { value: '4200', currency: 'USD' } }),
		values: { value: { value: '4200', currency: 'USD' } },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CurrencySwitch"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Open the currency dropdown.
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		// Type to filter: only EUR should survive.
		const filterInput = canvas.getByPlaceholderText('Filter currencies…');
		await filterInput.focus();
		await userEvent.type(filterInput, 'eur');
		const opts = canvas.getAllByRole('option');
		await expect(opts).toHaveLength(1);
		await expect(opts[0]).toHaveTextContent('EUR');
		await opts[0].click();
		// The internal button now reflects the new selection.
		await expect(canvas.getByText('EUR')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({ value: { value: '4200', currency: 'USD' } }),
		values: { value: { value: '4200', currency: 'USD' } },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypeaheadInAmountField"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// With an empty amount, typing a ticker directly into the amount input opens
		// the currency dropdown filtered to the typed text — no need to click the
		// currency button first.
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		await userEvent.type(amountInput, 'eur');
		const opts = canvas.getAllByRole('option');
		await expect(opts).toHaveLength(1);
		await expect(opts[0]).toHaveTextContent('EUR');
		// Enter selects the currency, clears the typed query, and the button now
		// shows the committed ticker.
		await userEvent.keyboard('{Enter}');
		await expect(canvas.getByText('EUR')).toBeVisible();
		// The amount field is cleared and ready for amount entry.
		await expect(amountInput).toHaveValue('');
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TypeaheadSpaceSelectsCurrency"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Typing a ticker prefix and pressing Space commits the currency (mirrors
		// Enter) — the common "EUR 1000" flow: type `EUR`, Space, then the amount.
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		await userEvent.type(amountInput, 'eur');
		const opts = canvas.getAllByRole('option');
		await expect(opts).toHaveLength(1);
		// Space selects EUR; no literal space is left in the amount field.
		await userEvent.keyboard(' ');
		await expect(canvas.getByText('EUR')).toBeVisible();
		await expect(amountInput).toHaveValue('');
		// The user can now type the amount, which formats with grouping.
		await userEvent.type(amountInput, '1000');
		await expect(amountInput).toHaveValue("1'000");
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="VisualThousandsSeparator"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The displayed text groups digits with `'`; the raw model (emitted to the
		// form) stays plain decimal.
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		await userEvent.type(amountInput, '4200');
		await expect(amountInput).toHaveValue("4'200");
		// Multi-digit grouping accumulates from the right (1'234'567).
		await userEvent.type(amountInput, '0');
		await expect(amountInput).toHaveValue("42'000");
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="PreferredCurrencyFirst"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The field def declares currency: 'USD' → USD pins first in the dropdown.
		// (The button itself reads “Currency” while the amount is empty — the
		// committed ticker only surfaces once an amount is typed.)
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		const opts = canvas.getAllByRole('option');
		// The first option is the preferred ticker (USD).
		await expect(opts[0]).toHaveTextContent('USD');
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyAmountShowsCurrencyPlaceholder"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A cleared amount does not show a committed ticker — the adornment reads
		// “Currency” so the field looks empty rather than auto-defaulted to USD.
		await expect(canvas.getByText('Currency')).toBeVisible();
		// Typing an amount restores the remembered (preferred) ticker.
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		await userEvent.type(amountInput, '100');
		await expect(canvas.getByText('USD')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Deal Value is required')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			required: true
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef,
		fieldErrors: { value: [{ message: 'Deal Value is required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Deal Value')).toBeVisible();
		// Read-only money renders via the shared Money display component.
		await expect(canvas.getByText('$ 4,200.00')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value'
		} satisfies InputMoneyNode,
		document: doc({ value: { value: '4200', currency: 'USD' } }),
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="InvalidAmount"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Type a digit-led but malformed amount (two decimal points) and assert the
		// local shape error surfaces. (Typeahead only engages on a leading letter;
		// a digit-led input stays in amount-entry mode.)
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		// Type the malformed value one character at a time to also exercise the
		// writeback path on every keystroke (the seed↔writeback loop the component
		// must not re-introduce when typing a decimal point that fails validation).
		await userEvent.type(amountInput, '12');
		await userEvent.type(amountInput, '.');
		await userEvent.type(amountInput, '3');
		await userEvent.type(amountInput, '.');
		await userEvent.type(amountInput, '4');
		await expect(amountInput).toHaveValue('12.3.4');
		await expect(canvas.getByText('Amount must be a decimal number (e.g. 9.99)')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-money',
			field: 'value',
			label: 'Deal Value',
			placeholder: '0'
		} satisfies InputMoneyNode,
		document: doc({}),
		values: { value: '' },
		def: dealDef
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputMoney
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
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
