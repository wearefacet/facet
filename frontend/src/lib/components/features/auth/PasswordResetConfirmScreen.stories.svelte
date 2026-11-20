<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import PasswordResetConfirmScreen from './PasswordResetConfirmScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/PasswordResetConfirmScreen',
		component: PasswordResetConfirmScreen,
		tags: ['autodocs'],
		args: {
			onsubmit: fn(),
			onCancel: fn()
		}
	});
</script>

<Story name="Default">
	{#snippet template()}
		<PasswordResetConfirmScreen />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'This reset link is invalid or has expired.',
		onsubmit: fn(),
		onCancel: fn()
	}}
>
	{#snippet template(args)}
		<PasswordResetConfirmScreen
			error={args.error}
			onsubmit={args.onsubmit}
			onCancel={args.onCancel}
		/>
	{/snippet}
</Story>

<Story
	name="Loading"
	args={{
		loading: true,
		onsubmit: fn(),
		onCancel: fn()
	}}
>
	{#snippet template(args)}
		<PasswordResetConfirmScreen
			loading={args.loading}
			onsubmit={args.onsubmit}
			onCancel={args.onCancel}
		/>
	{/snippet}
</Story>

<Story
	name="SubmitsNewPassword"
	args={{ onsubmit: fn(), onCancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'correct horse battery');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'correct horse battery');
		await userEvent.click(canvas.getByRole('button', { name: /set password/i }));
		await expect(args.onsubmit).toHaveBeenCalledWith('correct horse battery');
	}}
>
	{#snippet template(args)}
		<PasswordResetConfirmScreen onsubmit={args.onsubmit} onCancel={args.onCancel} />
	{/snippet}
</Story>

<Story
	name="RejectsMismatchedConfirm"
	args={{ onsubmit: fn(), onCancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'correct horse battery');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'wrong confirmation');
		await userEvent.click(canvas.getByRole('button', { name: /set password/i }));
		await expect(canvas.getByRole('alert')).toHaveTextContent(/do not match/i);
		await expect(args.onsubmit).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<PasswordResetConfirmScreen onsubmit={args.onsubmit} onCancel={args.onCancel} />
	{/snippet}
</Story>

<Story
	name="RejectsShortPassword"
	args={{ onsubmit: fn(), onCancel: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText(/^new password/i), 'short');
		await userEvent.type(canvas.getByLabelText(/confirm new password/i), 'short');
		await userEvent.click(canvas.getByRole('button', { name: /set password/i }));
		await expect(canvas.getByRole('alert')).toHaveTextContent(/at least 8 characters/i);
		await expect(args.onsubmit).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<PasswordResetConfirmScreen onsubmit={args.onsubmit} onCancel={args.onCancel} />
	{/snippet}
</Story>
