<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import TotpRegistrationScreen from './TotpRegistrationScreen.svelte';

	/** Minimal delay helper — `storybook/test` in this version has no `sleep`. */
	function sleep(ms: number): Promise<void> {
		return new Promise((r) => setTimeout(r, ms));
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Auth/TotpRegistrationScreen',
		component: TotpRegistrationScreen,
		tags: ['autodocs'],
		args: {
			secret: 'JBSWY3DPEHPK3PXP',
			onverify: fn(),
			onCancel: fn(),
			onDone: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story name="Default">
	{#snippet template()}
		<TotpRegistrationScreen secret="JBSWY3DPEHPK3PXP" />
	{/snippet}
</Story>

<Story
	name="Verifying"
	args={{
		secret: 'JBSWY3DPEHPK3PXP',
		status: 'verifying',
		onverify: fn(),
		onCancel: fn(),
		onDone: fn()
	}}
>
	{#snippet template(args)}
		<TotpRegistrationScreen
			secret={args.secret}
			status={args.status}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onDone={args.onDone}
		/>
	{/snippet}
</Story>

<Story
	name="WithError"
	args={{
		secret: 'JBSWY3DPEHPK3PXP',
		error: "That code didn't match. Try again.",
		onverify: fn(),
		onCancel: fn(),
		onDone: fn()
	}}
>
	{#snippet template(args)}
		<TotpRegistrationScreen
			secret={args.secret}
			error={args.error}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onDone={args.onDone}
		/>
	{/snippet}
</Story>

<Story
	name="Verified"
	args={{
		secret: 'JBSWY3DPEHPK3PXP',
		status: 'verified',
		backupCodes: [
			'8a1f-2034',
			'9cb2-7d10',
			'4e7a-1b9c',
			'2f08-5d3e',
			'6a51-9c7b',
			'0b3d-8e2f',
			'7c90-1a45',
			'3d6e-0f12'
		],
		onverify: fn(),
		onCancel: fn(),
		onDone: fn()
	}}
	play={async ({ canvasElement, args }) => {
		await sleep(100);
		const canvas = within(canvasElement);

		// The minted codes render in the grid — no empty state.
		const grid = canvas.getByRole('list', { name: 'Backup codes' });
		await expect(within(grid).getAllByRole('listitem')).toHaveLength(8);

		// Confirming the save leaves through onDone, not onCancel.
		await userEvent.click(canvas.getByRole('button', { name: "I've saved my backup codes" }));
		await expect(args.onDone).toHaveBeenCalledOnce();
		await expect(args.onCancel).not.toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<TotpRegistrationScreen
			secret={args.secret}
			status={args.status}
			backupCodes={args.backupCodes}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onDone={args.onDone}
		/>
	{/snippet}
</Story>

<Story name="EightDigits" args={{ secret: 'JBSWY3DPEHPK3PXP', length: 8 }}>
	{#snippet template(args)}
		<TotpRegistrationScreen secret={args.secret} length={args.length} />
	{/snippet}
</Story>

<Story name="Branded">
	{#snippet template()}
		<TotpRegistrationScreen
			secret="JBSWY3DPEHPK3PXP"
			issuer="Acme Records"
			account="ada@acme.dev"
			product="Acme Records"
		/>
	{/snippet}
</Story>

<Story
	name="ServerOtpauthUri"
	args={{
		secret: 'JBSWY3DPEHPK3PXP',
		otpauthUri:
			'otpauth://totp/Facet%3Aada%40acme.dev?secret=JBSWY3DPEHPK3PXP&issuer=Facet&algorithm=SHA1&digits=6&period=30',
		onverify: fn(),
		onCancel: fn(),
		onDone: fn()
	}}
	play={async ({ canvasElement, args: _args }) => {
		const canvas = within(canvasElement);
		// The QR renders from the server-built URI, and the account label is
		// read back out of that URI (not from the default `account` prop).
		await expect(canvasElement.querySelector('.qr-frame svg')).toBeTruthy();
		await expect(canvas.getByText('ada@acme.dev')).toBeTruthy();
	}}
>
	{#snippet template(args)}
		<TotpRegistrationScreen
			secret={args.secret}
			otpauthUri={args.otpauthUri}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onDone={args.onDone}
		/>
	{/snippet}
</Story>

<Story
	name="Dismissible"
	args={{
		secret: 'JBSWY3DPEHPK3PXP',
		cancelLabel: 'Skip for now',
		cancelArrow: 'right',
		onverify: fn(),
		onCancel: fn(),
		onDone: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const dismiss = canvas.getByRole('button', { name: 'Skip for now' });
		// The skip arrow trails the label — a forward affordance, not a back one.
		await expect(dismiss.lastElementChild?.tagName.toLowerCase()).toBe('svg');
		await userEvent.click(dismiss);
		await expect(args.onCancel).toHaveBeenCalled();
	}}
>
	{#snippet template(args)}
		<TotpRegistrationScreen
			secret={args.secret}
			cancelLabel={args.cancelLabel}
			cancelArrow={args.cancelArrow}
			onverify={args.onverify}
			onCancel={args.onCancel}
			onDone={args.onDone}
		/>
	{/snippet}
</Story>
