<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, fireEvent, userEvent } from 'storybook/test';
	import CollectionViewGridForm from './CollectionViewGridForm.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef } from '$lib/doctype/types.js';
	import type { CollectionViewColumn } from '$lib/collectionView/types.js';

	// The grid step edits a `crm.Deal` view — the fixture carries money /
	// integer (aggregate-able), enum / reference / dates (writable), a
	// computed `weighted_value` (read-only section), and the system
	// timestamps the grid renders but never edits.
	const driver = createMockDriver();
	const dealDef = parseDoctypeDef(driver.getDoctypeDefinition('crm.Deal')!);

	/** Fields the FilterBar may filter on — the editor's derivation. */
	/** A fresh column seed per template render. Explicit keys, not
	 *  `defaultColumns` — the fixture loader sorts the schema fields
	 *  alphabetically, so the seeded set shifts with the fixture. The form
	 *  replaces (never mutates) the array, so the shared reference stays
	 *  pristine across tests. */
	function seedColumns(): CollectionViewColumn[] {
		return [
			{ key: 'title', label: 'Deal Title' },
			{ key: 'value', label: 'Deal Value' },
			{ key: 'status', label: 'Status' },
			{ key: 'probability', label: 'Probability' }
		];
	}

	/** Wait for the render to settle. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/CollectionViewGridForm',
		component: CollectionViewGridForm,
		tags: ['autodocs']
	});
</script>

<!--
	The grid step of the view editor, mounted standalone. The plays assert
	the grid column semantics — the Edit opt-out, the Σ summary picker, the
	frozen markers — through the DOM the form renders, which mirrors the
	draft the parent persists. The stored-config rules themselves are pinned
	in `config.spec.ts` (the `buildConfig — grid` block) and through the
	editor stories, which read the saved payload back from the driver.

	The form renders inline (no dialog portal), so the plays query
	`within(canvasElement)`.
-->

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The settings strip: frozen select (None while unset) and the
		// new-row opt-in toggle.
		await expect(canvas.getByRole('combobox', { name: 'Frozen columns' })).toHaveValue('0');
		await expect(canvas.getByRole('group', { name: 'Grid' })).toBeVisible();
		await expect(canvas.getByRole('switch', { name: 'New rows' })).not.toBeChecked();
		// The picker splits the remaining fields into the two sections; the
		// computed field lands under Read-only.
		await expect(canvas.getByText('Editable in grid')).toBeVisible();
		await expect(canvas.getByText('Read-only')).toBeVisible();
		// The seeded columns render with the default-on Edit checkbox.
		const editableChecks = canvas.getAllByRole('checkbox', {
			name: /Edit in grid for column/
		});
		await expect(editableChecks.length).toBe(4);
		for (const box of editableChecks) await expect(box).toBeChecked();
		// The helper states the opt-out rule.
		await expect(canvas.getByText(/Every writable column is editable/)).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EditOptOut"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// Unchecking the Edit box persists the `editable: false` opt-out —
		// the checkbox itself is the draft the parent would store.
		const box = canvas.getByRole('checkbox', {
			name: 'Edit in grid for column value'
		}) as HTMLInputElement;
		await expect(box).toBeChecked();
		await fireEvent.click(box);
		await sleep(10);
		await expect(box).not.toBeChecked();
		// Checking again drops the flag — absent reads editable again.
		await fireEvent.click(box);
		await sleep(10);
		await expect(box).toBeChecked();
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>

<Story
	name="SummaryPicker"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// A money column offers the field aggregates next to count.
		const moneySelect = canvas.getByRole('combobox', {
			name: 'Summary for column value'
		}) as HTMLSelectElement;
		const moneyOptions = [...moneySelect.options].map((o) => o.value);
		await expect(moneyOptions).toEqual(['', 'count', 'sum', 'avg', 'min', 'max']);
		await userEvent.selectOptions(moneySelect, 'sum');
		await sleep(10);
		await expect(moneySelect).toHaveValue('sum');
		// A string column offers count only — the backend refuses the rest.
		const stringSelect = canvas.getByRole('combobox', {
			name: 'Summary for column title'
		}) as HTMLSelectElement;
		const stringOptions = [...stringSelect.options].map((o) => o.value);
		await expect(stringOptions).toEqual(['', 'count']);
		// Clearing the summary drops the key — the select reads None again.
		await userEvent.selectOptions(moneySelect, '');
		await sleep(10);
		await expect(moneySelect).toHaveValue('');
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>

<Story
	name="FrozenMarker"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// Freezing one column pins the first row — exactly one marker shows.
		await fireEvent.change(canvas.getByRole('combobox', { name: 'Frozen columns' }), {
			target: { value: '1' }
		});
		await sleep(10);
		await expect(canvas.getByRole('combobox', { name: 'Frozen columns' })).toHaveValue('1');
		await expect(canvas.getAllByText('Frozen')).toHaveLength(1);
		// Freezing never exceeds the column set — the select offers 0..N.
		const options = [
			...(canvas.getByRole('combobox', { name: 'Frozen columns' }) as HTMLSelectElement).options
		].map((o) => o.value);
		await expect(options).toEqual(['0', '1', '2', '3', '4']);
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>

<Story
	name="AddReadOnlyColumn"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// The computed field sits in the Read-only section; adding it lands
		// a row with the fx note and no Edit checkbox.
		await fireEvent.click(canvas.getByRole('button', { name: 'Add column weighted_value' }));
		await sleep(10);
		await expect(
			canvas.queryByRole('checkbox', { name: 'Edit in grid for column weighted_value' })
		).toBeNull();
		await expect(canvas.getByText('Computed — read-only')).toBeVisible();
		// Freeze every column, then remove the added one — the frozen count
		// clamps to the remaining set (4).
		await fireEvent.change(canvas.getByRole('combobox', { name: 'Frozen columns' }), {
			target: { value: '5' }
		});
		await sleep(10);
		await expect(canvas.getAllByText('Frozen')).toHaveLength(5);
		await fireEvent.click(canvas.getByRole('button', { name: 'Remove column weighted_value' }));
		await sleep(10);
		await expect(canvas.getAllByText('Frozen')).toHaveLength(4);
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyColumnsError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// An emptied draft: the columns error shows in the head, the selected
		// pane carries the empty state, and the frozen select clamps to the
		// empty set — only None remains.
		await expect(canvas.getByText('Add at least one column')).toBeVisible();
		await expect(canvas.getByText('No columns — add one from the left')).toBeVisible();
		const options = [
			...(canvas.getByRole('combobox', { name: 'Frozen columns' }) as HTMLSelectElement).options
		].map((o) => o.value);
		await expect(options).toEqual(['0']);
		// Re-adding a field lands a row again (the editor owns reacting to
		// the empty set; the form only renders what the draft holds).
		await fireEvent.click(canvas.getByRole('button', { name: 'Add column title' }));
		await sleep(10);
		await expect(canvas.queryByText('No columns — add one from the left')).toBeNull();
		await expect(
			canvas.getByRole('checkbox', { name: 'Edit in grid for column title' })
		).toBeChecked();
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm
				{driver}
				doctype={dealDef}
				columns={[]}
				columnsError="Add at least one column"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SortAndFilters"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await sleep(50);
		// Pick a row sort field; the direction radios compose the entry.
		await userEvent.click(canvas.getByRole('combobox', { name: 'Row sort' }));
		await sleep(20);
		const body = within(document.body);
		await userEvent.click(body.getAllByRole('option', { name: /Deal Value/ })[0]);
		await sleep(20);
		await expect(canvas.getByRole('combobox', { name: 'Row sort' })).toHaveValue('Deal Value');
		await fireEvent.click(canvas.getByRole('radio', { name: 'Ascending' }));
		await sleep(10);
		await expect(canvas.getByRole('radio', { name: 'Ascending' })).toHaveAttribute(
			'aria-checked',
			'true'
		);
		// The base filter bar renders (the kanban rule).
		await expect(canvas.getByText('Filters')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 900px; padding: 16px;">
			<CollectionViewGridForm {driver} doctype={dealDef} columns={seedColumns()} />
		</div>
	{/snippet}
</Story>
