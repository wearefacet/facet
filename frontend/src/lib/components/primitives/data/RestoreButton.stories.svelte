<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import RestoreButton from './RestoreButton.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataSource } from '$lib/datasource/MockDataSource.js';

	// Tombstoned doc — mock mutations run synchronously, so the delete lands
	// before any story mounts.
	const trashedDs = new MockDataSource('crm', 'Deal', [{ id: 'deal_del', name: 'Deleted deal' }]);
	void trashedDs.doc('deal_del').delete();

	// Live doc — restore must hit the backend's 409 no-op contract.
	const liveDs = new MockDataSource('crm', 'Deal', [{ id: 'deal_live', name: 'Live deal' }]);

	/** Unrestricted principal — the button renders enabled. */
	const adminManifest = { '*.*': ['*'] };
	/** Read-only principal — restore requires `update`, so the button is disabled. */
	const readOnlyManifest = { '*.*': ['read'] };

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/RestoreButton',
		component: RestoreButton,
		tags: ['autodocs'],
		args: {
			doctype: 'crm.Deal'
		}
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, userEvent } from 'storybook/test';
</script>

<!--
	Restore is gated by the existing `update` RBAC action (no dedicated
	`restore` permission) — the stories exercise both RBAC states and the
	backend's idempotency contract on an already-live document.
-->

<Story
	name="Allowed"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		const button = canvas.getByRole('button', { name: 'Restore' });
		await expect(button).toBeEnabled();

		await userEvent.click(button);
		await sleep(50);

		// The mock now lists the document as live again — the restore went
		// through and the row owner was free to refresh its listing.
		const live = await trashedDs.list();
		await expect(live.data.length).toBe(1);
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="padding: 24px">
				<RestoreButton doctype="crm.Deal" doc={trashedDs.doc('deal_del')} onRestored={() => {}} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Denied without update"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		const button = canvas.getByRole('button', { name: 'Restore' });
		await expect(button).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={readOnlyManifest}>
			<div style="padding: 24px">
				<RestoreButton doctype="crm.Deal" doc={trashedDs.doc('deal_del')} onRestored={() => {}} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Already restored returns 409"
	play={async ({ canvasElement }) => {
		await sleep(50);
		const canvas = within(canvasElement);
		const button = canvas.getByRole('button', { name: 'Restore' });
		await expect(button).toBeEnabled();

		await userEvent.click(button);
		await sleep(50);

		// The backend answers 409 for a live document — the button surfaces
		// the message AND refreshes the listing (a safe no-op, not an error).
		await expect(canvas.getByText('Document is not deleted')).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="padding: 24px">
				<RestoreButton doctype="crm.Deal" doc={liveDs.doc('deal_live')} onRestored={() => {}} />
			</div>
		</CanFixture>
	{/snippet}
</Story>
