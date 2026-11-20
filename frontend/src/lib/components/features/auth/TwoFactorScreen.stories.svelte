<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import TwoFactorScreen from './TwoFactorScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/TwoFactorScreen',
		component: TwoFactorScreen,
		tags: ['autodocs'],
		args: {
			onverify: fn(),
			onCancel: fn(),
			onUseBackupCode: fn()
		}
	});
</script>

<Story name="Default">
	{#snippet template()}
		<TwoFactorScreen />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'Incorrect code. Please try again.',
		onverify: fn(),
		onCancel: fn(),
		onUseBackupCode: fn()
	}}
>
	{#snippet template(args)}
		<TwoFactorScreen
			error={args.error}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onUseBackupCode={args.onUseBackupCode}
		/>
	{/snippet}
</Story>

<Story
	name="Loading"
	args={{
		loading: true,
		onverify: fn(),
		onCancel: fn(),
		onUseBackupCode: fn()
	}}
>
	{#snippet template(args)}
		<TwoFactorScreen
			loading={args.loading}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onUseBackupCode={args.onUseBackupCode}
		/>
	{/snippet}
</Story>

<Story name="EightDigits" args={{ length: 8 }}>
	{#snippet template(args)}
		<TwoFactorScreen length={args.length} />
	{/snippet}
</Story>
