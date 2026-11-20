<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import NavPanel from './NavPanel.svelte';
	import Topbar from './Topbar.svelte';
	import BuilderModeBar from '../../features/builder/BuilderModeBar.svelte';
	import BuilderSidebar from '../../features/builder/BuilderSidebar.svelte';
	import type { Crumb } from './Topbar.svelte';
	import type { NavDomain } from '$lib/navTypes';
	import type { IdentityProps } from './IdentityProps.js';
	import type { DataDriver } from '$lib/datasource/driver.js';

	let {
		/** Rail collapse state (two-way bindable). */
		collapsed = $bindable(false),
		/** Forwarded to `NavPanel`. */
		domains,
		activeDomainId = $bindable(''),
		activeDoctype,
		/** Identity block (account, activeRole, availableRoles, connectivity, onSwitchRole) forwarded to the shells. */
		account = undefined,
		activeRole = undefined,
		availableRoles = [] as string[],
		connectivity = undefined as string[] | undefined,
		onSwitchRole = async (_role: string) => {},
		/** Forwarded to `Topbar`. */
		crumbs = [],
		searchPlaceholder,
		onsearch,
		/** Forwarded to `Topbar` — hides the search trigger while the app has
		 * no global search surface. */
		showSearch = true,
		assistantLabel,
		/** Whether the workspace assistant is available to this account
		 * (`me.assistant.access`). Gates the top-bar toggle; builder mode
		 * keeps its own assistant toggle (`ontoggleassistant`). */
		assistantAvailable = false,
		/** Whether the notifications bell renders. Forwards to `Topbar`; the
		 * layout passes the account's in-app notification preference. */
		showNotifications = true,
		notificationsCount,
		onnotifications,
		/** Collapse toggle callback (fires in addition to updating `collapsed`). */
		ontoggle,
		/** When true, renders the `BuilderModeBar` above the topbar. */
		builderMode = false,
		/** Status line for the `BuilderModeBar`. */
		builderMessage = undefined,
		/** Called when the user clicks Exit on the `BuilderModeBar`. */
		onexitbuilder = () => {},
		/** Draft display name forwarded to BuilderModeBar's chip. */
		builderDraftName = undefined,
		/** Whether the active draft is editable (Publish/Discard are draft-only). */
		builderIsDraft = false,
		/** Whether the builder is currently in preview mode (URL-derived). */
		builderIsPreview = false,
		/** Open issue count forwarded to BuilderModeBar's Publish pill. */
		builderCheckIssueCount = 0,
		/** Called when the user clicks the Build segment of the segmented toggle. */
		onselectbuild = () => {},
		/** Called when the user clicks the Preview segment of the segmented toggle. */
		onselectpreview = () => {},
		/** Called when the user clicks Publish in the top bar. */
		onpublish = () => {},
		/** Called when the user clicks Discard in the top bar. */
		ondiscard = () => {},
		/** Called when the user toggles the assistant. Builder mode wires it
		 * to the floating window (via `BuilderModeBar`); everywhere else it
		 * drives the workspace dock through the top-bar toggle, which only
		 * renders when `assistantAvailable` is true. */
		ontoggleassistant = () => {},
		/** Live domains for the EditDomainDialog — forwarded to NavPanel. */
		liveDomains = [],
		/** Creates a new empty draft with a chosen id + label; returns null on success or an error message. */
		onnewdomain = (_input: { name: string; label?: string }) =>
			Promise.resolve(null as string | null),
		/** Called when the user drafts from a live domain (Edit existing). */
		oneditdomain = (_domainId: string) => {},
		/** Error to surface inside the EditDomainDialog (e.g. 409). */
		editError = undefined,
		/** Override the entire rail. Defaults to `<NavPanel>`. */
		sidebar,
		/** Override the topbar. Defaults to `<Topbar>`. */
		topbar,
		/** Drives the BuilderModeBar's toggle-button active state. The floating
		    assistant itself is mounted at the root +layout.svelte, not here,
		    because it is position:fixed and not part of the AppShell grid. */
		assistantOpen = false,
		/** Called when the user toggles a doctype's pinned state. */
		onpin = (_qualified: string) => {},
		/** Driver forwarded to `NavPanel` for lazy per-doctype count fetches. */
		driver = undefined,
		children
	}: {
		collapsed?: boolean;
		domains?: NavDomain[];
		activeDomainId?: string;
		activeDoctype?: string;
		crumbs?: Crumb[];
		searchPlaceholder?: string;
		onsearch?: () => void;
		showSearch?: boolean;
		assistantLabel?: string;
		assistantAvailable?: boolean;
		showNotifications?: boolean;
		notificationsCount?: number;
		onnotifications?: () => void;
		ontoggle?: (collapsed: boolean) => void;
		builderMode?: boolean;
		builderMessage?: string;
		onexitbuilder?: () => void;
		builderDraftName?: string;
		builderIsDraft?: boolean;
		builderIsPreview?: boolean;
		builderCheckIssueCount?: number;
		onselectbuild?: () => void;
		onselectpreview?: () => void;
		onpublish?: () => void;
		ondiscard?: () => void;
		ontoggleassistant?: () => void;
		/** Live domains for the EditDomainDialog — forwarded to NavPanel. */
		liveDomains?: NavDomain[];
		/** Creates a new empty draft with a chosen id + label; returns null on success or an error message. */
		onnewdomain?: (input: { name: string; label?: string }) => Promise<string | null>;
		/** Called when the user drafts from a live domain (Edit existing). */
		oneditdomain?: (domainId: string) => void;
		/** Error to surface inside the EditDomainDialog (e.g. 409). */
		editError?: string | undefined;
		sidebar?: import('svelte').Snippet;
		topbar?: import('svelte').Snippet;
		assistantOpen?: boolean;
		/** Called when the user toggles a doctype's pinned state. */
		onpin?: (qualified: string) => void;
		/** Driver forwarded to `NavPanel` for lazy per-doctype count fetches. */
		driver?: DataDriver;
		children?: import('svelte').Snippet;
	} & IdentityProps = $props();

	function handleToggle() {
		collapsed = !collapsed;
		ontoggle?.(collapsed);
	}
</script>

<div class="app" class:rail-collapsed={collapsed}>
	{#if sidebar}
		{@render sidebar?.()}
	{:else if builderMode}
		<!-- Builder mode sidebar — handles both the landing gallery
			(/Builder) and the draft-scoped nav (/Builder/[draft]/*). -->
		<BuilderSidebar
			{collapsed}
			ontoggle={handleToggle}
			{domains}
			{activeDomainId}
			{activeDoctype}
			{account}
			{activeRole}
			{availableRoles}
			{onSwitchRole}
			{onexitbuilder}
			{liveDomains}
			{onnewdomain}
			{oneditdomain}
			{editError}
		/>
	{:else}
		<NavPanel
			{collapsed}
			ontoggle={handleToggle}
			{domains}
			bind:activeDomainId
			{activeDoctype}
			{account}
			{activeRole}
			{availableRoles}
			{connectivity}
			{onSwitchRole}
			{onpin}
			{driver}
		/>
	{/if}

	{#if topbar}
		{@render topbar()}
	{:else}
		{#if builderMode}
			<BuilderModeBar
				message={builderMessage ?? m.builder_status_live()}
				draftName={builderDraftName}
				isDraft={builderIsDraft}
				canPublish={builderIsDraft}
				isPreview={builderIsPreview}
				checkIssueCount={builderCheckIssueCount}
				{onselectbuild}
				{onselectpreview}
				{onpublish}
				{ondiscard}
				onexit={onexitbuilder}
				{assistantOpen}
				{ontoggleassistant}
				{assistantLabel}
			/>
		{:else}
			<Topbar
				{crumbs}
				{searchPlaceholder}
				{onsearch}
				{showSearch}
				{assistantLabel}
				showAssistant={assistantAvailable}
				{assistantOpen}
				onassistant={ontoggleassistant}
				{showNotifications}
				{notificationsCount}
				{onnotifications}
			/>
		{/if}
	{/if}

	<main class="main">
		{@render children?.()}
	</main>
</div>

<style>
	.app {
		display: grid;
		height: 100vh;
		overflow: hidden;
		grid-template-columns: 252px minmax(0, 1fr);
		grid-template-rows: auto minmax(0, 1fr);
		grid-template-areas: 'side top' 'side main';
		transition: grid-template-columns 0.2s ease;
	}

	.app.rail-collapsed {
		grid-template-columns: 60px minmax(0, 1fr);
	}

	.main {
		grid-area: main;
		overflow: auto;
		min-width: 0;
		min-height: 0;
		position: relative;
	}
</style>
