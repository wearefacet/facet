<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ImportDomainDialog from './ImportDomainDialog.svelte';
	import type { FetchImpl } from '$lib/portableDomains/portableDomainsClient.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/ImportDomainDialog',
		component: ImportDomainDialog,
		tags: ['autodocs'],
		argTypes: {
			// The stubbed fetch is a play-internal concern; the controls pane
			// stays focused on the observable surface (open + callback).
			fetchImpl: { table: { disable: true } },
			onimported: { table: { disable: true } }
		}
	});

	// The import URL the latest stubbed enqueue received — plays assert on
	// it (query string) after resetting it. Stories run sequentially.
	let lastImportUrl = '';

	/**
	 * Builds a fetch stub: the import route answers the `202` enqueue body
	 * (its URL lands in `lastImportUrl` for query assertions), the status
	 * route always answers with `status`.
	 */
	function stubFetch(
		enqueue: { job_id: string; target_domain?: string },
		status: Record<string, unknown>
	): FetchImpl {
		return (async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			// Exact match — `/Api/core/Domain/import_export/...` shares the prefix.
			if (url === '/Api/core/Domain/import' || url.startsWith('/Api/core/Domain/import?')) {
				lastImportUrl = url;
				return new Response(JSON.stringify({ ...enqueue, status_url: '/s' }), { status: 202 });
			}
			if (url.includes('/import_export/')) {
				return new Response(JSON.stringify(status), { status: 200 });
			}
			return new Response(JSON.stringify({ error: 'unexpected route' }), { status: 404 });
		}) as FetchImpl;
	}
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
</script>

<!--
	Bits UI `Dialog.Portal` mounts into `document.body`, so the play functions
	query `within(document.body)`. The file input is driven with
	`userEvent.upload` — a programmatic `value` set would not fire `change`.
	Every play closes the dialog at the end so later stories start with a
	clean portal.
-->

<Story
	name="SubmitDisabledUntilABundleIsPicked"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import domain bundle')).toBeVisible());

		const importBtn = body.getByRole('button', { name: 'Import' });
		await expect(importBtn).toBeDisabled();

		const zip = new File(['PK\x03\x04'], 'crm.facet-domain.zip', { type: 'application/zip' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, zip);
		await waitFor(() => expect(body.getByText('crm.facet-domain.zip')).toBeVisible());
		await expect(importBtn).toBeEnabled();

		// Clean up so later stories see a single dialog in the portal.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Import domain bundle')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 560px;">
			<ImportDomainDialog open={args.open} />
		</div>
	{/snippet}
</Story>

<Story
	name="SucceededReportRendersTheCounters"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import domain bundle')).toBeVisible());

		const zip = new File(['PK\x03\x04'], 'crm.facet-domain.zip', { type: 'application/zip' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, zip);

		const importBtn = body.getByRole('button', { name: 'Import' });
		await waitFor(() => expect(importBtn).toBeEnabled());
		await userEvent.click(importBtn);

		// The stub answers 202 → succeeded immediately: the counters report.
		await waitFor(() =>
			expect(body.getByText('5 created · 2 updated · 0 unchanged')).toBeVisible()
		);
		await expect(body.getByText('ops')).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => expect(body.queryByText('Import domain bundle')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 560px;">
			<ImportDomainDialog
				open={args.open}
				fetchImpl={stubFetch(
					{ job_id: 'j1', target_domain: 'ops' },
					{
						id: 'j1',
						status: 'succeeded',
						result: {
							domain: 'ops',
							created: 1,
							doctypes_created: 5,
							doctypes_updated: 2,
							doctypes_unchanged: 0,
							document_views_created: 0,
							document_views_updated: 0,
							document_views_deleted: 0,
							collection_views_created: 0,
							collection_views_updated: 0,
							documents_created: 0
						}
					}
				)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ExpectedFailureRendersTheBackendMessage"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import domain bundle')).toBeVisible());

		const zip = new File(['PK\x03\x04'], 'crm.facet-domain.zip', { type: 'application/zip' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, zip);

		const importBtn = body.getByRole('button', { name: 'Import' });
		await waitFor(() => expect(importBtn).toBeEnabled());
		await userEvent.click(importBtn);

		// The backend's rejection surfaces verbatim (version gate, 409, …).
		await waitFor(() => expect(body.getByText('The import failed.')).toBeVisible());
		await expect(body.getByText('Version 3 is lower than the live version 5')).toBeVisible();

		// Pick another bundle returns to the pick step, dialog stays usable.
		await userEvent.click(body.getByRole('button', { name: 'Pick another bundle' }));
		await waitFor(() => expect(body.getByText('Import domain bundle')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Import domain bundle')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 560px;">
			<ImportDomainDialog
				open={args.open}
				fetchImpl={stubFetch(
					{ job_id: 'j2' },
					{
						id: 'j2',
						status: 'failed',
						error: 'Version 3 is lower than the live version 5',
						result: { expected: true }
					}
				)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="IntoAndMergeReachTheImportQuery"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Import domain bundle')).toBeVisible());

		lastImportUrl = '';

		const zip = new File(['PK\x03\x04'], 'crm.facet-domain.zip', { type: 'application/zip' });
		await userEvent.upload(document.querySelector('.file-input') as HTMLInputElement, zip);

		// Optional rename + the merge toggle land in the query string.
		await userEvent.type(body.getByLabelText('Import as domain'), 'ops2');
		await userEvent.click(body.getByLabelText('Merge into existing domain'));

		const importBtn = body.getByRole('button', { name: 'Import' });
		await waitFor(() => expect(importBtn).toBeEnabled());
		await userEvent.click(importBtn);

		await waitFor(() => expect(lastImportUrl).toBe('/Api/core/Domain/import?into=ops2&merge=true'));

		await userEvent.click(body.getByRole('button', { name: 'Done' }));
		await waitFor(() => expect(body.queryByText('Import domain bundle')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 560px;">
			<ImportDomainDialog
				open={args.open}
				fetchImpl={stubFetch(
					{ job_id: 'j3', target_domain: 'ops2' },
					{
						id: 'j3',
						status: 'succeeded',
						result: {
							domain: 'ops2',
							created: 1,
							doctypes_created: 3,
							doctypes_updated: 0,
							doctypes_unchanged: 0,
							document_views_created: 0,
							document_views_updated: 0,
							document_views_deleted: 0,
							collection_views_created: 0,
							collection_views_updated: 0,
							documents_created: 0
						}
					}
				)}
			/>
		</div>
	{/snippet}
</Story>
