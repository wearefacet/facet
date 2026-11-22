<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import GlobalAuditTable from './GlobalAuditTable.svelte';
	import { auditFilterDoctype } from './auditFilters.js';
	import type { MutationRecord } from '$lib/datasource/types.js';

	const SEED: MutationRecord[] = [
		{
			id: '01MUT001',
			domain: 'hr',
			doc_type: 'Employee',
			doc_id: 'abc123',
			idx: 1,
			action: 'create',
			actioner_id: 'account-1',
			arguments: { content: { name: 'Alice' } },
			channel: 'session',
			cause_kind: 'request',
			cause_trace: '01MUT001',
			emitted_at: '2025-06-01T08:00:00Z'
		},
		{
			id: '01MUT002',
			domain: 'hr',
			doc_type: 'Employee',
			doc_id: 'abc123',
			idx: 2,
			action: 'update',
			actioner_id: 'account-2',
			arguments: { diff: { set: [{ path: 'name', value: 'Alice Smith' }] } },
			app: '01APP1',
			channel: 'session',
			cause_kind: 'request',
			cause_trace: '01MUT002',
			emitted_at: '2025-06-02T09:30:00Z'
		},
		{
			id: '01MUT003',
			domain: 'org',
			doc_type: 'Policy',
			doc_id: 'pol99',
			idx: 1,
			action: 'create',
			actioner_id: 'admin',
			arguments: { content: { title: 'Safety policy' } },
			channel: 'api_key',
			cause_kind: 'request',
			cause_trace: '01MUT003',
			emitted_at: '2025-06-03T11:15:00Z'
		},
		{
			id: '01MUT004',
			domain: 'org',
			doc_type: 'Policy',
			doc_id: 'pol99',
			idx: 2,
			action: 'delete',
			actioner_id: 'admin',
			arguments: {},
			channel: 'internal',
			cause_kind: 'cascade',
			cause_trace: '01MUT004',
			emitted_at: '2025-06-04T12:00:00Z'
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Audit/GlobalAuditTable',
		component: GlobalAuditTable,
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** A bare `iam.Account` ULID — renders as a clickable account capsule. */
	const ACTOR_ULID = '01JCATPMKP4N82GVG2J7K4MHZZ';

	/** One row whose actioner is a signed-in account. */
	const ACTOR_ROW: MutationRecord[] = [
		{
			id: '01MUT005',
			domain: 'hr',
			doc_type: 'Employee',
			doc_id: 'abc123',
			idx: 3,
			action: 'update',
			actioner_id: ACTOR_ULID,
			arguments: { diff: { set: [{ path: 'name', value: 'Alice Smith' }] } },
			channel: 'session',
			cause_kind: 'request',
			cause_trace: '01MUT005',
			emitted_at: '2025-06-05T08:45:00Z'
		}
	];

	/**
	 * Filter schema with static values only — the dynamic enums (domains,
	 * doctypes, apps) stay empty here; the page injects the live lists.
	 */
	const FILTER_DEF = auditFilterDoctype();
</script>

<script lang="ts">
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';

	const selectSpy = fn();
	const filterSpy = fn();
	const pageSpy = fn();
	const actorSpy = fn();
</script>

<Story
	name="RendersRowsAndBadges"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getAllByText('Created').length).toBe(2));
		await expect(canvas.getByText('Updated')).toBeVisible();
		await expect(canvas.getByText('Deleted')).toBeVisible();
		// Without a driver the capsules fall back to the bare document id.
		await expect(canvas.getAllByText('abc123').length).toBe(2);
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable items={SEED} meta={{ count: 4, more: false }} page={1} />
		</div>
	{/snippet}
</Story>

<Story
	name="RowClickSelectsMutation"
	play={async () => {
		selectSpy.mockClear();
		const canvas = within(document.body);
		// 'Updated' is unique to the 01MUT002 row; scope via its row.
		await waitFor(() => expect(canvas.getByText('Updated')).toBeVisible());
		const row = canvas.getByText('Updated').closest('tr');
		if (!row) throw new Error('row not found');
		// Click a plain cell (not the capsule — it opens the QuickView).
		await userEvent.click(within(row).getByText('account-2'));
		await expect(selectSpy).toHaveBeenCalledTimes(1);
		await expect(selectSpy.mock.calls[0][0]).toMatchObject({ id: '01MUT002' });
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable
				items={SEED}
				meta={{ count: 4, more: false }}
				page={1}
				onSelect={selectSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ActorCapsuleOpensQuickView"
	play={async () => {
		selectSpy.mockClear();
		actorSpy.mockClear();
		const canvas = within(document.body);
		// The bare-ULID actor renders as an account capsule; clicking opens the
		// account in the QuickView and stops propagation — the row stays
		// unselected.
		await waitFor(() => expect(canvas.getByText(ACTOR_ULID)).toBeVisible());
		await userEvent.click(canvas.getByText(ACTOR_ULID));
		await expect(actorSpy).toHaveBeenCalledTimes(1);
		await expect(actorSpy.mock.calls[0][0]).toMatchObject({
			domain: 'iam',
			doctype: 'Account',
			id: ACTOR_ULID
		});
		await expect(selectSpy).not.toHaveBeenCalled();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable
				items={ACTOR_ROW}
				meta={{ count: 1, more: false }}
				page={1}
				onSelect={selectSpy}
				onOpenActor={actorSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FilterBarRendersChipsFromProps"
	play={async () => {
		const canvas = within(document.body);
		// The shared FilterBar renders one chip per active filter: the chip
		// label is the field title, the value control shows the selected
		// enum's label. Chip interaction (add menu, operator dropdown) is
		// covered by the FilterBar's own stories — portalled dropdowns stay
		// out of play functions here.
		await waitFor(() => expect(canvas.getAllByText('Action').length).toBeGreaterThan(0));
		await expect(canvas.getByText('Updated')).toBeVisible();
		await expect(canvas.getByLabelText('Remove filter')).toBeInTheDocument();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable
				items={SEED}
				meta={{ count: 4, more: false }}
				page={1}
				doctype={FILTER_DEF}
				filters={{ action__eq: 'update' }}
				onFilterChange={filterSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ChannelColumnRendersLabel"
	play={async () => {
		const canvas = within(document.body);
		// Channels render through `channelLabel`: `session` shows as `facet`,
		// others verbatim. The header carries the same word as the filter.
		await waitFor(() => expect(canvas.getAllByText('facet').length).toBe(2));
		await expect(canvas.getByText('api_key')).toBeVisible();
		await expect(canvas.getByText('internal')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable items={SEED} meta={{ count: 4, more: false }} page={1} />
		</div>
	{/snippet}
</Story>

<Story
	name="FooterCountsRemainingRows"
	play={async () => {
		const canvas = within(document.body);
		// The API reports the matching rows from this page's offset, not a global
		// total. The footer labels the number for what it is — the rows from
		// here onward — so a reader does not think rows vanished between pages.
		await waitFor(() => expect(canvas.getByText(/353 mutations from here/)).toBeVisible());
		await expect(canvas.queryByText(/total mutations/)).toBeNull();
		await expect(canvas.getByText(/Page 2/)).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<GlobalAuditTable items={SEED} meta={{ count: 353, more: false }} page={2} />
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
			<GlobalAuditTable
				items={SEED}
				meta={{ count: 4, more: false }}
				page={2}
				onPageChange={pageSpy}
			/>
		</div>
	{/snippet}
</Story>
