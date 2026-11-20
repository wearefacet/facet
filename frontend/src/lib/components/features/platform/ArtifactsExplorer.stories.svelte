<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import ArtifactsExplorer from './ArtifactsExplorer.svelte';
	import type { ArtifactRow, ArtifactGrantRow, ArtifactReferenceRow } from './ArtifactsSource.js';

	const ROWS: ArtifactRow[] = [
		{
			id: '01ART1',
			filename: 'brand-logo.png',
			mime_type: 'image/png',
			size: 20480,
			sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
			deleted_at: null,
			created_at: '2026-01-10T08:00:00Z',
			uploaded_by: 'account_kim',
			owner_count: 2,
			grant_count: 1,
			reference_count: 3
		},
		{
			id: '01ART2',
			filename: 'contract-2026.pdf',
			mime_type: 'application/pdf',
			size: 512000,
			sha256: 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
			deleted_at: null,
			created_at: '2026-01-11T09:30:00Z',
			uploaded_by: 'system',
			owner_count: 1,
			grant_count: 0,
			reference_count: 1
		},
		{
			id: '01ART3',
			filename: 'legacy-banner.jpg',
			mime_type: 'image/jpeg',
			size: 8192,
			sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
			deleted_at: '2026-01-12T10:00:00Z',
			created_at: '2026-01-05T07:00:00Z',
			uploaded_by: null,
			owner_count: 0,
			grant_count: 0,
			reference_count: 0
		}
	];

	const GRANTS: ArtifactGrantRow[] = [
		{
			id: '01GRANT1',
			artifact_id: '01ART1',
			owner_id: '01OWNER1',
			kind: 'permanent',
			expires_at: null,
			epoch: 0,
			created_by: 'account_kim',
			created_at: '2026-01-10T09:00:00Z'
		},
		{
			id: '01GRANT2',
			artifact_id: '01ART1',
			owner_id: '01OWNER1',
			kind: 'ephemeral',
			expires_at: '2020-01-01T00:00:00Z',
			epoch: 0,
			created_by: 'op',
			created_at: '2026-01-11T09:00:00Z'
		}
	];

	const REFERENCES: ArtifactReferenceRow[] = [
		{
			domain: 'hr',
			doc_type: 'Employee',
			resource_id: '01DOC1',
			display_name: 'Alice Martin',
			resource_field: 'avatar',
			last_reference_at: '2026-01-12T10:00:00Z'
		},
		{
			domain: 'crm',
			doc_type: 'Company',
			resource_id: '01DOC2',
			display_name: null,
			resource_field: 'assets[0].file',
			last_reference_at: '2026-01-11T12:00:00Z'
		},
		{
			domain: 'hr',
			doc_type: null,
			resource_id: '01DOC3',
			display_name: null,
			resource_field: 'file',
			last_reference_at: '2026-01-10T08:00:00Z'
		}
	];

	/**
	 * Driver for the hydrated capsules: one seeded account (the grants
	 * table hydrates `account_kim` → "Kim Alvein") and one Employee (the
	 * references table hydrates `01DOC1` → "Alice Martin"). The `crm.Company`
	 * reference has no seed — it exercises the failed-hydration fallback.
	 */
	function makeDriver(): MockDataDriver {
		const drv = new MockDataDriver();
		drv.registerDoctype('iam', 'Account', {
			doctype: 'Account',
			domain: 'iam',
			fields: { name: { key: 'name', type: 'string', title: 'Name' } }
		});
		void drv.domain('iam').doctype('Account', [{ id: 'account_kim', name: 'Kim Alvein' }]);
		drv.registerDoctype('hr', 'Employee', {
			doctype: 'Employee',
			domain: 'hr',
			fields: { name: { key: 'name', type: 'string', title: 'Name' } }
		});
		void drv.domain('hr').doctype('Employee', [{ id: '01DOC1', name: 'Alice Martin' }]);
		return drv;
	}

	const { Story } = defineMeta({
		title: 'Components/Features/Platform/ArtifactsExplorer',
		component: ArtifactsExplorer,
		// A11y backlog (audit 22 — see .storybook/preview.ts): the Bits UI
		// `Select` dropdown portal (role=listbox) carries no accessible name;
		// the violation surfaces when a play function opens the filter and the
		// closing portal is still mounted at the afterEach scan. Same root
		// cause as IndexesTable — fix in the shared primitive, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';

	const selectSpy = fn();
	const revokeSpy = fn();
	const filterSpy = fn();
	const openRefSpy = fn();
	const purgeSpy = fn();
</script>

<Story
	name="RendersArtifactRows"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('brand-logo.png')).toBeVisible());
		await expect(canvas.getByText('contract-2026.pdf')).toBeVisible();
		await expect(canvas.getByText('legacy-banner.jpg')).toBeVisible();
		// Data is mono and rendered as-is: mime type + formatted size.
		await expect(canvas.getByText('application/pdf')).toBeVisible();
		await expect(canvas.getByText('500 KB')).toBeVisible();
		// Tombstone badge on the deleted row.
		await expect(canvas.getByText('deleted')).toBeVisible();
		// Uploaded by: raw ids without a driver (no hydration), and the em
		// dash for the ownerless tombstone.
		await expect(canvas.getByText('account_kim')).toBeVisible();
		await expect(canvas.getByText('system')).toBeVisible();
		await expect(canvas.getByText('—')).toBeVisible();
		// Count columns show the child-table aggregates.
		await expect(canvas.getByText('20.0 KB')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				onSelect={selectSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText(/No artifacts stored/)).toBeVisible());
		await expect(canvas.getByText(/Select an artifact/)).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer items={[]} meta={{ count: 0, more: false }} page={1} />
		</div>
	{/snippet}
</Story>

<Story
	name="SelectionShowsGrantsAndReferences"
	play={async () => {
		const canvas = within(document.body);
		// Row click reports the selection upwards.
		await userEvent.click(canvas.getByRole('button', { name: /brand-logo.png/ }));
		await waitFor(() => expect(selectSpy).toHaveBeenCalled());

		// Detail panel: facts (including the artifact id), grants table,
		// references table.
		await waitFor(() => expect(canvas.getByText('01ART1')).toBeVisible());
		await expect(canvas.getByText('Permanent')).toBeVisible();
		await expect(canvas.getByText('Ephemeral')).toBeVisible();
		await expect(canvas.getByText('Never expires')).toBeVisible();
		await expect(canvas.getByText('expired')).toBeVisible();
		await expect(canvas.getByText('Referenced by')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				grants={GRANTS}
				grantsMeta={{ count: 2, more: false }}
				references={REFERENCES}
				referencesMeta={{ count: 3, more: false }}
				onSelect={selectSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CapsulesHydrateAndOpenReferences"
	play={async () => {
		const canvas = within(document.body);
		// The account capsules hydrate through the mock driver: the grant
		// minter, the uploaded-by column and the detail fact all name
		// `account_kim`.
		await waitFor(() => expect(canvas.getAllByText('Kim Alvein').length).toBeGreaterThanOrEqual(1));
		// A non-account minter (`op`) stays plain text — same for the
		// `system` uploader sentinel.
		await expect(canvas.getByText('op')).toBeVisible();
		await expect(canvas.getByText('system')).toBeVisible();
		// The em dash marks the artifact with no owner row at all (the
		// references table renders its own dash for a gone projection).
		await expect(canvas.getAllByText('—').length).toBeGreaterThanOrEqual(1);
		// The resolvable resource capsule hydrates its display name.
		await expect(canvas.getByText('Alice Martin')).toBeVisible();
		// The unresolvable resource capsule falls back to the qualified id.
		await expect(canvas.getByText('crm.Company.01DOC2')).toBeVisible();
		// A null `doc_type` (projection gone) stays plain text.
		await expect(canvas.getByText('01DOC3')).toBeVisible();

		// Clicking a resource capsule follows the reference upwards. The
		// Capsule reports the full stored reference (`id` = the qualified
		// value it hydrated from).
		openRefSpy.mockClear();
		await userEvent.click(canvas.getByText('Alice Martin'));
		await waitFor(() => expect(openRefSpy).toHaveBeenCalled());
		await expect(openRefSpy.mock.calls[0][0]).toMatchObject({
			domain: 'hr',
			doctype: 'Employee'
		});
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				grants={GRANTS}
				grantsMeta={{ count: 2, more: false }}
				references={REFERENCES}
				referencesMeta={{ count: 3, more: false }}
				driver={makeDriver()}
				onOpenReference={openRefSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RevokeButtonFiresCallback"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Permanent')).toBeVisible());
		const revoke = canvas.getAllByRole('button', { name: /Revoke/ })[0];
		await expect(revoke).toBeVisible();
		await userEvent.click(revoke);
		await waitFor(() => expect(revokeSpy).toHaveBeenCalled());
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				grants={GRANTS}
				grantsMeta={{ count: 2, more: false }}
				references={REFERENCES}
				referencesMeta={{ count: 2, more: false }}
				canRevoke={true}
				onRevoke={revokeSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RevokeHiddenWithoutPermission"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Permanent')).toBeVisible());
		// getAllByRole throws on zero matches — queryAllByRole asserts absence.
		await expect(canvas.queryAllByRole('button', { name: /Revoke/ })).toHaveLength(0);
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				grants={GRANTS}
				grantsMeta={{ count: 2, more: false }}
				references={REFERENCES}
				referencesMeta={{ count: 2, more: false }}
				canRevoke={false}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FilterInputPushesParams"
	play={async () => {
		filterSpy.mockClear();
		const canvas = within(document.body);
		const input = canvas.getByLabelText('Filename') as HTMLInputElement;
		await userEvent.type(input, 'logo');
		await waitFor(() => expect(filterSpy).toHaveBeenCalled());
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				onFilterChange={filterSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DownloadLinkThroughGateway"
	play={async () => {
		const canvas = within(document.body);
		// The detail header links to the cookie-auth download gateway; it
		// opens a new tab so the inline/attachment disposition decides
		// view vs download.
		const link = canvas.getByRole('link', { name: /Open or download brand-logo.png/ });
		await expect(link).toBeVisible();
		await expect(link).toHaveAttribute('href', '/Api/core/artifacts/01ART1/download');
		await expect(link).toHaveAttribute('target', '_blank');
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DownloadLinkHiddenForTombstone"
	play={async () => {
		const canvas = within(document.body);
		// A tombstoned artifact answers 410 at the mint — no link.
		await waitFor(() => expect(canvas.getAllByText('legacy-banner.jpg').length).toBeGreaterThan(0));
		await expect(
			canvas.queryByRole('link', { name: /Open or download legacy-banner.jpg/ })
		).toBeNull();
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[2]}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="PurgeButtonFiresCallback"
	play={async () => {
		purgeSpy.mockClear();
		const canvas = within(document.body);
		const button = canvas.getByRole('button', { name: /Force delete artifact 01ART1/ });
		await expect(button).toBeVisible();
		await userEvent.click(button);
		await waitFor(() => expect(purgeSpy).toHaveBeenCalledWith(ROWS[0]));
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				canPurge={true}
				onPurge={purgeSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="PurgeHiddenWithoutPermission"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('01ART1')).toBeVisible());
		// getAllByRole throws on zero matches — queryAllByRole asserts absence.
		await expect(canvas.queryAllByRole('button', { name: /Force delete/ })).toHaveLength(0);
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<ArtifactsExplorer
				items={ROWS}
				meta={{ count: 3, more: false }}
				page={1}
				selected={ROWS[0]}
				canPurge={false}
			/>
		</div>
	{/snippet}
</Story>
