<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	NoRoleScreen — full-screen notice for an authenticated account that holds
	no assigned role.

	The backend lets a roleless account connect under `iam.Roles.anonymous`
	(B-120), so `/Api/iam/me` succeeds with `available_roles: []`. The normal
	app shell would render an empty, unusable workspace; this surface tells
	the user to ask IT for access and offers a refresh that re-runs the layout
	load (an operator may have granted a role in the meantime).
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { ShieldOff, RefreshCw } from '@lucide/svelte';
	import { logout } from '$lib/auth.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import AuthShell from './AuthShell.svelte';

	let { onrefresh }: { onrefresh?: () => void } = $props();
</script>

<!-- The screen owns the browser-tab title: without it, the title of the
     previous surface stays in the tab (F05-08). -->
<svelte:head>
	<title>{m.auth_no_role_page_title()}</title>
</svelte:head>

<AuthShell
	maxWidth={420}
	gap={20}
	title={m.auth_no_role_title()}
	sub={m.auth_no_role_sub()}
	iconTint="warn"
>
	{#snippet icon()}
		<ShieldOff size={22} />
	{/snippet}

	<div class="no-role-action">
		<Button variant="primary" size="lg" onclick={() => onrefresh?.()} iconLeft={RefreshIcon}>
			{m.auth_no_role_refresh()}
		</Button>
		<Button variant="ghost" size="lg" onclick={() => void logout()}>
			{m.nav_logout()}
		</Button>
	</div>
</AuthShell>

{#snippet RefreshIcon()}<RefreshCw size={15} />{/snippet}

<style>
	.no-role-action {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.no-role-action :global(.btn) {
		width: 100%;
	}
</style>
