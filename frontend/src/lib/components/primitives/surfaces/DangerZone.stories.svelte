<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DangerZone from './DangerZone.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/DangerZone',
		component: DangerZone,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';

	// Each play resets the counter first — stories on this page share it.
	let confirmations = 0;

	// The first pointer interaction can hit a transient `pointer-events: none`
	// left on <body> by a previously closed Bits UI modal (inherited by every
	// element) — retry inside waitFor per workflow.md → play conventions.
	async function typeWhenReady(input: HTMLElement, text: string): Promise<void> {
		await waitFor(async () => {
			await userEvent.type(input, text);
		});
	}
</script>

<Story
	name="TypeToConfirm"
	play={async ({ canvasElement }) => {
		confirmations = 0;
		const canvas = within(canvasElement);

		const input = canvas.getByPlaceholderText('Type crm.Widget to confirm');
		const button = canvas.getByRole('button', { name: 'Delete widget' });
		await expect(button).toBeDisabled();

		// A partial match must not arm the button.
		await typeWhenReady(input, 'crm.Widg');
		await expect(button).toBeDisabled();

		await typeWhenReady(input, 'et');
		await expect(button).toBeEnabled();
		await userEvent.click(button);
		await expect(confirmations).toBe(1);
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; max-width: 560px;">
			<DangerZone
				title="Danger zone"
				warning="Deleting the widget orphans every record and its children. This can't be undone."
				confirmTarget="crm.Widget"
				confirmLabel="Delete widget"
				onconfirm={() => confirmations++}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="BusyAndError"
	play={async ({ canvasElement }) => {
		confirmations = 0;
		const canvas = within(canvasElement);

		// While busy the button stays disabled even with a matching confirm text.
		const button = canvas.getByRole('button', { name: 'Deleting…' });
		await expect(button).toBeDisabled();
		await expect(canvas.getByRole('alert')).toHaveTextContent(
			'Network error — could not delete domain'
		);
		await expect(confirmations).toBe(0);
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; max-width: 560px;">
			<DangerZone
				title="Danger zone"
				warning="Deleting the widget orphans every record and its children. This can't be undone."
				confirmTarget="crm.Widget"
				confirmLabel="Delete widget"
				busy
				error="Network error — could not delete domain"
				onconfirm={() => confirmations++}
			/>
		</div>
	{/snippet}
</Story>
