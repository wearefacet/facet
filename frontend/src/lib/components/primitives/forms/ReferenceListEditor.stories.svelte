<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import ReferenceListEditor from './ReferenceListEditor.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';

	const driver = createMockDriver();

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/ReferenceListEditor',
		component: ReferenceListEditor,
		tags: ['autodocs'],
		args: { driver },
		// A11y backlog (audit 22 — see .storybook/preview.ts): the embedded
		// ReferencePicker carries the same violations as the standalone one.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	// The editor mutates `value` in place (push / splice), so the interactive
	// stories pass $state proxies — a plain array would take the mutation but
	// the chips would not re-render. Each play resets its array first, so
	// story order cannot skew an assertion.
	const seedCompanies = ['crm.Company.1', 'crm.Company.2'];

	let selectedValues = $state<string[]>([...seedCompanies]);
	let addValues = $state<string[]>([]);
	let removeValues = $state<string[]>([...seedCompanies]);
	let duplicateValues = $state<string[]>(['crm.Company.1']);
</script>

<Story
	name="Empty"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		addValues = [];
		const canvas = within(canvasElement);
		// No chips yet — only the add picker renders.
		await expect(canvas.getByPlaceholderText('Search and add…')).toBeVisible();
		await waitFor(() => {
			expect(canvasElement.querySelectorAll('.rle-chip').length).toBe(0);
		});
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor label={args.label} doctype={args.doctype} {driver} value={addValues} />
		</div>
	{/snippet}
</Story>

<Story
	name="SelectedChips"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		selectedValues = [...seedCompanies];
		const canvas = within(canvasElement);
		// Each stored token hydrates its own capsule label.
		await waitFor(() => expect(canvas.getByText('Acme Corp')).toBeVisible());
		await expect(canvas.getByText('Globex Inc')).toBeVisible();
		// The raw qualified ids never render.
		expect(canvasElement.textContent ?? '').not.toContain('crm.Company.1');
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor
				label={args.label}
				doctype={args.doctype}
				{driver}
				value={selectedValues}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="AddAppendsQualifiedToken"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		addValues = [];
		const canvas = within(canvasElement);

		// Opening the add picker lists the target's records.
		const input = canvas.getByPlaceholderText('Search and add…');
		await userEvent.click(input);
		await waitFor(() => {
			expect(canvasElement.querySelectorAll('.ref-opt').length).toBeGreaterThan(0);
		});

		// Picking a record appends the QUALIFIED token (the picker writes the
		// bare id; the list editor qualifies it with the picked doctype).
		// Assertions scope to the chip list — the dropdown stays open, so the
		// picked label exists both as a chip and as a result row.
		const opt = Array.from(canvasElement.querySelectorAll('.ref-opt')).find((el) =>
			el.textContent?.includes('Initech')
		);
		expect(opt).toBeDefined();
		await userEvent.click(opt as HTMLElement);
		await waitFor(() => {
			const chipLabels = Array.from(canvasElement.querySelectorAll('.rle-chip .capsule')).map(
				(el) => el.textContent ?? ''
			);
			expect(chipLabels.some((t) => t.includes('Initech'))).toBe(true);
		});
		await expect(addValues).toEqual(['crm.Company.3']);

		// The dropdown stays open with the query intact — several targets
		// can be added in a row.
		expect(canvasElement.querySelectorAll('.ref-opt').length).toBeGreaterThan(0);

		// A second pick appends after the first.
		const second = Array.from(canvasElement.querySelectorAll('.ref-opt')).find((el) =>
			el.textContent?.includes('Acme Corp')
		);
		expect(second).toBeDefined();
		await userEvent.click(second as HTMLElement);
		await waitFor(() => {
			const chipLabels = Array.from(canvasElement.querySelectorAll('.rle-chip .capsule')).map(
				(el) => el.textContent ?? ''
			);
			expect(chipLabels.some((t) => t.includes('Acme Corp'))).toBe(true);
		});
		await expect(addValues).toEqual(['crm.Company.3', 'crm.Company.1']);
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor label={args.label} doctype={args.doctype} {driver} value={addValues} />
		</div>
	{/snippet}
</Story>

<Story
	name="DuplicateRejected"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		duplicateValues = ['crm.Company.1'];
		const canvas = within(canvasElement);

		const input = canvas.getByPlaceholderText('Search and add…');
		await userEvent.click(input);
		await waitFor(() => {
			expect(canvasElement.querySelectorAll('.ref-opt').length).toBeGreaterThan(0);
		});

		// Picking the already-selected target shows the duplicate message and
		// leaves the list untouched.
		const opt = Array.from(canvasElement.querySelectorAll('.ref-opt')).find((el) =>
			el.textContent?.includes('Acme Corp')
		);
		expect(opt).toBeDefined();
		await userEvent.click(opt as HTMLElement);
		const alert = await canvas.findByRole('alert');
		await expect(alert).toHaveTextContent('Already selected.');
		await expect(duplicateValues).toEqual(['crm.Company.1']);
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor
				label={args.label}
				doctype={args.doctype}
				{driver}
				value={duplicateValues}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RemoveChip"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		removeValues = [...seedCompanies];
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Acme Corp')).toBeVisible());

		// Each chip carries a labelled remove button; clicking one splices
		// exactly that token out of the bound array.
		await userEvent.click(canvas.getByRole('button', { name: 'Remove crm.Company.1' }));
		await waitFor(() => expect(canvas.queryByText('Acme Corp')).toBeNull());
		await expect(canvas.getByText('Globex Inc')).toBeVisible();
		await expect(removeValues).toEqual(['crm.Company.2']);
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor
				label={args.label}
				doctype={args.doctype}
				{driver}
				value={removeValues}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Disabled"
	args={{ label: 'Skills', doctype: 'crm.Company' }}
	play={async ({ canvasElement }) => {
		selectedValues = [...seedCompanies];
		const canvas = within(canvasElement);
		// Disabled state keeps the chips, drops the remove buttons, and locks
		// the add picker.
		await waitFor(() => expect(canvas.getByText('Acme Corp')).toBeVisible());
		await expect(canvas.queryByRole('button', { name: /Remove/ })).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="rle-frame">
			<ReferenceListEditor
				label={args.label}
				doctype={args.doctype}
				{driver}
				value={selectedValues}
				disabled
			/>
		</div>
	{/snippet}
</Story>

<style>
	.rle-frame {
		max-width: 480px;
		margin: 24px auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
	}
</style>
