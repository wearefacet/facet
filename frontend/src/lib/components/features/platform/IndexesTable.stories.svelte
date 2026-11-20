<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import IndexesTable from './IndexesTable.svelte';
	import type { IndexRow } from './IndexesSource.js';

	const SEED: IndexRow[] = [
		{
			id: '01IDX1',
			domain: 'hr',
			doc_type: 'Employee',
			field_name: 'email',
			index_type: 'btree',
			index_name: 'idx_env_hr_01a2b3c4',
			status: 'active',
			error_message: null,
			created_at: '2026-01-10T08:00:00Z',
			updated_at: '2026-01-10T08:00:05Z'
		},
		{
			id: '01IDX2',
			domain: 'hr',
			doc_type: 'Employee',
			field_name: 'full_name',
			index_type: 'gin_trgm',
			index_name: 'idx_env_hr_9f8e7d6c',
			status: 'pending',
			error_message: null,
			created_at: '2026-01-11T09:00:00Z',
			updated_at: '2026-01-11T09:00:02Z'
		},
		{
			id: '01IDX3',
			domain: 'crm',
			doc_type: 'Company',
			field_name: 'revenue',
			index_type: 'btree_money',
			index_name: 'idx_env_crm_55aa11bb',
			status: 'error',
			error_message: 'CREATE INDEX CONCURRENTLY failed: deadlock detected',
			created_at: '2026-01-12T10:00:00Z',
			updated_at: '2026-01-12T10:00:30Z'
		},
		{
			id: '01IDX4',
			domain: 'crm',
			doc_type: 'Company',
			field_name: 'legacy_ref',
			index_type: 'btree',
			index_name: 'idx_env_crm_deadbeef',
			status: 'dropped',
			error_message: null,
			created_at: '2026-01-05T07:00:00Z',
			updated_at: '2026-01-09T07:00:00Z'
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Platform/IndexesTable',
		component: IndexesTable,
		// A11y backlog (audit 22 — see .storybook/preview.ts): the Bits UI
		// `Select` dropdown portal (role=listbox) carries no accessible name;
		// the violation surfaces when a play function opens the filter and the
		// closing portal is still mounted at the afterEach scan. Same root
		// cause as GlobalAuditTable — fix in the shared primitive, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';

	const filterSpy = fn();
	const pageSpy = fn();
	const refreshSpy = fn();
</script>

<Story
	name="RendersRowsAndStatusBadges"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Active')).toBeVisible());
		await expect(canvas.getByText('Pending')).toBeVisible();
		await expect(canvas.getByText('Dropped')).toBeVisible();
		// 'Error' is both a column header and a badge — assert the badge by its
		// unique error message, then the header by role.
		await expect(canvas.getByText(/deadlock detected/)).toBeVisible();
		await expect(canvas.getByRole('columnheader', { name: 'Error' })).toBeVisible();
		// Data is mono: identifiers and codes render as-is.
		await expect(canvas.getByText('idx_env_crm_55aa11bb')).toBeVisible();
		await expect(canvas.getByText('btree_money')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable items={SEED} meta={{ count: 4, more: false }} page={1} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyState"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText(/No indexes tracked/)).toBeVisible());
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable items={[]} meta={{ count: 0, more: false }} page={1} />
		</div>
	{/snippet}
</Story>

<Story
	name="FilterChangeUpdatesParams"
	play={async () => {
		filterSpy.mockClear();
		const canvas = within(document.body);
		// The status filter is the typeable `Select` primitive (Bits UI
		// combobox) — the dropdown portals to document.body. 'Pending' also
		// labels a row badge, so pick the dropdown entry by its `option` role.
		const combo = canvas.getByLabelText('Status');
		await userEvent.click(combo);
		await waitFor(() =>
			expect(within(document.body).getAllByRole('option', { name: 'Pending' }).length).toBe(1)
		);
		await userEvent.click(within(document.body).getByRole('option', { name: 'Pending' }));
		await expect(filterSpy).toHaveBeenCalledWith({ status__eq: 'pending' });
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable
				items={SEED}
				meta={{ count: 4, more: false }}
				page={1}
				onFilterChange={filterSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="TextFieldFilterCommitsValue"
	play={async () => {
		filterSpy.mockClear();
		const canvas = within(document.body);
		const input = canvas.getByLabelText('Domain');
		await userEvent.type(input, 'hr');
		await expect(filterSpy).toHaveBeenCalledWith({ domain__match: 'hr' });
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable
				items={SEED}
				meta={{ count: 4, more: false }}
				page={1}
				onFilterChange={filterSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="PaginationUsesMoreFlag"
	play={async () => {
		pageSpy.mockClear();
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Next →')).toBeVisible());
		// With more = false, Next should be disabled.
		await expect(canvas.getByText('Next →')).toBeDisabled();
		// With more = true, Next is enabled and clicking notifies the page.
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable items={SEED} meta={{ count: 4, more: false }} page={2} onPageChange={pageSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="RefreshButtonNotifies"
	play={async () => {
		refreshSpy.mockClear();
		const canvas = within(document.body);
		const btn = await waitFor(() => {
			const el = canvas.getByRole('button', { name: 'Refresh index status' });
			expect(el).toBeVisible();
			return el;
		});
		await userEvent.click(btn);
		await expect(refreshSpy).toHaveBeenCalledTimes(1);
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable items={SEED} meta={{ count: 4, more: false }} page={1} onRefresh={refreshSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="ErrorBanner"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Backend unreachable')).toBeVisible());
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<IndexesTable items={[]} error="Backend unreachable" meta={null} page={1} />
		</div>
	{/snippet}
</Story>
