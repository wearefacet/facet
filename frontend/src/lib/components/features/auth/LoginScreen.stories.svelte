<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, within } from 'storybook/test';
	import LoginScreen from './LoginScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/LoginScreen',
		component: LoginScreen,
		tags: ['autodocs'],
		args: {
			onsubmit: fn()
		}
	});

	const DEMO_PROVIDERS = [
		{ name: 'acme', label: 'Acme SSO' },
		{ name: 'globex', label: 'Globex ID' }
	];
</script>

<Story name="Default">
	{#snippet template()}
		<LoginScreen />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'Invalid identifier or password.',
		onsubmit: fn()
	}}
>
	{#snippet template(args)}
		<LoginScreen error={args.error} onsubmit={args.onsubmit} />
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
		<LoginScreen loading={args.loading} onsubmit={args.onsubmit} />
	{/snippet}
</Story>

<Story name="WithProviders" args={{ providers: DEMO_PROVIDERS }}>
	{#snippet template(args)}
		<LoginScreen providers={args.providers} />
	{/snippet}
</Story>

<!-- One button per provider, each linking to the backend's flow start. -->
<Story
	name="ProvidersRenderOneButtonEach"
	args={{ providers: DEMO_PROVIDERS }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const links = canvas.getAllByRole('link');
		await expect(links).toHaveLength(2);
		await expect(links[0]).toHaveAttribute('href', '/auth/oidc/acme');
		await expect(links[1]).toHaveAttribute('href', '/auth/oidc/globex');
		await expect(links[0]).toHaveTextContent('Continue with Acme SSO');
		await expect(links[1]).toHaveTextContent('Continue with Globex ID');
	}}
/>

<Story name="Branded">
	{#snippet template()}
		<LoginScreen product="Acme Records" tagline="secure document vault" />
	{/snippet}
</Story>
