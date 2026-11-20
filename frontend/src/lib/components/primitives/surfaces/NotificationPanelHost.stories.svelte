<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn, waitFor } from 'storybook/test';
	import NotificationPanelHost from './NotificationPanelHost.svelte';
	import type { NotificationItem } from './NotificationPanel.svelte';
	import {
		toggleNotificationPanel,
		closeNotificationPanel,
		resetNotifications
	} from '$lib/notifications.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/NotificationPanelHost',
		component: NotificationPanelHost,
		tags: ['autodocs'],
		args: {
			onnavigate: fn(),
			ondownload: fn()
		}
	});

	const row: NotificationItem = {
		id: '01JHOST1',
		domain: 'hr',
		doc_type: 'LeaveRequest',
		doc_id: '01JDOC1',
		kind: 'leave_pending',
		icon: null,
		title: 'A leave request awaits your review',
		body: 'Amara Diallo requested 5 days of leave.',
		actions: [],
		read_at: null,
		actioned_at: null,
		created_at: new Date().toISOString()
	};

	// The export-job notification shape: the reserved `data.download` key
	// carries the file path the shell downloads on click.
	const downloadRow: NotificationItem = {
		id: '01JHOST2',
		domain: 'crm',
		doc_type: 'Company',
		doc_id: 'crm.Company',
		kind: 'document_export_completed',
		icon: null,
		title: 'Export ready',
		body: 'crm.Company.csv — 1234 rows',
		data: { download: '/Api/crm/Company/import_export/j1/download' },
		actions: [],
		read_at: null,
		actioned_at: null,
		created_at: new Date().toISOString()
	};

	// The host reads the module-level notification store, so the stories drive
	// the store through its public API and stub the network layer.
	let savedFetch: typeof fetch | undefined;

	function stubNotificationFetch(servedRow: NotificationItem = row): void {
		savedFetch = window.fetch;
		window.fetch = (async (input: RequestInfo | URL) => {
			const url = String(input);
			if (url.includes('/read')) {
				return new Response(JSON.stringify({ read_at: new Date().toISOString() }), {
					status: 200
				});
			}
			if (url.includes('unread_count')) {
				return new Response(JSON.stringify({ count: 1 }), { status: 200 });
			}
			if (url.includes('/Api/notifications')) {
				return new Response(
					JSON.stringify({ data: [servedRow], meta: { count: 1, more: false } }),
					{
						status: 200
					}
				);
			}
			return new Response('{}', { status: 404 });
		}) as typeof fetch;
	}

	function restoreFetch(): void {
		if (savedFetch) window.fetch = savedFetch;
		savedFetch = undefined;
	}

	/** Closes the panel and drops the store state after a store-driving story. */
	function cleanupStore(): void {
		closeNotificationPanel();
		resetNotifications();
	}
</script>

<Story
	name="ClosedByDefault"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button', { name: 'Mark all read' })).toBeNull();
	}}
/>

<Story
	name="OpensAndNavigates"
	play={async ({ canvasElement, args }) => {
		stubNotificationFetch();
		try {
			await toggleNotificationPanel();

			const canvas = within(canvasElement);
			await waitFor(() =>
				expect(canvas.getByText('A leave request awaits your review')).toBeVisible()
			);

			// Opening a row closes the panel, marks it read, then hands the
			// navigation to the host caller.
			await userEvent.click(
				canvas.getByRole('button', { name: 'Open A leave request awaits your review' })
			);
			await expect(args.onnavigate).toHaveBeenCalledWith(row);
			await waitFor(() =>
				expect(canvas.queryByRole('button', { name: 'Mark all read' })).toBeNull()
			);
		} finally {
			cleanupStore();
			restoreFetch();
		}
	}}
/>

<Story
	name="DownloadsFile"
	play={async ({ canvasElement, args }) => {
		stubNotificationFetch(downloadRow);
		try {
			await toggleNotificationPanel();

			const canvas = within(canvasElement);
			await waitFor(() => expect(canvas.getByText('Export ready')).toBeVisible());

			// Clicking the Download control runs the same flow as opening:
			// close, mark read, then hand the item to the host caller, which
			// triggers the browser download.
			await userEvent.click(canvas.getByRole('button', { name: 'Download' }));
			await expect(args.ondownload).toHaveBeenCalledOnce();
			await expect(args.ondownload).toHaveBeenCalledWith(downloadRow);
			await waitFor(() =>
				expect(canvas.queryByRole('button', { name: 'Mark all read' })).toBeNull()
			);
		} finally {
			cleanupStore();
			restoreFetch();
		}
	}}
/>
