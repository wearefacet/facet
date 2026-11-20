<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	RoleMemberRow — one row in a role-membership list, shared by the
	assignments page (both modes) and the role members page.

	Left side: primary label plus a secondary line — either a description
	(role documents) or an `email · id` pair (account documents). Right side:
	optional status badge, optional `default` tag, and the remove action.
-->
<script lang="ts">
	import RowItem from '$lib/components/primitives/data/RowItem.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import { X } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		title,
		email,
		metaId,
		description,
		status,
		isDefault = false,
		defaultTitle = m.admin_default_role_aria(),
		removable = true,
		removing = false,
		disabled = false,
		removeTitle,
		onremove
	}: {
		/** Primary label (account display name, email, or role name). */
		title: string;
		/** Email shown before the id on the secondary line (account rows). */
		email?: string;
		/** Mono document id at the end of the secondary line (account rows). */
		metaId?: string;
		/** Description line (role rows). Replaces the `email · id` pair. */
		description?: string;
		/** Account status — renders the status badge when present. */
		status?: string;
		/** Render the `default` tag. */
		isDefault?: boolean;
		/** Tooltip on the default tag. */
		defaultTitle?: string;
		/** Show the remove action. `false` renders the row read-only — for
		 *  surfaces where the viewer holds read but not the remove action. */
		removable?: boolean;
		/** True while this row's remove action is in flight. */
		removing?: boolean;
		/** Disable the remove button (another action is running). */
		disabled?: boolean;
		/** Tooltip on the remove button. */
		removeTitle?: string;
		/** Called when the remove button is clicked. */
		onremove: () => void;
	} = $props();

	function statusBadge(s?: string): { label: string; cls: string } {
		if (s === 'suspended') return { label: 'suspended', cls: 'badge-warn' };
		if (s === 'disabled') return { label: 'disabled', cls: 'badge-danger' };
		return { label: 'active', cls: 'badge-ok' };
	}

	const badge = $derived(statusBadge(status));
</script>

<RowItem>
	<div class="member-meta">
		<span class="member-name">{title}</span>
		{#if description}
			<span class="member-sub">{description}</span>
		{:else if email || metaId}
			<span class="member-sub">
				{#if email}{email} ·
				{/if}{#if metaId}<span class="member-id">{metaId}</span>{/if}
			</span>
		{/if}
	</div>
	{#if status}
		<span class="badge {badge.cls}">{badge.label}</span>
	{/if}
	{#if isDefault}
		<span class="default-tag" title={defaultTitle}>{m.admin_default_tag()}</span>
	{/if}
	{#if removable}
		<div class="actions">
			<Button variant="ghost" size="sm" {disabled} onclick={onremove} title={removeTitle}>
				{#snippet iconLeft()}
					<X size={13} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{removing ? m.admin_member_removing() : m.common_remove()}
			</Button>
		</div>
	{/if}
</RowItem>

<style>
	.member-meta {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
		flex: 1 1 auto;
	}

	.member-name {
		font-size: 14px;
		font-weight: 600;
		color: var(--text);
	}

	.member-sub {
		font-size: 11.5px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.member-id {
		opacity: 0.85;
	}

	.badge {
		margin-left: auto;
		padding: 2px 9px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		text-transform: lowercase;
		flex: none;
	}

	.badge-ok {
		background: var(--ok-weak);
		color: var(--ok);
	}

	.badge-warn {
		background: var(--warn-weak);
		color: var(--warn);
	}

	.badge-danger {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.default-tag {
		padding: 2px 8px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		background: var(--accent-weak, rgba(0, 0, 0, 0.04));
		color: var(--accent-ink, var(--text));
		flex: none;
	}

	.actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
	}
</style>
