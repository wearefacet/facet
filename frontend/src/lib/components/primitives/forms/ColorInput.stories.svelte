<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import ColorInput from './ColorInput.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/ColorInput',
		component: ColorInput,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	args={{ label: 'Doctype color', placeholder: '#5B8DEF' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Doctype color')).toBeVisible();
		await expect(canvas.getByPlaceholderText('#5B8DEF')).toBeVisible();
	}}
/>

<Story
	name="WithValue"
	args={{ label: 'Invoice tint', value: '#B05E2E' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByRole('textbox') as HTMLInputElement;
		await expect(input).toHaveValue('#B05E2E');
	}}
/>

<Story name="Required" args={{ label: 'Theme color', value: '#E4B61A', placeholder: '#RRGGBB' }} />

<Story
	name="InvalidHexFeedback"
	args={{ label: 'Accent', value: '#5B8DEF' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByRole('textbox') as HTMLInputElement;
		await expect(input).toHaveValue('#5B8DEF');

		// Focus opens the picker popover; an invalid entry stays uncommitted.
		await userEvent.click(input);
		await userEvent.clear(input);
		await userEvent.type(input, 'zzz');

		// Blur rejects the text: it snaps back to the last valid value and the
		// error is announced. Escape closes the popover; the message stays.
		await userEvent.tab();
		await userEvent.keyboard('{Escape}');
		await expect(input).toHaveValue('#5B8DEF');
		await expect(canvas.getByRole('alert')).toHaveTextContent(m.doc_color_hex_error());

		// Refocus clears the message; a valid entry commits and keeps it clear.
		await userEvent.click(input);
		await userEvent.clear(input);
		await userEvent.type(input, '3A6B9C');
		await userEvent.keyboard('{Escape}');
		await expect(input).toHaveValue('#3A6B9C');
		await expect(canvas.queryByRole('alert')).toBeNull();
	}}
/>

<Story
	name="Disabled"
	args={{ label: 'Locked', value: '#8A93A2', disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('textbox')).toBeDisabled();
	}}
/>
