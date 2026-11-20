<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import ImportDialog from './ImportDialog.svelte';
	import type { FetchImpl } from '$lib/importExport/importExportClient.js';

	// Spy capture for the import-completion callback (B-106 wiring).
	const importedSpy = fn();

	const { Story } = defineMeta({
		title: 'Components/Features/ImportExport/ImportDialog',
		component: ImportDialog,
		tags: ['autodocs'],
		argTypes: {
			// The stubbed fetch is a play-internal concern; the controls pane
			// stays focused on the observable surface (open + coordinates).
			fetchImpl: { table: { disable: true } }
		}
	});

	/** Builds a fetch stub whose status route always answers with `status`. */
	function stubFetch(
		enqueue: { job_id: string; row_count?: number },
		status: Record<string, unknown>,
		statusCode = 200
	): FetchImpl {
		return (async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url.endsWith('/import')) {
				return new Response(JSON.stringify({ ...enqueue, status_url: '/s' }), { status: 202 });
			}
			if (url.includes('/import_export/')) {
				return new Response(JSON.stringify(status), { status: statusCode });
			}
			return new Response(JSON.stringify({ error: 'unexpected route' }), { status: 404 });
		}) as FetchImpl;
	}
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import ImportExportActions from './ImportExportActions.svelte';
</script>

<!--
	Bits UI `Dialog.Portal` mounts into `document.body`, so the play functions
	query `within(document.body)`. The file input is driven with
	`userEvent.upload` — a programmatic `value` set would not fire `change`.
	Every play closes the dialog at the end so later stories start with a
	clean portal.
-->

<Story
	name="SubmitDisabledUntilAFileIsPicked"
	args={{ open: true, domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		const importBtn = body.getByRole('button', { name: 'Import' });
		await expect(importBtn).toBeDisabled();

		const csv = new File(['id,name\n,Acme\n'], 'rows.csv', { type: 'text/csv' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, csv);

		// The header preview renders from the picked file.
		await waitFor(() => expect(body.getByText('1 rows')).toBeVisible());
		await expect(body.getByText(/id · name/)).toBeVisible();

		await expect(importBtn).toBeEnabled();

		// Clean up so later stories see a single dialog in the portal.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Import Company')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<ImportDialog open={args.open} domain={args.domain} doctype={args.doctype} />
		</div>
	{/snippet}
</Story>

<Story
	name="SucceededReportRendersTheCounts"
	args={{ open: true, domain: 'crm', doctype: 'Company', onimported: importedSpy }}
	play={async ({ args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		const csv = new File(['id,name\n,Acme\n,Beta\n'], 'rows.csv', { type: 'text/csv' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, csv);

		const importBtn = body.getByRole('button', { name: 'Import' });
		await waitFor(() => expect(importBtn).toBeEnabled());
		await userEvent.click(importBtn);

		// The stub answers 202 → succeeded immediately: the upsert report.
		await waitFor(() => expect(body.getByText('2 created · 0 updated · 0 skipped')).toBeVisible());
		// The host's refresh callback ran once the job landed.
		await waitFor(() => expect(args.onimported).toHaveBeenCalled());

		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => expect(body.queryByText('Import Company')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<ImportDialog
				open={args.open}
				domain={args.domain}
				doctype={args.doctype}
				onimported={args.onimported}
				fetchImpl={stubFetch(
					{ job_id: 'j1', row_count: 2 },
					{
						id: 'j1',
						status: 'succeeded',
						result: { row_count: 2, created: 2, updated: 0, skipped: 0 }
					}
				)}
			/>
		</div>
	{/snippet}
</Story>

<!--
	B-221 regression: the dialog's Close button and Escape must tear the
	whole dialog down (overlay included) and sync the host's open state, so
	the toolbar's Import button can open it again. These stories render the
	real host (`ImportExportActions`) because the reopen bug lived in the
	host's open flag going stale after a Bits-UI-initiated close.
-->

<Story
	name="CloseButtonTearsDownAndReopens"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);

		// Open from the toolbar — the host owns the open state.
		await userEvent.click(canvas.getByRole('button', { name: 'Import' }));
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());
		await expect(document.querySelector('[data-dialog-overlay]')).not.toBeNull();

		// Close via the dialog's Close button.
		await userEvent.click(body.getByRole('button', { name: 'Close' }));
		await waitFor(() => {
			expect(document.querySelector('[data-dialog-overlay]')).toBeNull();
			expect(body.queryByText('Import Company')).toBeNull();
		});

		// The same toolbar button must open the dialog again.
		await waitFor(async () => {
			await userEvent.click(canvas.getByRole('button', { name: 'Import' }));
		});
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());
		await expect(document.querySelector('[data-dialog-overlay]')).not.toBeNull();

		// Leave the portal clean for later stories.
		await userEvent.click(body.getByRole('button', { name: 'Close' }));
		await waitFor(() => expect(document.querySelector('[data-dialog-overlay]')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<ImportExportActions domain={args.domain} doctype={args.doctype} />
		</div>
	{/snippet}
</Story>

<Story
	name="EscapeTearsDownAndReopens"
	args={{ domain: 'crm', doctype: 'Company' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'Import' }));
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		// Escape tears the whole dialog down — regression guard for the
		// path that already worked before B-221.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => {
			expect(document.querySelector('[data-dialog-overlay]')).toBeNull();
			expect(body.queryByText('Import Company')).toBeNull();
		});

		// And the toolbar can still open the dialog afterwards.
		await waitFor(async () => {
			await userEvent.click(canvas.getByRole('button', { name: 'Import' }));
		});
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		// Leave the portal clean for later stories.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(document.querySelector('[data-dialog-overlay]')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<ImportExportActions domain={args.domain} doctype={args.doctype} />
		</div>
	{/snippet}
</Story>

<Story
	name="FailedReportRendersTheFailingRow"
	args={{ open: true, domain: 'crm', doctype: 'Company' }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		const csv = new File(['id,email\n,x\n'], 'rows.csv', { type: 'text/csv' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, csv);

		const importBtn = body.getByRole('button', { name: 'Import' });
		await waitFor(() => expect(importBtn).toBeEnabled());
		await userEvent.click(importBtn);

		// All-or-nothing failure: nothing was imported, the failing row is named.
		await waitFor(() => expect(body.getByText('Nothing was imported.')).toBeVisible());
		await expect(body.getByText(/Row 37, field email/)).toBeVisible();
		await expect(body.getByText('Fix the row and submit the file again.')).toBeVisible();

		// Pick another file returns to the pick step, dialog stays usable.
		await userEvent.click(body.getByRole('button', { name: 'Pick another file' }));
		await waitFor(() => expect(body.getByText('Import Company')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Import Company')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<ImportDialog
				open={args.open}
				domain={args.domain}
				doctype={args.doctype}
				fetchImpl={stubFetch(
					{ job_id: 'j2', row_count: 1 },
					{
						id: 'j2',
						status: 'failed',
						result: { row: 37, field: 'email', message: 'is missing' }
					}
				)}
			/>
		</div>
	{/snippet}
</Story>
