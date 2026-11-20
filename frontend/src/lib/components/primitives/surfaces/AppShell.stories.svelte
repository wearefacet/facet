<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import AppShell from './AppShell.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/AppShell',
		component: AppShell,
		tags: ['autodocs'],
		argTypes: {
			collapsed: { control: 'boolean' },
			notificationsCount: { control: 'number' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import type { NavDomain } from '$lib/navTypes';
	import Panel from './Panel.svelte';
	import Capsule from '../data/Capsule.svelte';
	import Badge from '../data/Badge.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { buildNavModel } from '$lib/navModel';
	import type { Crumb } from './Topbar.svelte';

	// A fresh driver per story mount — keeps stories isolated.
	const driver = createMockDriver();

	let navModel = $state<NavDomain[]>([]);
	let loaded = $state(false);

	$effect(() => {
		(async () => {
			navModel = await buildNavModel(driver);
			loaded = true;
		})();
	});

	const crumbs: Crumb[] = [
		{ label: 'Logistics Ops', href: '#' },
		{ label: 'Invoices', href: '#' },
		{ label: 'Table' }
	];

	// A few dummy table rows so the workspace body has content.
	const rows = [
		{ id: 'INV-0486', vendor: 'Kuehne + Nagel', amount: '€ 28,900.00', status: 'disputed' },
		{ id: 'INV-0488', vendor: 'Maersk Line A/S', amount: '€ 12,480.00', status: 'warn' },
		{ id: 'INV-0484', vendor: 'DB Schenker', amount: '€ 7,775.00', status: 'muted' },
		{ id: 'INV-0479', vendor: 'CMA CGM', amount: '€ 19,330.00', status: 'warn' },
		{ id: 'INV-0471', vendor: 'Hapag-Lloyd', amount: '€ 4,210.00', status: 'warn' }
	];

	let activeDomainId = $state('');
	const activeDoctype = $derived(navModel[0]?.doctypes[0]?.qualified);
</script>

<Story name="Default" args={{ collapsed: false, notificationsCount: 3 }}>
	{#snippet template(args)}
		{#if loaded}
			<AppShell
				collapsed={args.collapsed}
				domains={navModel}
				{driver}
				bind:activeDomainId
				{activeDoctype}
				{crumbs}
				notificationsCount={args.notificationsCount}
			>
				<div class="ws">
					<div class="wshead">
						<h1>Invoices</h1>
						<span class="cnt">248 records</span>
						<span class="sp"></span>
						<button class="btn pri sm">New invoice</button>
					</div>
					<Panel padding={false}>
						<div class="table-scroll">
							<table>
								<thead>
									<tr>
										<th>Invoice</th>
										<th>Vendor</th>
										<th class="r">Amount</th>
										<th class="c">Status</th>
									</tr>
								</thead>
								<tbody>
									{#each rows as row (row.id)}
										<tr>
											<td><Capsule doctype="invoice" label={row.id} /></td>
											<td>{row.vendor}</td>
											<td class="r mono">{row.amount}</td>
											<td class="c">
												{#if row.status === 'disputed'}
													<Badge variant="danger">Disputed</Badge>
												{:else if row.status === 'warn'}
													<Badge variant="warn">Needs review</Badge>
												{:else}
													<Badge variant="neutral">Draft</Badge>
												{/if}
											</td>
										</tr>
									{/each}
								</tbody>
							</table>
						</div>
					</Panel>
				</div>
			</AppShell>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading domains…</p>
		{/if}
	{/snippet}
</Story>

<Story name="Collapsed Rail" args={{ collapsed: true, notificationsCount: 0 }}>
	{#snippet template(args)}
		{#if loaded}
			<AppShell
				collapsed={args.collapsed}
				domains={navModel}
				{driver}
				bind:activeDomainId
				{activeDoctype}
				{crumbs}
				notificationsCount={args.notificationsCount}
			>
				<div class="ws">
					<div class="wshead">
						<h1>Invoices</h1>
						<span class="cnt">248 records</span>
					</div>
					<Panel>
						<p style="color:var(--text-3);font-size:13px">Workspace content with collapsed rail.</p>
					</Panel>
				</div>
			</AppShell>
		{:else}
			<p style="padding:24px;color:var(--text-3);font-size:13px">Loading…</p>
		{/if}
	{/snippet}
</Story>

<Story name="Bare" args={{ collapsed: false }}>
	{#snippet template()}
		<!-- No `domains` prop — NavPanel falls back to its static mockup. -->
		<AppShell crumbs={[{ label: 'Facet', href: '#' }]} collapsed={false}>
			<div class="ws">
				<Panel>
					<p style="color:var(--text-3);font-size:13px;margin:0">
						Minimal skeleton — no driver data, static rail mockup.
					</p>
				</Panel>
			</div>
		</AppShell>
	{/snippet}
</Story>

<style>
	.ws {
		padding: 20px 22px;
		display: flex;
		flex-direction: column;
		gap: 14px;
		min-width: 0;
	}

	.wshead {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.wshead h1 {
		font-family: var(--font-display);
		font-size: 20px;
		font-weight: 600;
		margin: 0;
	}

	.wshead .cnt {
		font-size: 12.5px;
		color: var(--text-3);
	}

	.wshead .sp {
		flex: 1;
	}

	.btn {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 6px 11px;
		border-radius: var(--r-sm);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--accent);
		background: var(--accent);
		color: var(--on-accent);
	}

	.btn:hover {
		background: var(--accent-press);
	}

	.table-scroll {
		overflow-x: auto;
		min-width: 0;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 13px;
	}

	thead th {
		text-align: left;
		padding: 10px 14px;
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--text-3);
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
	}

	thead th.r,
	tbody td.r {
		text-align: right;
	}

	thead th.c,
	tbody td.c {
		text-align: center;
	}

	tbody td {
		padding: 11px 14px;
		border-bottom: 1px solid var(--border);
		color: var(--text);
	}

	tbody tr:last-child td {
		border-bottom: none;
	}

	tbody tr:hover {
		background: var(--sunken);
	}

	.mono {
		font-family: var(--font-mono);
	}
</style>
