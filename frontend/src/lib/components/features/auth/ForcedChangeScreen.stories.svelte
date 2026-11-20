<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import ForcedChangeScreen from './ForcedChangeScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/ForcedChangeScreen',
		component: ForcedChangeScreen,
		tags: ['autodocs'],
		args: {
			onsubmit: fn()
		}
	});
</script>

<Story name="Default">
	{#snippet template()}
		<ForcedChangeScreen />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'Current password is incorrect',
		onsubmit: fn()
	}}
>
	{#snippet template(args)}
		<ForcedChangeScreen error={args.error} onsubmit={args.onsubmit} />
	{/snippet}
</Story>

<Story
	name="Loading"
	args={{
		loading: true,
		onsubmit: fn()
	}}
>
	{#snippet template(args)}
		<ForcedChangeScreen loading={args.loading} onsubmit={args.onsubmit} />
	{/snippet}
</Story>

<Story
	name="SubmitsValidPasswords"
	args={{ onsubmit: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/current password/i), 'temp-K7M4-9XQ2');
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'correct horse battery');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'correct horse battery');
		await userEvent.click(canvas.getByRole('button', { name: /save password/i }));
		await expect(args.onsubmit).toHaveBeenCalledWith('temp-K7M4-9XQ2', 'correct horse battery');
	}}
>
	{#snippet template(args)}
		<ForcedChangeScreen onsubmit={args.onsubmit} />
	{/snippet}
</Story>

<Story
	name="RejectsMismatchedConfirm"
	args={{ onsubmit: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/current password/i), 'temp-K7M4-9XQ2');
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'correct horse battery');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'wrong confirmation');
		await userEvent.click(canvas.getByRole('button', { name: /save password/i }));
		await expect(canvas.getByRole('alert')).toHaveTextContent(/do not match/i);
		await expect(args.onsubmit).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<ForcedChangeScreen onsubmit={args.onsubmit} />
	{/snippet}
</Story>

<Story
	name="RejectsShortPassword"
	args={{ onsubmit: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/current password/i), 'temp-K7M4-9XQ2');
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'short');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'short');
		await userEvent.click(canvas.getByRole('button', { name: /save password/i }));
		await expect(canvas.getByRole('alert')).toHaveTextContent(/at least 8 characters/i);
		await expect(args.onsubmit).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<ForcedChangeScreen onsubmit={args.onsubmit} />
	{/snippet}
</Story>
