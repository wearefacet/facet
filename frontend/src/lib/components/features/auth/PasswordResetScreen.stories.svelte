<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import PasswordResetScreen from './PasswordResetScreen.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/PasswordResetScreen',
		component: PasswordResetScreen,
		tags: ['autodocs'],
		args: {
			onsubmit: fn(),
			onCancel: fn()
		}
	});
</script>

<Story name="Default">
	{#snippet template()}
		<PasswordResetScreen validityText="1 day" />
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		error: 'No account found for that identifier.',
		onsubmit: fn(),
		onCancel: fn()
	}}
>
	{#snippet template(args)}
		<PasswordResetScreen
			error={args.error}
			validityText="1 day"
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
		<PasswordResetScreen
			loading={args.loading}
			validityText="1 day"
			onsubmit={args.onsubmit}
			onCancel={args.onCancel}
		/>
	{/snippet}
</Story>

<Story
	name="Success"
	args={{
		success: true,
		submittedIdentifier: 'you@company.com',
		validityText: '1 day',
		onsubmit: fn(),
		onCancel: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The copy states the derived TTL, not a hardcoded duration (B-90).
		await expect(
			canvas.getByText(m.auth_reset_link_validity({ validity: args.validityText }))
		).toBeInTheDocument();
	}}
>
	{#snippet template(args)}
		<PasswordResetScreen
			success={args.success}
			submittedIdentifier={args.submittedIdentifier}
			validityText={args.validityText}
			onsubmit={args.onsubmit}
			onCancel={args.onCancel}
		/>
	{/snippet}
</Story>

<Story name="Branded">
	{#snippet template()}
		<PasswordResetScreen product="Acme Records" validityText="1 day" />
	{/snippet}
</Story>

<!-- B-292: the identifier input must write back into the component state —
	a one-way `value` prop left the typed text visible while `onsubmit` sent
	an empty identifier (the backend answered 200 without doing anything). -->
<Story
	name="SubmitsTypedIdentifier"
	args={{
		validityText: '1 day',
		onsubmit: fn(),
		onCancel: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// Query by role: the Field chrome appends a required marker to the
		// label's text content, so getByLabelText would not exact-match.
		const input = canvas.getByRole('textbox', { name: m.auth_login_identifier_label() });
		await userEvent.type(input, 'locked-out@corp.example');
		await userEvent.click(canvas.getByRole('button', { name: m.auth_reset_send_button() }));
		await expect(args.onsubmit).toHaveBeenCalledWith('locked-out@corp.example');
	}}
>
	{#snippet template(args)}
		<PasswordResetScreen validityText={args.validityText} onsubmit={args.onsubmit} />
	{/snippet}
</Story>
