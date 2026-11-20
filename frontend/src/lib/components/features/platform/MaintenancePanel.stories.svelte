<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import MaintenancePanel from './MaintenancePanel.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { MaintenanceJobRow, MaintenanceStatus } from './MaintenanceSource.js';

	// The doctype picker is a ReferencePicker forced to `core.DocType`; the
	// mock driver auto-seeds those rows (id = qualified doctype id).
	const driver = createMockDriver();

	const SEED_STATUS: MaintenanceStatus = {
		doctype_id: 'crm.Company',
		current_version: 3,
		ahead_count: 12,
		blocked_count: 2
	};

	const SEED_JOBS: MaintenanceJobRow[] = [
		{
			id: '01JOB1',
			kind: 'doctype_reproject',
			status: 'succeeded',
			attempts: 1,
			max_attempts: 3,
			last_error: null,
			result: {
				total: 30,
				processed: 24,
				superseded: 3,
				skipped: 2,
				failed: 1,
				failed_ids: ['01DOC9', '01DOC10']
			},
			account_id: '01ACC1',
			role_id: '01ROLE1',
			created_at: '2026-01-10T08:00:00Z',
			updated_at: '2026-01-10T08:01:00Z'
		},
		{
			id: '01JOB2',
			kind: 'doctype_migrate_ahead',
			status: 'failed',
			attempts: 3,
			max_attempts: 3,
			last_error: 'Migration batch 2 failed: deadlock detected',
			result: null,
			account_id: '01ACC1',
			role_id: '01ROLE2',
			created_at: '2026-01-11T09:00:00Z',
			updated_at: '2026-01-11T09:00:30Z'
		}
	];

	const SEED_PENDING: MaintenanceJobRow = {
		id: '01JOB3',
		kind: 'doctype_reproject',
		status: 'pending',
		attempts: 0,
		max_attempts: 1,
		last_error: null,
		result: null,
		account_id: '01ACC1',
		role_id: '01ROLE1',
		created_at: '2026-01-12T08:00:00Z',
		updated_at: '2026-01-12T08:00:00Z'
	};

	const { Story } = defineMeta({
		title: 'Components/Features/Platform/MaintenancePanel',
		component: MaintenancePanel,
		// A11y backlog: the embedded ReferencePicker carries the violations
		// logged on its own stories (contrast / ARIA structure). Fix there,
		// then remove this override.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import ConfirmDialog from '$lib/components/primitives/surfaces/ConfirmDialog.svelte';
	import * as m from '$lib/paraglide/messages';

	// Shared spies — each play clears the ones it asserts on.
	const loadSpy = fn();
	const retrySpy = fn();
	const enqueueSpy = fn();
	const refreshSpy = fn();
	const pageChangeSpy = fn();
</script>

<!--
	The panel is a pure renderer: the page owns every fetch, so every story
	runs against plain props and spies — no backend and no `apiFetch`
	involved. The doctype picker searches `core.DocType` through the mock
	driver. The confirm host lives in the root layout in the app; the
	confirm story mounts it explicitly or `confirm()` never renders.
-->

<Story
	name="EmptyState"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() =>
			expect(canvas.getByText(m.platform_maintenance_status_empty_hint())).toBeVisible()
		);
		// No doctype loaded — the picker waits for a pick, and the enqueue
		// actions stay disarmed.
		await expect(
			canvas.getByPlaceholderText(m.platform_maintenance_doctype_placeholder())
		).toBeVisible();
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_reproject() })
		).toBeDisabled();
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_migrate() })
		).toBeDisabled();
		await expect(canvas.getByText(m.platform_maintenance_jobs_header())).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel {driver} />
		</div>
	{/snippet}
</Story>

<Story
	name="StatusLoadedWithCounts"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() =>
			expect(
				canvas.getByText(m.platform_maintenance_status_current_version({ version: 3 }))
			).toBeVisible()
		);
		await expect(
			canvas.getByText(m.platform_maintenance_status_ahead_count({ count: 12 }))
		).toBeVisible();
		await expect(
			canvas.getByText(m.platform_maintenance_status_blocked_count({ count: 2 }))
		).toBeVisible();
		// With a loaded doctype the enqueue actions are armed.
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_reproject() })
		).toBeEnabled();
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_migrate() })
		).toBeEnabled();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel {driver} doctype="crm.Company" status={SEED_STATUS} />
		</div>
	{/snippet}
</Story>

<Story
	name="JobsTableWithStatsAndError"
	play={async () => {
		const canvas = within(document.body);
		// Kind + status badges.
		await waitFor(() =>
			expect(canvas.getByText(m.platform_maintenance_kind_reproject())).toBeVisible()
		);
		await expect(canvas.getByText(m.platform_maintenance_kind_migrate())).toBeVisible();
		await expect(canvas.getByText(m.platform_maintenance_job_succeeded())).toBeVisible();
		await expect(canvas.getByText(m.platform_maintenance_job_failed())).toBeVisible();
		// The succeeded job renders the compact run stats.
		await expect(canvas.getByText(/24 processed/)).toBeVisible();
		// The failed job renders its last error.
		await expect(canvas.getByText(/deadlock detected/)).toBeVisible();
		await expect(
			canvas.getByRole('columnheader', { name: m.platform_maintenance_jobs_col_stats() })
		).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel
				{driver}
				doctype="crm.Company"
				status={SEED_STATUS}
				jobs={SEED_JOBS}
				jobsMeta={{ count: 2, more: false, page: 1 }}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="PendingJobBlocksOnlyItsKind"
	play={async () => {
		const canvas = within(document.body);
		// A pending reproject job blocks its own kind (the backend answers 409)…
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_reproject() })
		).toBeDisabled();
		// …but the other kind stays armed — it may run concurrently.
		await expect(
			canvas.getByRole('button', { name: m.platform_maintenance_action_migrate() })
		).toBeEnabled();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel {driver} doctype="crm.Company" status={SEED_STATUS} jobs={[SEED_PENDING]} />
		</div>
	{/snippet}
</Story>

<Story
	name="ForbiddenWithoutRetry"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText(m.platform_maintenance_forbidden())).toBeVisible());
		// The forbidden state replaces the whole surface — no retry button.
		await expect(canvas.queryByRole('button', { name: m.common_retry() })).toBeNull();
		await expect(canvas.queryByText(m.platform_maintenance_status_empty_hint())).toBeNull();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel error={m.platform_maintenance_forbidden()} errorStatus={403} />
		</div>
	{/snippet}
</Story>

<Story
	name="LoadErrorOffersRetry"
	play={async () => {
		retrySpy.mockClear();
		const canvas = within(document.body);
		const retry = await waitFor(() => {
			const el = canvas.getByRole('button', { name: m.common_retry() });
			expect(el).toBeVisible();
			return el;
		});
		await userEvent.click(retry);
		await expect(retrySpy).toHaveBeenCalledTimes(1);
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel error="unknown doctype" errorStatus={404} onRetry={retrySpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="PickLoadsDoctype"
	play={async ({ canvasElement }) => {
		loadSpy.mockClear();
		const canvas = within(document.body);
		const input = canvas.getByPlaceholderText(
			m.platform_maintenance_doctype_placeholder()
		) as HTMLInputElement;
		await userEvent.click(input);
		await userEvent.type(input, 'company');
		// The debounced search resolves against the mock's seeded `core.DocType`
		// rows (labelled by their qualified id). Pick crm.Company.
		const option = await waitFor(() => {
			const el = canvas.getByText('crm.Company');
			expect(el).toBeVisible();
			return el;
		});
		await userEvent.click(option);
		await expect(loadSpy).toHaveBeenCalledWith('crm.Company');
		// The recordMeta override replaces the generic blue mark with the
		// doctype's own tint on the selected chip.
		await waitFor(() => {
			const chip = canvasElement.querySelector('.ref-capsule');
			expect(chip?.getAttribute('style')).toContain('#176e3a');
		});
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel
				{driver}
				recordMeta={{
					'crm.Company': { label: 'crm.Company', icon: 'building-2', color: '#176e3a' }
				}}
				onPickDoctype={loadSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ConfirmRunsEnqueue"
	play={async () => {
		enqueueSpy.mockClear();
		const canvas = within(document.body);
		await userEvent.click(
			canvas.getByRole('button', { name: m.platform_maintenance_action_reproject() })
		);
		// The confirm host portals into document.body; the action button is
		// outside it, so the dialog button is the one inside role=dialog.
		const confirmDialog = await waitFor(() => {
			const el = within(document.body).getByRole('dialog');
			expect(el).toBeVisible();
			return el;
		});
		await expect(
			within(confirmDialog).getByRole('heading', { name: m.platform_maintenance_confirm_title() })
		).toBeVisible();
		// The copy states the audit-log cost.
		await expect(within(confirmDialog).getByText(/audit log row/)).toBeVisible();
		await userEvent.click(
			within(confirmDialog).getByRole('button', { name: m.platform_maintenance_confirm_run() })
		);
		await waitFor(() => expect(enqueueSpy).toHaveBeenCalledTimes(1));
		await expect(enqueueSpy).toHaveBeenCalledWith('reproject');
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel
				{driver}
				doctype="crm.Company"
				status={SEED_STATUS}
				onEnqueue={enqueueSpy}
			/>
			<ConfirmDialog />
		</div>
	{/snippet}
</Story>

<Story
	name="RefreshNotifies"
	play={async () => {
		refreshSpy.mockClear();
		const canvas = within(document.body);
		const btn = await waitFor(() => {
			const el = canvas.getByRole('button', { name: m.platform_maintenance_refresh_aria() });
			expect(el).toBeVisible();
			return el;
		});
		await userEvent.click(btn);
		await expect(refreshSpy).toHaveBeenCalledTimes(1);
		// Without meta.more the Next button is disabled.
		await expect(canvas.getByText(m.platform_maintenance_pager_next())).toBeDisabled();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<MaintenancePanel
				{driver}
				doctype="crm.Company"
				status={SEED_STATUS}
				jobs={SEED_JOBS}
				jobsMeta={{ count: 2, more: false, page: 1 }}
				onJobsRefresh={refreshSpy}
				onJobsPageChange={pageChangeSpy}
			/>
		</div>
	{/snippet}
</Story>
