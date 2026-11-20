<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import BackupCodeScreen from './BackupCodeScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/BackupCodeScreen',
		component: BackupCodeScreen,
		tags: ['autodocs'],
		args: {
			onverify: fn(),
			onBack: fn()
		}
	});
</script>

<Story name="Default">
	{#snippet template(args)}
		<BackupCodeScreen onverify={args.onverify} onBack={args.onBack} />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'Invalid or already-used code. 4 attempts remaining.',
		onverify: fn(),
		onBack: fn()
	}}
>
	{#snippet template(args)}
		<BackupCodeScreen error={args.error} onverify={args.onverify} onBack={args.onBack} />
	{/snippet}
</Story>

<Story name="Loading" args={{ loading: true, onverify: fn(), onBack: fn() }}>
	{#snippet template(args)}
		<BackupCodeScreen loading={args.loading} onverify={args.onverify} onBack={args.onBack} />
	{/snippet}
</Story>

<Story
	name="SubmitsTrimmedCode"
	args={{ onverify: fn(), onBack: fn() }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);

		// The submit is dead until a code is typed.
		const verify = canvas.getByRole('button', { name: 'Verify' });
		await expect(verify).toBeDisabled();

		await userEvent.type(canvas.getByLabelText(/Backup code/), '  8a1f-2034 ');
		await userEvent.click(verify);

		// The code reaches the handler trimmed; the back link is untouched.
		await expect(args.onverify).toHaveBeenCalledWith('8a1f-2034');
		await expect(args.onBack).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<BackupCodeScreen onverify={args.onverify} onBack={args.onBack} />
	{/snippet}
</Story>
