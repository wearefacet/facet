<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ConfirmDialog from './ConfirmDialog.svelte';
	import { confirm } from '$lib/confirm.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/ConfirmDialog',
		component: ConfirmDialog,
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';

	// One shared answer label; each play resets it before opening its prompt.
	let answer = $state('');

	/** Open the confirm; return the raw promise and mirror the answer to `answer`. */
	function ask(options: Parameters<typeof confirm>[0]): Promise<boolean> {
		answer = '';
		const promise = confirm(options);
		void promise.then((ok) => {
			answer = ok ? 'Answer: yes' : 'Answer: no';
		});
		return promise;
	}
</script>

<!--
	The dialog portals into `document.body`, so the play functions query
	`within(document.body)`. The plays call `confirm()` directly (the `Ask`
	button exists for interactive preview only) — canvas clicks would fail
	here because an open dialog sets `pointer-events: none` on `<body>`.
-->

<Story
	name="ConfirmResolvesTrue"
	play={async () => {
		const body = within(document.body);
		answer = '';

		const promise = ask({
			title: 'Delete the “Viewer” role?',
			message: 'This cannot be undone.',
			confirmLabel: 'Delete role',
			variant: 'danger'
		});
		await waitFor(() => expect(body.getByText('Delete the “Viewer” role?')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Delete role' }));
		await expect(promise).resolves.toBe(true);
		// The dialog unmounts once the request is settled.
		await waitFor(() => {
			expect(body.queryByText('Delete the “Viewer” role?')).toBeNull();
		});
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; min-height: 200px;">
			<button
				onclick={() =>
					ask({
						title: 'Delete the “Viewer” role?',
						message: 'This cannot be undone.',
						confirmLabel: 'Delete role',
						variant: 'danger'
					})}
			>
				Ask
			</button>
			<span>{answer}</span>
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

<Story
	name="CancelResolvesFalse"
	play={async () => {
		const body = within(document.body);
		answer = '';

		const promise = ask({ title: 'Discard unsaved changes?', message: 'Your edits are lost.' });
		await waitFor(() => expect(body.getByText('Discard unsaved changes?')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await expect(promise).resolves.toBe(false);
		await waitFor(() => {
			expect(body.queryByText('Discard unsaved changes?')).toBeNull();
		});
	}}
>
	{#snippet template(_args)}
		<div style="padding: 24px; min-height: 200px;">
			<button
				onclick={() => ask({ title: 'Discard unsaved changes?', message: 'Your edits are lost.' })}
			>
				Ask
			</button>
			<span>{answer}</span>
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>
