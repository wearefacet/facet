<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import { ShieldCheck, KeyRound, ArrowLeft } from '@lucide/svelte';
	import AuthShell from './AuthShell.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/AuthShell',
		component: AuthShell,
		tags: ['autodocs']
	});
</script>

<!-- The shell hosts each auth screen's chrome; the stories assert the
     standard header, error banner, and footer-link chrome. -->

<Story
	name="Default"
	args={{ title: 'Set a new password', sub: 'Choose a new one to continue.' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The brand mark + title + sub form the standard header.
		await expect(canvas.getByText('Set a new password')).toBeVisible();
		await expect(canvas.getByText('Choose a new one to continue.')).toBeVisible();
	}}
/>

<Story
	name="WithIconAndError"
	args={{
		title: 'Two-factor authentication',
		sub: 'Enter the 6-digit code from your authenticator app.',
		error: 'Incorrect code. Please try again.'
	}}
>
	{#snippet template(args)}
		<AuthShell title={args.title} sub={args.sub} error={args.error}>
			{#snippet icon()}
				<ShieldCheck size={22} />
			{/snippet}
		</AuthShell>
	{/snippet}
</Story>

<Story
	name="WithWarnIconTint"
	args={{
		title: 'Set a new password',
		sub: 'Your account uses a temporary password.',
		iconTint: 'warn'
	}}
>
	{#snippet template(args)}
		<AuthShell title={args.title} sub={args.sub} iconTint={args.iconTint as 'accent' | 'warn'}>
			{#snippet icon()}
				<KeyRound size={22} />
			{/snippet}
		</AuthShell>
	{/snippet}
</Story>

<Story
	name="WithFooterLinks"
	args={{ title: 'Reset your password', sub: "We'll send a reset link." }}
>
	{#snippet template(args)}
		<AuthShell title={args.title} sub={args.sub}>
			{#snippet footer()}
				<button class="link-btn" type="button">
					<ArrowLeft size={13} />
					Back to sign in
				</button>
			{/snippet}
		</AuthShell>
	{/snippet}
</Story>

<Story
	name="CustomWidth"
	args={{
		title: 'Authorize app',
		sub: 'The app wants to access your account.',
		maxWidth: 520,
		gap: 18,
		subMaxWidth: 360
	}}
/>
