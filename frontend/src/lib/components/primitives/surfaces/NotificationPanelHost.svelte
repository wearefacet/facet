<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import NotificationPanel from './NotificationPanel.svelte';
	import type { NotificationItem } from './NotificationPanel.svelte';
	import {
		isNotificationPanelOpen,
		getNotificationItems,
		getUnreadCount,
		hasMoreNotifications,
		closeNotificationPanel,
		loadMoreNotifications,
		markNotificationRead,
		markAllNotificationsRead,
		fireNotificationAction
	} from '$lib/notifications.svelte';

	let {
		onnavigate,
		ondownload
	}: {
		/** Called after the row is closed and marked read; the host keeps the
		 *  store free of SvelteKit, so the navigation is the caller's job. */
		onnavigate: (item: NotificationItem) => Promise<void> | void;
		/** Called after a download row is closed and marked read; the caller
		 *  owns the browser side of the download (the backend answers with an
		 *  attachment, so the page stays). */
		ondownload?: (item: NotificationItem) => Promise<void> | void;
	} = $props();

	// The store owns data + open state; the host owns the fixed positioning
	// and the open flow: close, mark read, then hand over to navigation.
	async function handleOpen(item: NotificationItem): Promise<void> {
		closeNotificationPanel();
		await markNotificationRead(item);
		await onnavigate(item);
	}

	// The download flow mirrors the open flow: the click consumes the row
	// (close + mark read) before the caller triggers the download.
	async function handleDownload(item: NotificationItem): Promise<void> {
		closeNotificationPanel();
		await markNotificationRead(item);
		await ondownload?.(item);
	}
</script>

{#if isNotificationPanelOpen()}
	<!-- Anchored to the Topbar bell (the `top` grid row is 56px tall).
		Fixed positioning keeps the panel out of AppShell's
		overflow:hidden main area. -->
	<div style="position: fixed; top: 64px; right: 18px; z-index: 60;">
		<NotificationPanel
			notifications={getNotificationItems()}
			more={hasMoreNotifications()}
			unreadCount={getUnreadCount()}
			onaction={fireNotificationAction}
			ondownload={handleDownload}
			onopen={handleOpen}
			onmarkallread={markAllNotificationsRead}
			onclose={closeNotificationPanel}
			onloadmore={loadMoreNotifications}
		/>
	</div>
{/if}
