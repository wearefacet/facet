<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import StringListEditor from './StringListEditor.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/StringListEditor',
		component: StringListEditor,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	// The editor mutates `values` in place (push / splice / pop), so the
	// interactive stories pass a $state proxy — a plain array would take the
	// mutation but the chips would not re-render. Each play resets its array
	// first, so story order cannot skew an assertion.
	const seedUris = ['https://app.example.com/callback', 'https://alt.example.com/callback'];

	let defaultValues = $state<string[]>([...seedUris]);
	let removeValues = $state<string[]>([...seedUris]);
	let backspaceValues = $state<string[]>(['first-row', 'second-row']);
	let validatorValues = $state<string[]>([]);
</script>

<Story
	name="Default"
	args={{ label: 'Redirect URIs', helper: 'Press Enter or comma to add.' }}
	play={async ({ canvasElement }) => {
		defaultValues = [...seedUris];
		const canvas = within(canvasElement);
		await expect(canvas.getByText('https://app.example.com/callback')).toBeVisible();
		await expect(canvas.getByText('https://alt.example.com/callback')).toBeVisible();
		// Typing a value and pressing Enter appends one chip and clears the input.
		const input = canvas.getByRole('textbox', { name: 'Redirect URIs' });
		await userEvent.type(input, 'https://new.example.com/callback{Enter}');
		await waitFor(() => expect(canvas.getByText('https://new.example.com/callback')).toBeVisible());
		await waitFor(() => expect(input).toHaveValue(''));
		await expect(defaultValues).toEqual([...seedUris, 'https://new.example.com/callback']);
	}}
>
	{#snippet template(args)}
		<div class="sle-frame">
			<StringListEditor label={args.label} helper={args.helper} values={defaultValues} />
		</div>
	{/snippet}
</Story>

<Story
	name="RemoveChip"
	args={{ label: 'Redirect URIs' }}
	play={async ({ canvasElement }) => {
		removeValues = [...seedUris];
		const canvas = within(canvasElement);
		// Each chip carries a labelled remove button; clicking one splices
		// exactly that entry out of the bound array.
		await userEvent.click(
			canvas.getByRole('button', { name: 'Remove https://app.example.com/callback' })
		);
		await waitFor(() => expect(canvas.queryByText('https://app.example.com/callback')).toBeNull());
		await expect(canvas.getByText('https://alt.example.com/callback')).toBeVisible();
		await expect(removeValues).toEqual(['https://alt.example.com/callback']);
	}}
>
	{#snippet template(args)}
		<div class="sle-frame">
			<StringListEditor label={args.label} values={removeValues} />
		</div>
	{/snippet}
</Story>

<Story
	name="BackspaceRemovesLast"
	args={{ label: 'Tag list' }}
	play={async ({ canvasElement }) => {
		backspaceValues = ['first-row', 'second-row'];
		const canvas = within(canvasElement);
		// Backspace on an empty input removes the last chip.
		const input = canvas.getByRole('textbox', { name: 'Tag list' });
		await userEvent.type(input, '{Backspace}');
		await waitFor(() => expect(canvas.queryByText('second-row')).toBeNull());
		await expect(canvas.getByText('first-row')).toBeVisible();
		await expect(backspaceValues).toEqual(['first-row']);
	}}
>
	{#snippet template(args)}
		<div class="sle-frame">
			<StringListEditor label={args.label} values={backspaceValues} />
		</div>
	{/snippet}
</Story>

<Story
	name="DuplicateRejected"
	args={{ label: 'Redirect URIs', values: ['https://app.example.com/callback'] }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Committing a value that is already in the list shows the duplicate
		// message and keeps the draft in the input.
		const input = canvas.getByRole('textbox', { name: 'Redirect URIs' });
		await userEvent.type(input, 'https://app.example.com/callback{Enter}');
		const alert = await canvas.findByRole('alert');
		await expect(alert).toHaveTextContent('Already in the list.');
		await expect(input).toHaveValue('https://app.example.com/callback');
	}}
/>

<Story
	name="ValidatorRejected"
	args={{ label: 'Callback URIs' }}
	play={async ({ canvasElement }) => {
		validatorValues = [];
		const canvas = within(canvasElement);
		const input = canvas.getByRole('textbox', { name: 'Callback URIs' });
		// The validator's message shows and the rejected value stays in the draft.
		await userEvent.type(input, 'bad value{Enter}');
		const alert = await canvas.findByRole('alert');
		await expect(alert).toHaveTextContent('No spaces allowed');
		await expect(input).toHaveValue('bad value');
		await expect(validatorValues).toEqual([]);
		// A corrected value commits and clears the error. The draft still
		// holds the rejected text, so clear it before typing the fix — the
		// corrected value must pass the validator (no spaces).
		await userEvent.clear(input);
		await userEvent.type(input, 'good-callback{Enter}');
		await waitFor(() => expect(canvas.getByText('good-callback')).toBeVisible());
		await waitFor(() => expect(canvas.queryByRole('alert')).toBeNull());
		await expect(validatorValues).toEqual(['good-callback']);
	}}
>
	{#snippet template(args)}
		<div class="sle-frame">
			<StringListEditor
				label={args.label}
				values={validatorValues}
				validator={(v) => (v.includes(' ') ? 'No spaces allowed' : null)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Disabled"
	args={{ label: 'Redirect URIs', values: ['https://locked.example.com/callback'], disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Disabled state keeps the chips, drops the remove buttons, and locks
		// the input.
		await expect(canvas.getByText('https://locked.example.com/callback')).toBeVisible();
		await expect(canvas.getByRole('textbox', { name: 'Redirect URIs' })).toBeDisabled();
		await expect(canvas.queryByRole('button', { name: /Remove/ })).toBeNull();
	}}
/>

<style>
	.sle-frame {
		max-width: 480px;
		margin: 24px auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
	}
</style>
