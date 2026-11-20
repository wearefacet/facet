<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Bell, CheckCheck } from '@lucide/svelte';
	import IconButton from '../actions/IconButton.svelte';
	import Button from '../actions/Button.svelte';
	import RelativeTime from '../data/RelativeTime.svelte';
	import { resolveDoctypeIcon, DOCTYPE_ICON_CATALOG } from '$lib/doctype/doctype-icons';
	import { notificationDownloadUrl } from '$lib/notificationDownload.js';

	/** One action descriptor from the notification's `actions` array. */
	export interface NotificationActionDescriptor {
		key: string;
		label: string;
		/** Visual hint from the producer ("primary", "danger", …). */
		variant?: string;
		/** Confirmation prompt the host should show before firing. */
		confirm?: string;
	}

	/** One row of `GET /Api/notifications` (`data[]` shape). */
	export interface NotificationItem {
		id: string;
		domain: string;
		doc_type: string;
		doc_id: string;
		kind: string;
		icon?: string | null;
		title: string;
		body: string;
		/** Structured context from the producer. The reserved `download` key
		 *  (a same-origin path — see `notificationDownloadUrl`) renders a
		 *  Download affordance instead of the source-document navigation. */
		data?: Record<string, unknown>;
		actions: NotificationActionDescriptor[];
		read_at: string | null;
		/** Set once any action has fired — every action on the item is dead. */
		actioned_at: string | null;
		created_at: string;
	}

	type ButtonVariant = 'primary' | 'secondary' | 'danger' | 'ghost';

	let {
		notifications = [] as NotificationItem[],
		more = false,
		unreadCount = 0,
		onaction,
		ondownload,
		onopen,
		onmarkallread,
		onclose,
		onloadmore
	}: {
		/** Newest-first page from `GET /Api/notifications`. */
		notifications?: NotificationItem[];
		/** Whether `GET /Api/notifications` reported a next page (`meta.more`). */
		more?: boolean;
		/** Unread count for the header badge (`GET /Api/notifications/unread_count`). */
		unreadCount?: number;
		/** The user fired one action. The host confirms (`confirm`), calls the route, then updates the item's `actioned_at`. */
		onaction?: (item: NotificationItem, action: NotificationActionDescriptor) => void;
		/** The user asked for the notification's file download (`data.download`).
		 *  Not a doctype action — `actioned_at` never gates or consumes it. */
		ondownload?: (item: NotificationItem) => void;
		/** The user opened the notification's source document. */
		onopen?: (item: NotificationItem) => void;
		/** The user dismissed every unread notification. */
		onmarkallread?: () => void;
		/** The user closed the panel. */
		onclose?: () => void;
		/** The user asked for the next page. */
		onloadmore?: () => void;
	} = $props();

	// A fired action is one-shot per notification: the first successful
	// invocation stamps `actioned_at` server-side and consumes every action,
	// so the buttons render disabled no matter which key was used.
	const isActioned = (item: NotificationItem) => item.actioned_at !== null;

	// Producer hints map onto the Button variants we actually render.
	const buttonVariant = (variant?: string): ButtonVariant =>
		variant === 'primary' ? 'primary' : variant === 'danger' ? 'danger' : 'secondary';

	// Notification icons are free-form names; reuse the doctype Lucide
	// catalog when the name resolves, with a Bell fallback when it does not.
	const resolveIcon = (name?: string | null) =>
		name && DOCTYPE_ICON_CATALOG.has(name) ? resolveDoctypeIcon(name) : Bell;
</script>

<section class="notif-panel" aria-label={m.nav_notifications()}>
	<header class="notif-head">
		<span class="notif-title">{m.nav_notifications()}</span>
		{#if unreadCount > 0}
			<span class="notif-badge" aria-label={m.nav_unread_aria({ count: unreadCount })}
				>{unreadCount}</span
			>
		{/if}
		<span class="notif-head-spacer"></span>
		{#if unreadCount > 0}
			<Button variant="ghost" size="sm" onclick={onmarkallread}>{m.nav_mark_all_read()}</Button>
		{/if}
		<IconButton label={m.nav_close_notifications()} onclick={onclose}>
			<span class="notif-x" aria-hidden="true">×</span>
		</IconButton>
	</header>

	{#if notifications.length === 0}
		<div class="notif-empty">
			<span class="notif-empty-icon" aria-hidden="true"><CheckCheck size={18} /></span>
			<span class="notif-empty-title">{m.nav_notifications_empty()}</span>
			<span class="notif-empty-sub">{m.nav_notifications_empty_helper()}</span>
		</div>
	{:else}
		<ul class="notif-list" role="list">
			{#each notifications as item (item.id)}
				{@const Icon = resolveIcon(item.icon)}
				{@const downloadHref = notificationDownloadUrl(item)}
				<li
					class="notif-item"
					class:unread={item.read_at === null}
					class:actioned={isActioned(item)}
				>
					<button
						class="notif-main"
						type="button"
						onclick={() => onopen?.(item)}
						aria-label={downloadHref
							? m.nav_download_notification_aria({ title: item.title })
							: m.nav_open_notification_aria({ title: item.title })}
					>
						<span class="notif-disc" class:unread={item.read_at === null} aria-hidden="true">
							<Icon size={14} />
							{#if item.read_at === null}<span class="notif-dot"></span>{/if}
						</span>
						<span class="notif-main-text">
							<span class="notif-item-title">{item.title}</span>
							{#if item.body}
								<span class="notif-item-body">{item.body}</span>
							{/if}
						</span>
						<span class="notif-time">
							<RelativeTime date={item.created_at} />
						</span>
					</button>
					{#if item.actions.length > 0 || downloadHref}
						<div class="notif-actions">
							{#each item.actions as action (action.key)}
								<Button
									size="sm"
									variant={buttonVariant(action.variant)}
									disabled={isActioned(item)}
									onclick={() => onaction?.(item, action)}
								>
									{action.label}
								</Button>
							{/each}
							{#if downloadHref}
								<Button
									size="sm"
									variant="secondary"
									onclick={() => ondownload?.(item)}
									label={m.impex_download()}
								/>
							{/if}
							{#if isActioned(item)}
								<span class="notif-done" aria-hidden="true">
									<CheckCheck size={13} />
									{m.nav_action_taken()}
								</span>
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>
		{#if more}
			<button class="notif-more" type="button" onclick={onloadmore}>{m.nav_load_more()}</button>
		{/if}
	{/if}
</section>

<style>
	/* ── Panel — anchored popover surface for the Topbar bell ───────────── */
	.notif-panel {
		width: 384px;
		max-width: 100%;
		max-height: 480px;
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-2);
		overflow: hidden;
	}

	/* ── Header ─────────────────────────────────────────────────────────── */
	.notif-head {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 10px 10px 10px 16px;
		border-bottom: 1px solid var(--border);
		flex-shrink: 0;
	}

	.notif-title {
		font-family: var(--font-display);
		font-size: 14px;
		font-weight: 600;
		color: var(--text);
	}

	.notif-badge {
		font-family: var(--font-mono);
		font-size: 11px;
		line-height: 1;
		padding: 3px 7px;
		border-radius: var(--r-pill);
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.notif-head-spacer {
		flex: 1;
	}

	.notif-x {
		font-size: 18px;
		line-height: 1;
	}

	/* ── List ───────────────────────────────────────────────────────────── */
	.notif-list {
		list-style: none;
		margin: 0;
		padding: 0;
		overflow-y: auto;
	}

	.notif-item {
		border-bottom: 1px solid var(--border);
		padding: 6px 8px;
	}

	.notif-item:last-child {
		border-bottom: none;
	}

	.notif-item.actioned {
		background: var(--sunken);
	}

	/* The item body is one big click target that opens the source document;
	   the action row sits outside it so buttons never nest. */
	.notif-main {
		display: flex;
		align-items: flex-start;
		gap: 10px;
		width: 100%;
		padding: 6px;
		border: none;
		background: none;
		font: inherit;
		text-align: left;
		cursor: pointer;
		border-radius: var(--r);
	}

	.notif-main:hover {
		background: var(--surface-2);
	}

	.notif-main:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -1px;
	}

	/* ── Icon disc + unread dot ─────────────────────────────────────────── */
	.notif-disc {
		position: relative;
		width: 28px;
		height: 28px;
		border-radius: var(--r);
		display: inline-flex;
		align-items: center;
		justify-content: center;
		flex-shrink: 0;
		background: var(--sunken);
		color: var(--text-2);
	}

	.notif-dot {
		position: absolute;
		top: -1px;
		right: -1px;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--accent);
	}

	/* ── Text ───────────────────────────────────────────────────────────── */
	.notif-main-text {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.notif-item-title {
		font-size: 13px;
		font-weight: 500;
		color: var(--text-2);
		line-height: 1.4;
	}

	.notif-item.unread .notif-item-title {
		color: var(--text);
		font-weight: 600;
	}

	.notif-item-body {
		font-size: 12px;
		color: var(--text-2);
		line-height: 1.45;
		overflow: hidden;
		display: -webkit-box;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		-webkit-box-orient: vertical;
	}

	.notif-time {
		flex-shrink: 0;
		margin-top: 2px;
		display: inline-flex;
	}

	/* ── Actions ────────────────────────────────────────────────────────── */
	.notif-actions {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 2px 6px 6px 44px;
		flex-wrap: wrap;
	}

	.notif-done {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	/* ── Empty state ────────────────────────────────────────────────────── */
	.notif-empty {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 4px;
		padding: 44px 24px;
		text-align: center;
	}

	.notif-empty-icon {
		width: 40px;
		height: 40px;
		border-radius: var(--r-lg);
		background: var(--sunken);
		color: var(--text-3);
		display: inline-flex;
		align-items: center;
		justify-content: center;
		margin-bottom: 6px;
	}

	.notif-empty-title {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
	}

	.notif-empty-sub {
		font-size: 12px;
		color: var(--text-3);
	}

	/* ── Footer ─────────────────────────────────────────────────────────── */
	.notif-more {
		flex-shrink: 0;
		border: none;
		border-top: 1px solid var(--border);
		background: none;
		width: 100%;
		padding: 10px;
		font-family: var(--font-sans);
		font-size: 12px;
		font-weight: 600;
		color: var(--accent-ink);
		cursor: pointer;
	}

	.notif-more:hover {
		background: var(--surface-2);
	}

	.notif-more:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}
</style>
