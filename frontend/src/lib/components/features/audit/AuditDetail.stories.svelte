<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import AuditDetail from './AuditDetail.svelte';
	import type { MutationRecord } from '$lib/datasource/types.js';

	const SAMPLE: MutationRecord = {
		id: '01MUT1ABCDEFGH2',
		domain: 'hr',
		doc_type: 'Employee',
		doc_id: 'abc123',
		idx: 3,
		action: 'update',
		actioner_id: 'account-1',
		arguments: {
			diff: {
				set: [
					{ path: 'name', value: 'Alice Smith' },
					{ path: 'profile', value: { dept: 'Sales', level: 5 } }
				],
				unset: ['old_field']
			}
		},
		channel: 'session',
		app: null,
		api_key: null,
		acting_role: null,
		cause_kind: 'action',
		cause_name: null,
		cause_event: 'updated',
		cause_source: null,
		cause_parent: null,
		cause_trace: '01MUT1ABCDEFGH2',
		emitted_at: '2025-01-01T09:00:00Z'
	};

	const DELETE_MUTATION: MutationRecord = {
		...SAMPLE,
		id: '01MUTDEL1',
		doc_type: 'CompanyMembership',
		doc_id: 'crm.CompanyMembership.1',
		idx: 2,
		action: 'delete',
		arguments: {},
		cause_kind: 'cascade',
		cause_name: null,
		cause_event: null,
		cause_source: 'crm.Company:crm.Company.1',
		cause_parent: '01MUTROOT'
	};

	/** The cascade cluster: the company delete plus two cascaded memberships. */
	const CLUSTER: MutationRecord[] = [
		{
			...DELETE_MUTATION,
			id: '01MUTROOT',
			doc_type: 'Company',
			doc_id: 'crm.Company.1',
			idx: 3,
			cause_kind: 'request',
			cause_source: null,
			cause_parent: null
		},
		DELETE_MUTATION,
		{
			...DELETE_MUTATION,
			id: '01MUTDEL2',
			doc_id: 'crm.CompanyMembership.2',
			idx: 2,
			emitted_at: '2025-01-01T09:00:01Z'
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Audit/AuditDetail',
		component: AuditDetail,
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const confirmSpy = fn();
	const deleteSpy = fn();
	const clusterSpy = fn();
	const actorSpy = fn();

	/** A bare `iam.Account` ULID — renders as a clickable account capsule. */
	const ACTOR_ULID = '01JCATPMKP4N82GVG2J7K4MHZZ';

	/** Minimal delay helper — lets bits-ui restore the body's pointer-events
	 *  after a modal dialog closes (restored asynchronously on the next tick). */
	function sleep(ms: number): Promise<void> {
		return new Promise((r) => setTimeout(r, ms));
	}
</script>

<Story
	name="RendersChangeEntries"
	play={async () => {
		const canvas = within(document.body);
		await waitFor(() => expect(canvas.getByText('Updated')).toBeVisible());
		await expect(canvas.getByText('/name')).toBeVisible();
		await expect(canvas.getByText('Alice Smith')).toBeVisible();
		await expect(canvas.getByText('removed')).toBeVisible();
		// The actor row shows the machine principal as plain text (not an
		// account capsule), and the session channel displays as `facet`.
		await expect(canvas.getByText('account-1')).toBeVisible();
		await expect(canvas.getByText('via facet')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail mutation={SAMPLE} canRollback={true} onRollback={fn()} />
		</div>
	{/snippet}
</Story>

<Story
	name="ActorCapsuleOpensQuickView"
	play={async () => {
		const canvas = within(document.body);
		// Without a driver the capsule falls back to the bare id, but it stays
		// clickable — the click carries the resolved iam.Account reference.
		await userEvent.click(canvas.getByText(ACTOR_ULID));
		await expect(actorSpy).toHaveBeenCalledTimes(1);
		await expect(actorSpy.mock.calls[0][0]).toMatchObject({
			domain: 'iam',
			doctype: 'Account',
			id: ACTOR_ULID
		});
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail
				mutation={{ ...SAMPLE, actioner_id: ACTOR_ULID }}
				canRollback={true}
				onRollback={fn()}
				onOpenActor={actorSpy}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RestoreDisabledWithoutPermission"
	play={async () => {
		const canvas = within(document.body);
		// A delete target renders the restore action; without update rights it
		// stays disabled and the reason is shown underneath.
		const btn = canvas.getByRole('button', { name: 'Restore document' });
		await waitFor(() => expect(btn).toBeDisabled());
		await expect(
			canvas.getByText('You do not have update permission on this document type.')
		).toBeVisible();
		// The cascade cause renders its source document.
		await expect(canvas.getByText('Cascade')).toBeVisible();
		await expect(canvas.getByText('crm.Company')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail
				mutation={DELETE_MUTATION}
				canRollback={false}
				rollBlockReason="You do not have update permission on this document type."
				onRollback={fn()}
				onOpenSource={fn()}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DeleteRollbackOffersRestore"
	play={async () => {
		const canvas = within(document.body);
		const btn = canvas.getByRole('button', { name: 'Restore document' });
		await waitFor(() => expect(btn).toBeEnabled());
		await userEvent.click(btn);
		const confirm = await waitFor(() => {
			const el = canvas.getByRole('button', { name: 'Roll back' });
			return el;
		});
		// The dialog explains the restore semantics.
		await expect(canvas.getByText(/state recorded by the mutation/)).toBeVisible();
		await userEvent.click(confirm);
		await waitFor(() => expect(deleteSpy).toHaveBeenCalled());
		// Close the dialog so the shared storybook iframe is clean for the next
		// story (a modal sets `pointer-events: none` on body while open).
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText(/state recorded by the mutation/)).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail mutation={DELETE_MUTATION} canRollback={true} onRollback={deleteSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="ClusterRollbackOffersWholeAction"
	play={async () => {
		const spy = clusterSpy;
		const canvas = within(document.body);
		// The cause section names the cluster; both actions are offered.
		await expect(canvas.getByText('One action — 3 changes across 3 documents')).toBeVisible();
		await expect(canvas.getByText(/Roll back the whole action/)).toBeVisible();
		const single = canvas.getByRole('button', { name: 'Restore document' });
		await waitFor(() => expect(single).toBeEnabled());
		const whole = canvas.getByRole('button', { name: /Roll back the whole action/ });
		await userEvent.click(whole);
		const confirm = await waitFor(() => {
			const el = canvas.getByRole('button', { name: 'Roll back action' });
			return el;
		});
		// The dialog lists the affected documents and the clobber warning.
		await expect(
			canvas.getByText(/Later changes to these documents are overwritten/)
		).toBeVisible();
		// The membership id appears in the panel's cluster list AND the dialog.
		expect(canvas.getAllByText('crm.CompanyMembership.2').length).toBeGreaterThanOrEqual(2);
		await userEvent.click(confirm);
		await waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
		// Close the dialog so the shared storybook canvas stays clean.
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Roll back the whole action')).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="min-height: 560px; padding: 16px;">
			<AuditDetail
				mutation={DELETE_MUTATION}
				canRollback={true}
				cluster={CLUSTER}
				onRollback={fn()}
				onRollbackCluster={clusterSpy}
				onOpenSource={fn()}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ConfirmDialogFiresRollback"
	play={async () => {
		const spy = confirmSpy;
		const canvas = within(document.body);
		const btn = canvas.getByRole('button', { name: 'Roll back to this version' });
		await waitFor(() => expect(btn).toBeEnabled());
		await userEvent.click(btn);
		const confirm = await waitFor(() => {
			const el = canvas.getByRole('button', { name: 'Roll back' });
			return el;
		});
		await userEvent.click(confirm);
		await waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
		await expect(spy.mock.calls[0][0]).toMatchObject({ id: '01MUT1ABCDEFGH2' });
		// Close the dialog so the shared iframe stays clean for the next story.
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(canvas.queryByText('Confirm rollback')).toBeNull());
		await sleep(50);
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail mutation={SAMPLE} canRollback={true} onRollback={confirmSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="PlaceholderWhenNoMutation"
	play={async () => {
		const canvas = within(document.body);
		await expect(canvas.getByText('Select a mutation to inspect its changes.')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 480px; padding: 16px;">
			<AuditDetail mutation={null} onRollback={fn()} />
		</div>
	{/snippet}
</Story>
