<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ExportMenu from './ExportMenu.svelte';
	import ToastHost from '$lib/components/primitives/surfaces/ToastHost.svelte';
	import type { FetchImpl, ViewExportItem } from '$lib/importExport/importExportClient.js';

	const { Story } = defineMeta({
		title: 'Components/Features/ImportExport/ExportMenu',
		component: ExportMenu
	});

	/** Builds a fetch stub: the enqueue 202s, the status is already succeeded. */
	function stubFetch(jobId = 'jx'): FetchImpl {
		return (async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url.includes('/export')) {
				return new Response(
					JSON.stringify({ job_id: jobId, status_url: `/Api/crm/Company/import_export/${jobId}` }),
					{ status: 202 }
				);
			}
			if (url.includes('/import_export/')) {
				return new Response(
					JSON.stringify({
						id: jobId,
						status: 'succeeded',
						result: { artifact_id: 'a1', row_count: 7, format: 'csv' }
					}),
					{ status: 200 }
				);
			}
			return new Response(JSON.stringify({ error: 'unexpected route' }), { status: 404 });
		}) as FetchImpl;
	}

	/** A fetch stub whose job never leaves running — playback of the long-job case. */
	function pendingFetch(jobId = 'jy'): FetchImpl {
		return (async (input: string | URL | Request) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url.includes('/export')) {
				return new Response(
					JSON.stringify({ job_id: jobId, status_url: `/Api/crm/Company/import_export/${jobId}` }),
					{ status: 202 }
				);
			}
			return new Response(JSON.stringify({ id: jobId, status: 'running', result: null }), {
				status: 200
			});
		}) as FetchImpl;
	}

	/** A fetch stub that records the view-export enqueue body for the play to assert. */
	function capturingFetch(captured: { body: string | null }, jobId = 'jz'): FetchImpl {
		return (async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url.includes('/export_view')) {
				captured.body = typeof init?.body === 'string' ? init.body : null;
				return new Response(
					JSON.stringify({ job_id: jobId, status_url: `/Api/crm/Company/import_export/${jobId}` }),
					{ status: 202 }
				);
			}
			if (url.includes('/import_export/')) {
				return new Response(
					JSON.stringify({
						id: jobId,
						status: 'succeeded',
						result: { artifact_id: 'a2', row_count: 3, format: 'csv' }
					}),
					{ status: 200 }
				);
			}
			return new Response(JSON.stringify({ error: 'unexpected route' }), { status: 404 });
		}) as FetchImpl;
	}

	const tableView: ViewExportItem = {
		columns: ['name', 'amount'],
		filters: { status__eq: 'open' },
		sort: ['-created_at']
	};
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import { getToasts, dismissToast } from '$lib/toast.svelte';

	// The first pointer interaction can hit the story preparation state
	// (`pointer-events: none` on body) — retry inside waitFor per the
	// testing strategy's Bits UI modal note.
	async function clickWhenReady(element: HTMLElement) {
		await waitFor(async () => {
			await userEvent.click(element);
		});
	}

	// The view-export story's captured enqueue body — filled by the stub's
	// fetch during the play, asserted at the end.
	const captured: { body: string | null } = { body: null };
</script>

<!--
	Portalled dropdown content is avoided in play functions per the testing
	strategy (flaky across iframes) — these stories drive the menu open and
	assert the item, then let the enqueue + toast flow run. The story mounts
	`ToastHost` itself: the toasts render in the root layout in the app, and
	the story plays the role of the layout. Toast clean-up at the end of
	every play keeps later stories clean.
-->

<Story
	name="CsvExportCompletesWithADownloadToast"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		// Open the menu (portalled content, one click, asserted quickly).
		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('Export as CSV')).toBeVisible());

		await userEvent.click(body.getByText('Export as CSV'));

		// The start toast, then the completion toast with the download link.
		await waitFor(() => expect(body.getByText('Export ready.')).toBeVisible());
		const link = body.getByRole('link', { name: 'Download' });
		await expect(link).toHaveAttribute('href', '/Api/crm/Company/import_export/jx/download');

		// Clean the shared toast stack for later stories.
		for (const t of [...getToasts()]) dismissToast(t.id);
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu domain={args.domain} doctype={args.doctype} fetchImpl={stubFetch()} />
			<ToastHost />
		</div>
	{/snippet}
</Story>

<Story
	name="PendingJobKeepsTheMenuQuiet"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('Export as JSON')).toBeVisible());

		await userEvent.click(body.getByText('Export as JSON'));

		// The start toast lands; the poll keeps running against the stub's
		// always-running job, so no completion toast ever appears.
		await waitFor(() =>
			expect(body.getByText('Export started — the file link lands here when ready.')).toBeVisible()
		);
		await new Promise((r) => setTimeout(r, 250));
		await expect(body.queryByText('Export ready.')).toBeNull();

		for (const t of [...getToasts()]) dismissToast(t.id);
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu domain={args.domain} doctype={args.doctype} fetchImpl={pendingFetch()} />
			<ToastHost />
		</div>
	{/snippet}
</Story>

<!--
	The view export: the third menu item renders with a view state, posts the
	captured body to `/export_view`, and the completion toast carries the same
	download link the flat exports use.
-->

<Story
	name="ViewExportCompletesWithADownloadToast"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('CSV — current view')).toBeVisible());

		await userEvent.click(body.getByText('CSV — current view'));

		await waitFor(() => expect(body.getByText('View export ready.')).toBeVisible());
		const link = body.getByRole('link', { name: 'Download' });
		await expect(link).toHaveAttribute('href', '/Api/crm/Company/import_export/jz/download');

		// The enqueue body carried the view state plus the resolved timezone —
		// the settings store is unloaded in stories, so the browser zone.
		expect(captured.body).not.toBeNull();
		expect(JSON.parse(captured.body as string)).toEqual({
			columns: ['name', 'amount'],
			filters: { status__eq: 'open' },
			sort: ['-created_at'],
			timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
		});

		for (const t of [...getToasts()]) dismissToast(t.id);
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu
				domain={args.domain}
				doctype={args.doctype}
				view={tableView}
				fetchImpl={capturingFetch(captured)}
			/>
			<ToastHost />
		</div>
	{/snippet}
</Story>

<!-- Without a view state (trash mode passes `null`) the item never renders. -->

<Story
	name="ViewExportHiddenWithoutViewState"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('Export as CSV')).toBeVisible());
		await expect(body.queryByText('CSV — current view')).toBeNull();

		// Close the menu before the story ends — an open Bits UI menu's
		// unmount cleanup leaves `pointer-events: none` on body and trips the
		// next story's first pointer interaction (see the testing strategy).
		await userEvent.keyboard('{Escape}');
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu domain={args.domain} doctype={args.doctype} view={null} fetchImpl={stubFetch()} />
		</div>
	{/snippet}
</Story>

<!-- A view state whose data columns are all filtered out hides the item too. -->

<Story
	name="ViewExportHiddenWithoutColumns"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('Export as CSV')).toBeVisible());
		await expect(body.queryByText('CSV — current view')).toBeNull();

		await userEvent.keyboard('{Escape}');
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu
				domain={args.domain}
				doctype={args.doctype}
				view={{ columns: [], filters: {}, sort: [] }}
				fetchImpl={stubFetch()}
			/>
		</div>
	{/snippet}
</Story>

<!--
	The running guard: a pending job keeps the menu items disabled — the
	play starts a flat export against the always-running stub, reopens the
	menu, and asserts all three items are disabled (no second job can start).
-->

<Story
	name="RunningGuardDisablesAllItems"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);

		await clickWhenReady(body.getByRole('button', { name: 'Export' }));
		await waitFor(() => expect(body.getByText('Export as CSV')).toBeVisible());

		// A scripted click starts the export — the menu closes and `running`
		// gates every item. (A userEvent click here trips the Bits UI
		// pointer-events restore race — see the testing strategy — and the
		// guard under test is the disabled state, not the pointer path.)
		body
			.getByText('Export as CSV')
			.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
		await waitFor(() =>
			expect(
				body.getAllByText('Export started — the file link lands here when ready.').length
			).toBeGreaterThan(0)
		);

		// Reopen the menu while the job is pending. A scripted second click
		// toggles `open` back to true — but the item list re-renders through
		// the portalled content asynchronously, so drive the toggle and then
		// wait for the running-state labels the disabled items carry.
		const trigger = body.getByRole('button', { name: 'Export' });
		trigger.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
		await waitFor(() => expect(body.getByText('View — exporting…')).toBeVisible());
		await expect(body.getByText('View — exporting…').closest('[role=menuitem]')).toHaveAttribute(
			'aria-disabled',
			'true'
		);
		await expect(body.getByText('CSV — exporting…').closest('[role=menuitem]')).toHaveAttribute(
			'aria-disabled',
			'true'
		);
		await expect(body.getByText('JSON — exporting…').closest('[role=menuitem]')).toHaveAttribute(
			'aria-disabled',
			'true'
		);
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 300px; padding: 24px;">
			<ExportMenu
				domain={args.domain}
				doctype={args.doctype}
				view={tableView}
				fetchImpl={pendingFetch('jg')}
			/>
			<ToastHost />
		</div>
	{/snippet}
</Story>
