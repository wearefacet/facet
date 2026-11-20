<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import NavPanel from './NavPanel.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/NavPanel',
		component: NavPanel,
		tags: ['autodocs'],
		argTypes: {
			domains: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import NavPanelInner from './NavPanel.svelte';
	import type { NavDomain } from '$lib/navTypes';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { buildNavModel } from '$lib/navModel';
	import { setPermissions } from '$lib/permissions.svelte';

	// A fresh driver per story mount — keeps stories isolated and avoids
	// importing the singleton from `.storybook/preview.ts` (which lives
	// outside `src/` and is brittle to reach via relative paths).
	const driver = createMockDriver();

	// The stories render `activeRole="Administrator"`; grant the admin wildcard
	// so the Configure button (gated on `can('core.DocType', 'update')`) is
	// visible and the visual mockup matches production for an admin user.
	// `CanFixture` is not used because the full NavPanel composes `SidebarShell`
	// (which reads the global role/permissions stores directly), so the store
	// must be hydrated at mount.
	setPermissions({ '*.*': ['*'] });

	let navModel = $state<NavDomain[]>([]);
	let loaded = $state(false);

	$effect(() => {
		(async () => {
			navModel = await buildNavModel(driver);
			loaded = true;
		})();
	});

	// Pinned stand-in: the first doctype of the first domain.
	const pinnedDoctype = $derived(navModel[0]?.doctypes[0]?.qualified);

	// Two-way-bound active domain selection — mirrors what a host app would own.
	let activeDomainId = $state('');

	// Sample model for the Mockup story. The story owns the mockup content —
	// the production component has no static branch. Story sample props stay
	// literal; component chrome comes from the message catalogue.
	const mockDomains: NavDomain[] = [
		{
			id: 'logistics',
			label: 'Logistics Ops',
			color: 'var(--dt-shipment)',
			doctypes: [
				{ qualified: 'logistics.Shipment', label: 'Shipment', color: 'var(--dt-shipment)' },
				{ qualified: 'logistics.Carrier', label: 'Carrier', color: 'var(--dt-shipment)' },
				{ qualified: 'logistics.Warehouse', label: 'Warehouse', color: 'var(--dt-shipment)' },
				{ qualified: 'logistics.Route', label: 'Route', color: 'var(--dt-shipment)' },
				{ qualified: 'logistics.Inventory', label: 'Inventory', color: 'var(--dt-shipment)' },
				{
					qualified: 'logistics.Order',
					label: 'Order',
					color: 'var(--dt-shipment)',
					children: [
						{
							qualified: 'logistics.OrderLine',
							label: 'OrderLine',
							color: 'var(--dt-shipment)'
						},
						{
							qualified: 'logistics.OrderNote',
							label: 'OrderNote',
							color: 'var(--dt-shipment)'
						}
					]
				}
			]
		}
	];
</script>

<Story
	name="Default"
	args={{ collapsed: false }}
	play={async ({ canvasElement }) => {
		// Doctype marks render the configured Lucide icon (not the diamond).
		const canvas = within(canvasElement);
		const navBtns = await canvas.findAllByRole('link');
		await expect(navBtns.length).toBeGreaterThan(0);
		await expect(canvasElement.querySelector('.doctype-icon-glyph svg')).not.toBeNull();

		// Lazy count regression: each doctype badge starts at `—` and flips
		// to a number once `loadForDomain` resolves for the active domain.
		// We poll the `.ct` badge spans (excluding the static `admin` chip on
		// the Configure button) until at least one shows a digit. A stuck `—`
		// is exactly the bug introduced by the lazy-count refactor.
		const start = Date.now();
		let digits = 0;
		while (Date.now() - start < 2500) {
			const badges = canvasElement.querySelectorAll('.nav-btn .ct');
			digits = [...badges].filter((b) => /\d/.test((b.textContent ?? '').trim())).length;
			if (digits > 0) break;
			await new Promise((r) => setTimeout(r, 50));
		}
		await expect(digits).toBeGreaterThan(0);
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="position:relative;width:260px;height:90vh;min-height:600px;overflow:hidden">
				<NavPanelInner
					collapsed={args.collapsed}
					domains={navModel}
					{driver}
					bind:activeDomainId
					activeDoctype={pinnedDoctype}
					account={{ id: 'u1', display_name: 'Yacine A.' }}
					activeRole="Administrator"
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading domains…</p>
		{/if}
	{/snippet}
</Story>

<!-- The avatar+name is a DropdownMenu trigger. The portalled menu content is
     not asserted via `play` (portalled content is flaky across iframes per the
     frontend workflow); the trigger button and its accessible name are the
     stable contract. `findByRole` waits for the async nav-model load to settle
     before asserting. -->
<Story
	name="ProfileMenuTrigger"
	args={{ collapsed: false }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The trigger is a button labelled with the user's display name. The nav
		// model hydrates asynchronously, so use the async query.
		const trigger = await canvas.findByRole('button', { name: /Yacine A/ });
		await expect(trigger).toBeVisible();
	}}
>
	{#snippet template(args)}
		{#if loaded}
			<div style="position:relative;width:260px;height:90vh;min-height:600px;overflow:hidden">
				<NavPanelInner
					collapsed={args.collapsed}
					domains={navModel}
					{driver}
					bind:activeDomainId
					activeDoctype={pinnedDoctype}
					account={{ id: 'u1', display_name: 'Yacine A.' }}
					activeRole="Administrator"
				/>
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading domains…</p>
		{/if}
	{/snippet}
</Story>

<Story name="Collapsed" args={{ collapsed: true }}>
	{#snippet template(args)}
		{#if loaded}
			<div style="position:relative;width:64px;height:90vh;min-height:600px;overflow:hidden">
				<NavPanelInner collapsed={args.collapsed} domains={navModel} {driver} bind:activeDomainId />
			</div>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<!-- Static mockup — sample domain data, no driver. The story renders the
     mockup content; the production component does not carry it. -->
<Story name="Mockup" args={{ collapsed: false }}>
	{#snippet template(args)}
		<div style="position:relative;width:260px;height:90vh;min-height:600px;overflow:hidden">
			<NavPanelInner collapsed={args.collapsed} domains={mockDomains} />
		</div>
	{/snippet}
</Story>

<!-- Composition children nest under their parent as an expandable tree.
     Subtrees start expanded; the caret collapses a branch. The play function
     walks one collapse/expand cycle on the Order subtree. -->
<Story
	name="DoctypeTree"
	args={{ collapsed: false }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The child row renders under its parent without any interaction.
		const orderLine = await canvas.findByRole('link', { name: 'OrderLine' });
		await expect(orderLine).toBeVisible();

		// The parent's caret reports the expanded state.
		const caret = canvas.getByRole('button', { name: m.nav_tree_collapse() });
		await expect(caret).toHaveAttribute('aria-expanded', 'true');

		// Collapse: the child rows leave the tree, the caret flips.
		await userEvent.click(caret);
		await expect(canvas.queryByRole('link', { name: 'OrderLine' })).toBeNull();
		await expect(caret).toHaveAttribute('aria-expanded', 'false');

		// Re-expand: the subtree comes back.
		await userEvent.click(canvas.getByRole('button', { name: m.nav_tree_expand() }));
		await expect(canvas.getByRole('link', { name: 'OrderLine' })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="position:relative;width:260px;height:90vh;min-height:600px;overflow:hidden">
			<NavPanelInner collapsed={args.collapsed} domains={mockDomains} />
		</div>
	{/snippet}
</Story>
