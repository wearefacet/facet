<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import OtpInput from './OtpInput.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/OtpInput',
		component: OtpInput,
		tags: ['autodocs']
	});
</script>

<Story
	name="Empty"
	args={{ code: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const boxes = canvas.getAllByRole('textbox');
		await expect(boxes.length).toBe(6);
		// First box carries the one-time-code autocomplete hint.
		await expect(boxes[0]).toHaveAttribute('autocomplete', 'one-time-code');
		await expect(boxes[1]).toHaveAttribute('autocomplete', 'off');
	}}
/>

<Story
	name="TypingAdvancesFocus"
	args={{ code: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const boxes = canvas.getAllByRole('textbox');
		await userEvent.type(boxes[0], '4');
		// The typed digit lands in the shared code and focus auto-advances.
		await expect(boxes[1]).toHaveFocus();
		await expect(boxes[0]).toHaveValue('4');
	}}
/>

<Story
	name="PartFilled"
	args={{ code: '12' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const boxes = canvas.getAllByRole('textbox');
		await expect(boxes[0]).toHaveValue('1');
		await expect(boxes[1]).toHaveValue('2');
		await expect(boxes[2]).toHaveValue('');
	}}
/>

<Story
	name="EightDigits"
	args={{ code: '', length: 8 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getAllByRole('textbox').length).toBe(8);
	}}
/>

<Story
	name="ArrowNavigation"
	args={{ code: '12' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const boxes = canvas.getAllByRole('textbox');
		// ArrowRight from box 0 moves focus to box 1.
		await userEvent.click(boxes[0]);
		await userEvent.keyboard('{ArrowRight}');
		await expect(boxes[1]).toHaveFocus();
		// ArrowLeft moves back.
		await userEvent.keyboard('{ArrowLeft}');
		await expect(boxes[0]).toHaveFocus();
	}}
/>

<Story
	name="BackspaceOnEmptyReturns"
	args={{ code: '1' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const boxes = canvas.getAllByRole('textbox');
		// Focus box 1 (empty) and press Backspace: the digit in box 0 clears
		// and focus returns to box 0.
		await userEvent.click(boxes[1]);
		await userEvent.keyboard('{Backspace}');
		await expect(boxes[0]).toHaveFocus();
		await expect(boxes[0]).toHaveValue('');
	}}
/>
