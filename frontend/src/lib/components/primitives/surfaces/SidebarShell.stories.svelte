<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import SidebarShell from './SidebarShell.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/SidebarShell',
		component: SidebarShell,
		tags: ['autodocs']
	});

	// Collapse spy — one slot, reset at the top of each play.
	let lastToggle: boolean | undefined = undefined;
	const ontoggle = (collapsed: boolean) => {
		lastToggle = collapsed;
	};

	const account = { id: 'acc_42', display_name: 'Ada Lovelace' };
	const roles = ['iam.Roles.production_editor', 'iam.Roles.admin'];
</script>

<Story
	name="Default"
	args={{ collapsed: false, title: 'Facet', subtitle: 'HR workspace' }}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Facet')).toBeVisible();
		await expect(canvas.getByText('HR workspace')).toBeVisible();
		await expect(canvas.getByText('Ada Lovelace')).toBeVisible();
		// Role ids humanize in the footer (`iam.Roles.production_editor` →
		// 'Production Editor').
		await expect(canvas.getByText('Production Editor')).toBeVisible();
		// The collapse toggle reports the requested rail state.
		await userEvent.click(canvas.getByRole('button', { name: 'Collapse sidebar' }));
		await expect(lastToggle).toBe(true);
	}}
>
	{#snippet template(args)}
		<div class="shell-frame">
			<SidebarShell
				collapsed={args.collapsed}
				{ontoggle}
				title={args.title}
				subtitle={args.subtitle}
				{account}
				activeRole="iam.Roles.production_editor"
				availableRoles={roles}
			>
				{#snippet nav()}
					{#if !args.collapsed}
						<nav class="nav-demo">
							<a href="#domains">Domains</a>
							<a href="#invoices">Invoices</a>
							<a href="#shipments">Shipments</a>
						</nav>
					{/if}
				{/snippet}
			</SidebarShell>
		</div>
	{/snippet}
</Story>

<Story
	name="Collapsed"
	args={{ collapsed: true, title: 'Facet', subtitle: 'HR workspace' }}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		// The collapsed rail hides the brand text and the account block but
		// keeps the expand control reachable.
		await expect(canvas.getByText('Facet')).not.toBeVisible();
		await expect(canvas.getByText('Ada Lovelace')).not.toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Expand sidebar' }));
		await expect(lastToggle).toBe(false);
	}}
>
	{#snippet template(args)}
		<div class="shell-frame">
			<SidebarShell
				collapsed={args.collapsed}
				{ontoggle}
				title={args.title}
				subtitle={args.subtitle}
				{account}
				activeRole="iam.Roles.production_editor"
				availableRoles={roles}
			>
				{#snippet nav()}
					{#if !args.collapsed}
						<nav class="nav-demo">
							<a href="#domains">Domains</a>
						</nav>
					{/if}
				{/snippet}
			</SidebarShell>
		</div>
	{/snippet}
</Story>

<Story
	name="NoAccount"
	args={{ collapsed: false, title: 'Facet' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No session row — the footer degrades to the administrator label.
		await expect(canvas.getByText('Administrator')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="shell-frame">
			<SidebarShell collapsed={args.collapsed} {ontoggle} title={args.title}>
				{#snippet nav()}
					<nav class="nav-demo">
						<a href="#domains">Domains</a>
					</nav>
				{/snippet}
			</SidebarShell>
		</div>
	{/snippet}
</Story>

<!-- Lockup brand — the app navbar treatment: the wordmark is baked into the
		 image, so no brand text renders and the alt carries the name. -->

<Story
	name="Lockup brand"
	args={{ collapsed: false, title: 'Facet' }}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		// The name lives in the image: no brand text anywhere in the shell.
		await expect(canvas.queryByText('Facet')).toBeNull();
		// Both theme variants render; CSS shows exactly one.
		const marks = canvas.getAllByAltText('Facet');
		await expect(marks.length).toBe(2);
		await expect(canvas.getByText('Ada Lovelace')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="shell-frame">
			<SidebarShell
				collapsed={args.collapsed}
				{ontoggle}
				variant="lockup"
				title={args.title}
				{account}
				activeRole="iam.Roles.production_editor"
				availableRoles={roles}
			>
				{#snippet nav()}
					{#if !args.collapsed}
						<nav class="nav-demo">
							<a href="#domains">Domains</a>
							<a href="#invoices">Invoices</a>
							<a href="#shipments">Shipments</a>
						</nav>
					{/if}
				{/snippet}
			</SidebarShell>
		</div>
	{/snippet}
</Story>

<Story
	name="Lockup brand — collapsed"
	args={{ collapsed: true, title: 'Facet' }}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		// The collapsed rail hides the whole brand row, lockup included.
		const marks = canvas.getAllByAltText('Facet');
		for (const mark of marks) {
			await expect(mark).not.toBeVisible();
		}
		await userEvent.click(canvas.getByRole('button', { name: 'Expand sidebar' }));
		await expect(lastToggle).toBe(false);
	}}
>
	{#snippet template(args)}
		<div class="shell-frame">
			<SidebarShell
				collapsed={args.collapsed}
				{ontoggle}
				variant="lockup"
				title={args.title}
				{account}
				activeRole="iam.Roles.production_editor"
				availableRoles={roles}
			>
				{#snippet nav()}
					{#if !args.collapsed}
						<nav class="nav-demo">
							<a href="#domains">Domains</a>
						</nav>
					{/if}
				{/snippet}
			</SidebarShell>
		</div>
	{/snippet}
</Story>

<style>
	.shell-frame {
		display: flex;
		height: 480px;
		max-width: 280px;
		margin: 24px;
		background: var(--ground);
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}

	.nav-demo {
		display: flex;
		flex-direction: column;
		gap: 2px;
		padding: 12px;
		font-size: 13px;
	}

	.nav-demo a {
		padding: 6px 8px;
		border-radius: var(--r-sm);
		color: var(--text-2);
		text-decoration: none;
	}

	.nav-demo a:hover {
		background: var(--sunken);
		color: var(--text);
	}
</style>
