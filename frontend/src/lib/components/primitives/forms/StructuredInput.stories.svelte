<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import StructuredInput from './StructuredInput.svelte';
	import type { FieldDef } from '$lib/doctype/types.js';

	/** One object field with two declared properties — the canonical fixture. */
	const addressField: FieldDef = {
		key: 'address',
		type: 'object',
		title: 'Address',
		properties: [
			{ key: 'street', type: 'string' },
			{ key: 'floors', type: 'integer' }
		]
	};

	/** One array-of-strings field. */
	const tagsField: FieldDef = {
		key: 'tags',
		type: 'array',
		title: 'Tags',
		items: { key: '(items)', type: 'string' }
	};

	/** One dictionary field with an integer entry schema. */
	const countersField: FieldDef = {
		key: 'counters',
		type: 'dictionary',
		title: 'Counters',
		dictionaryValue: { key: '(value)', type: 'integer' }
	};

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/StructuredInput',
		component: StructuredInput,
		tags: ['autodocs'],
		argTypes: {
			// The schema fixture is a per-story concern; the controls pane stays
			// focused on the observable surface.
			field: { table: { disable: true } }
		}
	});
</script>

<!--
	StructuredInput — the JSON editor for object / array / dictionary fields
	(B-105). The plays type into the textarea like a user and assert the bound
	`value` through the `onchange` mock — the component calls it with each
	parsed structure, so the writes are observable without touching args.
	`userEvent.clear` empties the field first: that emits the `''` cleared
	sentinel, so later assertions check the LAST call.
-->

<Story
	name="BlankStartsEmpty"
	args={{ field: addressField, label: 'Address', value: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;
		expect(box.value).toBe('');
		// The helper names the expected JSON shape until an error replaces it.
		expect(
			canvas.getByText('One JSON object, array, or dictionary per the field schema.')
		).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput field={args.field} label={args.label} value={args.value} id="s-blank" />
		</div>
	{/snippet}
</Story>

<Story
	name="SeedsAndBindsTheParsedStructure"
	args={{
		field: addressField,
		label: 'Address',
		value: { street: 'Main St', floors: 3 },
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);

		// A stored structure seeds the textarea as pretty JSON.
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;
		await waitFor(() => expect(box.value).toBe('{\n  "street": "Main St",\n  "floors": 3\n}'));

		// Editing re-binds the parsed structure — the raw text never travels
		// (B-105: the dictionary input submitted raw text).
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street":"Elm St","floors":1}');
		await waitFor(() =>
			expect(args.onchange).toHaveBeenCalledWith({ street: 'Elm St', floors: 1 })
		);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput
				field={args.field}
				label={args.label}
				value={args.value}
				onchange={args.onchange}
				id="s-seed"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="InvalidJsonShowsAnErrorAndBindsNothing"
	args={{
		field: addressField,
		label: 'Address',
		value: { street: 'Main St', floors: 3 },
		onchange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;
		await waitFor(() => expect(box.value).not.toBe(''));

		// Broken JSON: the field-level error renders…
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street": ');
		await waitFor(() => expect(canvas.getByRole('alert')).toHaveTextContent(/Invalid JSON/));
		// …and nothing new binds: the last emit stays the cleared sentinel.
		expect(args.onchange).toHaveBeenLastCalledWith('');

		// Fixing the text binds the parsed structure and clears the error.
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street":"Elm St","floors":2}');
		await waitFor(() =>
			expect(args.onchange).toHaveBeenLastCalledWith({ street: 'Elm St', floors: 2 })
		);
		await waitFor(() => expect(canvas.queryByRole('alert')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput
				field={args.field}
				label={args.label}
				value={args.value}
				onchange={args.onchange}
				id="s-invalid"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SchemaMismatchNamesThePath"
	args={{ field: tagsField, label: 'Tags', value: ['a', 'b'], onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;
		await waitFor(() => expect(box.value).not.toBe(''));

		// A valid array binds. (`[[` escapes to a literal `[`; a lone `]` is
		// already literal.)
		await userEvent.clear(box);
		await userEvent.type(box, '[["x","y"]');
		await waitFor(() => expect(args.onchange).toHaveBeenLastCalledWith(['x', 'y']));

		// An item of the wrong type fails the declared item schema, with the
		// offending index in the message. The invalid typing binds nothing —
		// no onchange call lands after the clear's blank sentinel.
		const callsBeforeInvalid = (args.onchange as ReturnType<typeof fn>).mock.calls.length;
		await userEvent.clear(box);
		await userEvent.type(box, '[["x",42]');
		await waitFor(() =>
			expect(canvas.getByRole('alert')).toHaveTextContent(/tags\[1\] must be a string/)
		);
		expect((args.onchange as ReturnType<typeof fn>).mock.calls.length).toBe(callsBeforeInvalid + 1);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput
				field={args.field}
				label={args.label}
				value={args.value}
				onchange={args.onchange}
				id="s-array"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DictionaryEntrySchemaValidates"
	args={{ field: countersField, label: 'Counters', value: { small: 1 }, onchange: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;
		await waitFor(() => expect(box.value).not.toBe(''));

		// Valid entries against the declared integer schema bind.
		await userEvent.clear(box);
		await userEvent.type(box, '{{"small":1,"large":99}');
		await waitFor(() => expect(args.onchange).toHaveBeenLastCalledWith({ small: 1, large: 99 }));

		// A string entry fails the schema; the message names the entry key.
		// The invalid typing binds nothing — no onchange call lands after the
		// clear's blank sentinel.
		const callsBeforeInvalid = (args.onchange as ReturnType<typeof fn>).mock.calls.length;
		await userEvent.clear(box);
		await userEvent.type(box, '{{"small":"one"}');
		await waitFor(() =>
			expect(canvas.getByRole('alert')).toHaveTextContent(/counters\.small must be a number/)
		);
		expect((args.onchange as ReturnType<typeof fn>).mock.calls.length).toBe(callsBeforeInvalid + 1);
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput
				field={args.field}
				label={args.label}
				value={args.value}
				onchange={args.onchange}
				id="s-dict"
			/>
		</div>
	{/snippet}
</Story>

<!-- B-118: the host form gates the save on this widget's parse validity, so
	the flips must reach it — false while the text does not parse, true again
	on a fix, and blank text counts as valid (the cleared sentinel). -->
<Story
	name="ReportsValidityFlipsToTheHost"
	args={{
		field: addressField,
		label: 'Address',
		value: '',
		onchange: fn(),
		onvaliditychange: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const box = canvas.getByRole('textbox') as HTMLTextAreaElement;

		// Invalid typing flips the report to false…
		await userEvent.type(box, '{{"street": ');
		await waitFor(() => expect(args.onvaliditychange).toHaveBeenLastCalledWith(false));

		// …a fix flips it back…
		await userEvent.clear(box);
		await userEvent.type(box, '{{"street":"Elm St"}');
		await waitFor(() => expect(args.onvaliditychange).toHaveBeenLastCalledWith(true));

		// …and blank text is valid — the cleared sentinel binds, not a failure.
		await userEvent.clear(box);
		await waitFor(() => expect(args.onvaliditychange).toHaveBeenLastCalledWith(true));
		expect(args.onchange).toHaveBeenLastCalledWith('');
	}}
>
	{#snippet template(args)}
		<div style="min-height: 220px; padding: 24px">
			<StructuredInput
				field={args.field}
				label={args.label}
				value={args.value}
				onchange={args.onchange}
				onvaliditychange={args.onvaliditychange}
				id="s-validity"
			/>
		</div>
	{/snippet}
</Story>
