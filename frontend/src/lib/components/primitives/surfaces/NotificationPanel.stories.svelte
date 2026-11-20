<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import { Bell } from '@lucide/svelte';
	import NotificationPanel from './NotificationPanel.svelte';
	import type { NotificationItem } from './NotificationPanel.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/NotificationPanel',
		component: NotificationPanel,
		tags: ['autodocs'],
		args: {
			onaction: fn(),
			ondownload: fn(),
			onopen: fn(),
			onmarkallread: fn(),
			onclose: fn(),
			onloadmore: fn()
		}
	});

	const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000).toISOString();

	const makeItem = (over: Partial<NotificationItem>): NotificationItem => ({
		id: over.id ?? crypto.randomUUID(),
		domain: 'hr',
		doc_type: 'LeaveRequest',
		doc_id: '01JDOC123',
		kind: 'leave_pending',
		icon: null,
		title: 'Untitled',
		body: '',
		actions: [],
		read_at: null,
		actioned_at: null,
		created_at: minutesAgo(5),
		...over
	});
</script>

<!-- Instance state for the action-flow story: the panel is presentational,
     so the story plays the host — it reflects the route response by stamping
     `read_at` / `actioned_at` on the clicked item. -->
<script lang="ts">
	let firedItems = $state<NotificationItem[]>([
		makeItem({
			id: 'n-act',
			title: 'A leave request awaits your review',
			body: 'Amara Diallo requested 5 days of leave starting Monday.',
			actions: [
				{ key: 'approve', label: 'Approve', variant: 'primary' },
				{ key: 'reject', label: 'Reject', variant: 'danger' }
			]
		})
	]);

	function hostFireAction(item: NotificationItem): void {
		const stamped = {
			...item,
			read_at: new Date().toISOString(),
			actioned_at: new Date().toISOString()
		};
		firedItems = firedItems.map((i) => (i.id === item.id ? stamped : i));
	}
</script>

<Story
	name="Mixed"
	args={{
		unreadCount: 2,
		notifications: [
			makeItem({
				id: 'n-1',
				title: 'A leave request awaits your review',
				body: 'Amara Diallo requested 5 days of leave starting Monday.',
				icon: 'calendar-clock',
				created_at: minutesAgo(3),
				actions: [
					{
						key: 'approve',
						label: 'Approve',
						variant: 'primary',
						confirm: 'Approve this request?'
					},
					{ key: 'reject', label: 'Reject', variant: 'danger', confirm: 'Reject this request?' }
				]
			}),
			makeItem({
				id: 'n-2',
				title: 'Mentioned in SHP-1042',
				body: 'Kara: "The packing list changed — can you re-check the weights?"',
				icon: 'at-sign',
				created_at: minutesAgo(45)
			}),
			makeItem({
				id: 'n-3',
				title: 'Shipment SHP-991 delivered',
				body: 'Signed for by J. Malone at 14:02.',
				icon: 'package-check',
				read_at: minutesAgo(120),
				created_at: minutesAgo(180)
			})
		]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('A leave request awaits your review')).toBeVisible();
		await expect(canvas.getByText('Shipment SHP-991 delivered')).toBeVisible();
		await expect(canvas.getByLabelText('2 unread')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Mark all read' })).toBeVisible();
	}}
/>

<Story
	name="FiredActionDisablesAllActions"
	args={{ unreadCount: 1 }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const approve = canvas.getByRole('button', { name: 'Approve' });
		const reject = canvas.getByRole('button', { name: 'Reject' });
		await expect(approve).toBeEnabled();
		await expect(reject).toBeEnabled();

		// Fire one action; the host reflects the route response by stamping
		// `actioned_at` (and `read_at`) on the item.
		await userEvent.click(approve);
		await expect(args.onaction).toHaveBeenCalledOnce();

		// One click consumes EVERY action on the notification.
		await expect(approve).toBeDisabled();
		await expect(reject).toBeDisabled();
		await expect(canvas.getByText('Action taken')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div
			style="
				min-height: 420px;
				padding: 24px;
				display: flex;
				justify-content: center;
				align-items: flex-start;
			"
		>
			<NotificationPanel
				notifications={firedItems}
				unreadCount={args.unreadCount}
				onaction={(item, action) => {
					args.onaction?.(item, action);
					hostFireAction(item);
				}}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Actioned"
	args={{
		notifications: [
			makeItem({
				id: 'n-done',
				title: 'A leave request awaits your review',
				body: 'Amara Diallo requested 5 days of leave starting Monday.',
				read_at: minutesAgo(10),
				actioned_at: minutesAgo(10),
				actions: [
					{ key: 'approve', label: 'Approve', variant: 'primary' },
					{ key: 'reject', label: 'Reject', variant: 'danger' }
				]
			})
		]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('button', { name: 'Approve' })).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Reject' })).toBeDisabled();
		await expect(canvas.getByText('Action taken')).toBeVisible();
	}}
/>

<Story
	name="Empty"
	args={{ notifications: [], unreadCount: 0 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText("You're all caught up")).toBeVisible();
		await expect(canvas.queryByRole('button', { name: 'Mark all read' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Load more' })).toBeNull();
	}}
/>

<Story
	name="MarksAllRead"
	args={{
		unreadCount: 3,
		notifications: [
			makeItem({ id: 'n-m1', title: 'First' }),
			makeItem({ id: 'n-m2', title: 'Second' })
		]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Mark all read' }));
		await expect(args.onmarkallread).toHaveBeenCalledOnce();
	}}
/>

<Story
	name="LoadMore"
	args={{
		unreadCount: 0,
		more: true,
		notifications: [
			makeItem({ id: 'n-l1', title: 'First', read_at: minutesAgo(1) }),
			makeItem({ id: 'n-l2', title: 'Second', read_at: minutesAgo(2) })
		]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Load more' }));
		await expect(args.onloadmore).toHaveBeenCalledOnce();
	}}
/>

<Story
	name="OpensSourceDocument"
	args={{
		unreadCount: 1,
		notifications: [makeItem({ id: 'n-o1', title: 'A leave request awaits your review' })]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(
			canvas.getByRole('button', { name: 'Open A leave request awaits your review' })
		);
		await expect(args.onopen).toHaveBeenCalledOnce();
		await expect(args.onopen).toHaveBeenCalledWith(args.notifications![0]);
	}}
/>

<Story
	name="DownloadNotification"
	args={{
		unreadCount: 1,
		notifications: [
			makeItem({
				id: 'n-dl1',
				title: 'Export ready',
				body: 'crm.Company.csv — 1234 rows',
				data: { download: '/Api/crm/Company/import_export/j1/download' }
			}),
			makeItem({ id: 'n-dl2', title: 'Mentioned in SHP-1042' })
		]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);

		// Only the row with the reserved `data.download` key renders the
		// Download affordance.
		const download = canvas.getByRole('button', { name: 'Download' });
		await expect(download).toBeVisible();
		await expect(canvas.queryByRole('button', { name: 'Open Export ready' })).toBeNull();
		await expect(canvas.getByRole('button', { name: 'Open Mentioned in SHP-1042' })).toBeVisible();

		// The download is not a doctype action: firing it reports to the host
		// without consuming anything (no actioned marker).
		await userEvent.click(download);
		await expect(args.ondownload).toHaveBeenCalledOnce();
		await expect(args.ondownload).toHaveBeenCalledWith(args.notifications![0]);
		await expect(canvas.queryByText('Action taken')).toBeNull();
	}}
/>

<Story name="AnchoredToBell" args={{ unreadCount: 2 }}>
	{#snippet template(args)}
		<!-- Composition preview: the Topbar bell toggle positions the panel
		     under itself. The host owns open/close; the panel stays
		     presentational. -->
		<div
			style="
				min-height: 420px;
				padding: 24px;
				background: var(--ground);
				display: flex;
				justify-content: flex-end;
				align-items: flex-start;
			"
		>
			<div style="position: relative;">
				<button
					type="button"
					aria-label="Notifications"
					style="position: absolute; top: -12px; right: 4px; border: none; background: none; color: var(--text-2); cursor: pointer;"
					><Bell size={18} stroke-width={1.8} /></button
				>
				<div style="padding-top: 28px;">
					<NotificationPanel
						notifications={[
							makeItem({
								id: 'n-b1',
								title: 'A leave request awaits your review',
								body: 'Amara Diallo requested 5 days of leave starting Monday.',
								actions: [{ key: 'approve', label: 'Approve', variant: 'primary' }]
							})
						]}
						unreadCount={args.unreadCount}
						onclose={args.onclose}
					/>
				</div>
			</div>
		</div>
	{/snippet}
</Story>
