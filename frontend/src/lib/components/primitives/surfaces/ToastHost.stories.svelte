<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import ToastHost from './ToastHost.svelte';
	import { dismissToast, getToasts, toast } from '$lib/toast.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/ToastHost',
		component: ToastHost,
		tags: ['autodocs']
	});

	// The host reads the global toast store — each play clears it first and
	// seeds its own toasts. The long durationMs keeps the auto-dismiss timer
	// out of the assertion path.
	const HOLD_MS = 60_000;

	function clearToasts(): void {
		for (const id of getToasts().map((t) => t.id)) dismissToast(id);
	}
</script>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		clearToasts();
		const canvas = within(canvasElement);
		// With no toasts the host renders nothing at all.
		await waitFor(() => expect(canvas.queryByRole('status')).toBeNull());
	}}
>
	{#snippet template()}
		<div class="toast-note">The host renders nothing while the toast list is empty.</div>
		<ToastHost />
	{/snippet}
</Story>

<Story
	name="Single"
	play={async ({ canvasElement }) => {
		clearToasts();
		toast({ message: 'Export finished.', durationMs: HOLD_MS });
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Export finished.')).toBeVisible());
	}}
/>

<Story
	name="WithAction"
	play={async ({ canvasElement }) => {
		clearToasts();
		toast({
			message: 'Export finished.',
			action: { label: 'Download', href: '/Api/export/142' },
			durationMs: HOLD_MS
		});
		const canvas = within(canvasElement);
		// The action renders as a plain link carrying its href.
		const link = await canvas.findByRole('link', { name: 'Download' });
		await expect(link).toHaveAttribute('href', '/Api/export/142');
	}}
/>

<Story
	name="ErrorVariant"
	play={async ({ canvasElement }) => {
		clearToasts();
		toast({
			message: 'Save failed. Fix the marked field and retry.',
			variant: 'error',
			durationMs: HOLD_MS
		});
		const canvas = within(canvasElement);
		await waitFor(() =>
			expect(canvas.getByText('Save failed. Fix the marked field and retry.')).toBeVisible()
		);
	}}
/>

<Story
	name="Dismiss"
	play={async ({ canvasElement }) => {
		clearToasts();
		toast({ message: 'Export finished.', durationMs: HOLD_MS });
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Export finished.')).toBeVisible());
		// The close button drops that one toast from the store.
		await userEvent.click(canvas.getByRole('button', { name: 'Close' }));
		await waitFor(() => expect(canvas.queryByText('Export finished.')).toBeNull());
		await expect(getToasts()).toHaveLength(0);
	}}
/>

<Story
	name="NeverBlocksBehindControls"
	play={async ({ canvasElement }) => {
		clearToasts();
		toast({ message: 'Export finished.', durationMs: HOLD_MS });
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Export finished.')).toBeVisible());
		// The stack box (which spans the gap between stacked toasts and its
		// own padding) never intercepts clicks — only each toast does.
		const stack = canvas.getByRole('status');
		await expect(getComputedStyle(stack).pointerEvents).toBe('none');
		const toastEl = canvas.getByText('Export finished.').parentElement as HTMLElement;
		await expect(getComputedStyle(toastEl).pointerEvents).toBe('auto');
		// The toast itself stays clickable and dismissible.
		await userEvent.click(canvas.getByRole('button', { name: 'Close' }));
		await waitFor(() => expect(getToasts()).toHaveLength(0));
	}}
/>

<style>
	.toast-note {
		margin: 24px;
		color: var(--text-3);
		font-size: 13px;
	}
</style>
