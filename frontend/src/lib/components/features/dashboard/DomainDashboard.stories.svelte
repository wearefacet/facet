<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DomainDashboard from './DomainDashboard.svelte';
	import type { NavDomain, NavDoctype } from '$lib/navTypes';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { invalidateAllClientCaches } from '$lib/datasource/clientCache.js';
	import { clearCounts } from '$lib/navCounts.svelte';
	import {
		clearRecentDocuments,
		getRecentDocuments,
		recordRecentDocument
	} from '$lib/recentDocuments.svelte';
	import type { RecentDocument } from '$lib/recentDocuments.svelte';

	/**
	 * A single shared mock driver. The `crm.Deal` doctype ships with seeded
	 * `core.CollectionView` children (`all`, `open`, `won`, `timeline` — see
	 * data/fixtures/crm.facet-domain/views/crm.Deal/collection_views/), so the
	 * dashboard's pinned-view and saved-view sections have data without any
	 * imperative seeding.
	 *
	 * The mock's `applyFixtures` does not register a `core.Domain` row for the
	 * `crm` bundle, so `buildNavModel` would drop every `crm.*` doctype (it
	 * filters doctypes to domains present in the `core.Domain` list). The
	 * `crm` NavDomain is therefore assembled directly from the mock's registered
	 * doctype definitions — the dashboard only needs the `NavDomain` shape.
	 */
	const driver = createMockDriver();

	/** Lucide-style doctype colors extracted from each `crm.*` definition. */
	const DEFAULT_DOCTYPE_COLOR = '#566688';

	function buildCrmDomain(): NavDomain {
		const doctypes: NavDoctype[] = [];
		for (const [qualified, def] of driver.doctypeDefinitions) {
			if (!qualified.startsWith('crm.')) continue;
			const doctype = def.doctype as string | undefined;
			if (!doctype) continue;
			doctypes.push({
				qualified,
				label: doctype,
				color: (def.color as string) || DEFAULT_DOCTYPE_COLOR,
				icon: (def.icon as string | undefined) ?? null
			});
		}
		return {
			id: 'crm',
			label: 'CRM',
			color: '#2196F3',
			doctypes
		};
	}

	const crmDomain: NavDomain = buildCrmDomain();

	// Seeded `core.CollectionView` projection ids. The mock loader reconstructs
	// child ids from the bundle filename stems (the slug IS the full id):
	// `crm.Deal.collection_view.{slug}`.
	const dealViewIds = {
		all: 'crm.Deal.collection_view.all',
		open: 'crm.Deal.collection_view.open',
		won: 'crm.Deal.collection_view.won',
		pipeline: 'crm.Deal.collection_view.pipeline',
		timeline: 'crm.Deal.collection_view.timeline'
	};

	const recent: RecentDocument[] = [
		{
			id: 'crm.Company.1',
			domain: 'crm',
			doctype: 'Company',
			ts: Date.now() - 10 * 60_000
		},
		{
			id: 'crm.Contact.1',
			domain: 'crm',
			doctype: 'Contact',
			ts: Date.now() - 60 * 60_000
		},
		{
			id: 'crm.Deal.1',
			domain: 'crm',
			doctype: 'Deal',
			ts: Date.now() - 2 * 60 * 60_000
		}
	];

	// The pinned view ids for the "Scoped" story — three seeded Deal views
	// (table + kanban + calendar) exercise the three surface icons.
	const scopedPinned: string[] = [dealViewIds.open, dealViewIds.pipeline, dealViewIds.timeline];

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/DomainDashboard',
		component: DomainDashboard,
		tags: ['autofocus', 'autodocs'],
		args: {
			driver,
			domain: crmDomain,
			pinnedViewIds: [],
			recentDocuments: []
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { within, expect, waitFor } from 'storybook/test';

	// Reset the shared browser stores once per story mount so the count and
	// localStorage-backed sections render deterministically across stories.
	$effect(() => {
		invalidateAllClientCaches();
		clearCounts();
		clearRecentDocuments();
	});
</script>

<Story
	name="Scoped"
	args={{ pinnedViewIds: scopedPinned, recentDocuments: recent }}
	play={async ({ canvasElement }) => {
		await sleep(150);
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('heading', { name: 'CRM' })).toBeVisible();
		// Pinned views also appear as the doctype's saved-view sub-links, so
		// 'Open', 'Pipeline', and 'Timeline' each render twice (pinned card +
		// Deal sub-link).
		expect(canvas.getAllByText('Open').length).toBe(2);
		expect(canvas.getAllByText('Pipeline').length).toBe(2);
		expect(canvas.getAllByText('Timeline').length).toBe(2);
		// Recently-viewed chips resolve their live display name via show()
		// (the store keeps only the id) and render the doctype's color mark.
		const chipLabel = await canvas.findByText('Acme Corp', {}, { timeout: 3000 });
		await expect(chipLabel).toBeInTheDocument();
		const chip = chipLabel.closest('a');
		expect(chip).not.toBeNull();
		expect(chip!.querySelector('.doctype-icon')).not.toBeNull();
		// Doctype saved-view sub-link for crm.Deal 'Won' (not pinned — appears once).
		await expect(canvas.getByText('Won')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding:24px;background:var(--ground);min-height:80vh">
			<DomainDashboard
				{driver}
				domain={crmDomain}
				pinnedViewIds={args.pinnedViewIds}
				recentDocuments={args.recentDocuments}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Empty"
	args={{ pinnedViewIds: [], recentDocuments: [] }}
	play={async ({ canvasElement }) => {
		await sleep(150);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Pin a view and it will show up here.')).toBeVisible();
		await expect(canvas.getByText('Documents you open will appear here.')).toBeVisible();
		// The doctype list still renders with seeded Deal views as sub-links.
		await expect(canvas.getByText('Won')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding:24px;background:var(--ground);min-height:80vh">
			<DomainDashboard
				{driver}
				domain={crmDomain}
				pinnedViewIds={args.pinnedViewIds}
				recentDocuments={args.recentDocuments}
			/>
		</div>
	{/snippet}
</Story>

<!-- This story reads the live store (no `recentDocuments` prop), so a prune
	through `removeRecentDocument` removes the chip from the DOM. -->
<Story
	name="RecentPrunesGone"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A live entry stays and resolves its label.
		recordRecentDocument({ id: 'crm.Company.1', domain: 'crm', doctype: 'Company' });
		// Delete first, then record: the chip's label resolve then answers the
		// tombstone 410, and the dashboard prunes the entry (B-392).
		await driver.domain('crm').doctype('Deal').doc('crm.Deal.2').delete();
		recordRecentDocument({ id: 'crm.Deal.2', domain: 'crm', doctype: 'Deal' });
		await canvas.findByText('Acme Corp', {}, { timeout: 3000 });
		// The gone entry leaves the store — the same prune the command palette
		// runs. The live entry survives.
		await waitFor(() => {
			expect(getRecentDocuments('crm').some((d) => d.id === 'crm.Deal.2')).toBe(false);
		});
		expect(getRecentDocuments('crm').some((d) => d.id === 'crm.Company.1')).toBe(true);
		// The stale chip never stays as a raw id.
		await waitFor(() => {
			expect(canvas.queryByText('crm.Deal.2')).toBeNull();
		});
	}}
>
	{#snippet template()}
		<div style="padding:24px;background:var(--ground);min-height:80vh">
			<DomainDashboard {driver} domain={crmDomain} pinnedViewIds={[]} />
		</div>
	{/snippet}
</Story>
