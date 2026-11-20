<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import Kanban from '$lib/kanban/Kanban.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import type { ListParams } from '$lib/datasource/types.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { KanbanViewConfig } from '$lib/collectionView/types.js';

	const driver = createMockDriver();

	function defFor(qualified: string): DoctypeDef {
		const raw = driver.getDoctypeDefinition(qualified);
		if (!raw) throw new Error(`Missing doctype definition for ${qualified}`);
		return parseDoctypeDef(raw);
	}

	const dealDef = defFor('crm.Deal');

	/** The crm.Deal data source behind the shared driver (for the call spy). */
	const dealsDs = driver.domain('crm').doctype('Deal');
	const listCalls = (): ListParams[] => (dealsDs as unknown as MockDataSource).listCalls;

	// The `pipeline` fixture view config (values mode over the status enum).
	const pipelineCfg: KanbanViewConfig = { mode: 'values', group_by: 'status', page_size: 25 };

	// The `by_probability` fixture view config (custom lanes + base filter).
	const byProbabilityCfg: KanbanViewConfig = {
		mode: 'custom',
		page_size: 25,
		filters: { status__ne: 'abandoned' },
		lanes: [
			{ label: 'Low odds', filter: { probability__lt: 50 } },
			{ label: 'High odds', filter: { probability__gte: 50 } }
		]
	};

	// The `by_value` money-bucket view config: lanes filter on the money
	// field with `"<CCY> <amount>"` values (the mock parses the grammar).
	const byValueCfg: KanbanViewConfig = {
		mode: 'custom',
		page_size: 25,
		lanes: [
			{ label: 'Under 25k', filter: { value__lt: 'USD 25000' } },
			{ label: '25k to 100k', filter: { value__between: ['USD 25000', 'USD 100000'] } },
			{ label: 'Over 100k', filter: { value__gt: 'USD 100000' } }
		]
	};

	/**
	 * A driver whose doctype has no `card` document-view child. The view
	 * cache keys on the doctype id, so the fallback must use a distinct
	 * doctype (the `DocumentCard` stories rule) — reusing `crm.Deal` would
	 * read a cached card template from another story's driver.
	 */
	function makeNoCardDriver(): MockDataDriver {
		const d = new MockDataDriver();
		d.registerDoctype('crm', 'BoardDeal', {
			doctype: 'BoardDeal',
			domain: 'crm',
			icon: 'handshake',
			color: '#FF9800',
			fields: {
				title: { key: 'title', type: 'string', title: 'Title' },
				status: {
					key: 'status',
					type: 'enum',
					title: 'Status',
					values: [
						{ key: 'open', label: 'Open' },
						{ key: 'done', label: 'Done' }
					]
				}
			}
		});
		void d.domain('crm').doctype('BoardDeal', [
			{ id: 'crm.BoardDeal.1', title: 'Aurora Print Studio', status: 'open' },
			{ id: 'crm.BoardDeal.2', title: 'Northwind Supply Co', status: 'open' }
		]);
		void d
			.domain('core')
			.doctype('DocType', [{ id: 'crm.BoardDeal', doctype: 'BoardDeal', domain: 'crm' }]);
		return d;
	}

	/** A doctype with one over-full bucket, to exercise lane pagination. */
	function makeQueueDriver(): MockDataDriver {
		const d = new MockDataDriver();
		d.registerDoctype('crm', 'Queue', {
			doctype: 'Queue',
			domain: 'crm',
			icon: 'list',
			fields: {
				title: { key: 'title', type: 'string', title: 'Title' },
				status: {
					key: 'status',
					type: 'enum',
					title: 'Status',
					values: [
						{ key: 'pending', label: 'Pending' },
						{ key: 'done', label: 'Done' }
					]
				}
			}
		});
		const docs = Array.from({ length: 30 }, (_, i) => ({
			id: `crm.Queue.${i + 1}`,
			title: `Task ${i + 1}`,
			status: 'pending'
		}));
		void d.domain('crm').doctype('Queue', docs);
		void d
			.domain('core')
			.doctype('DocType', [{ id: 'crm.Queue', doctype: 'Queue', domain: 'crm' }]);
		return d;
	}

	/** A values-mode board whose enum carries a value with no declared label.
	 *  The lane header must show the humanized key, as the table does. */
	function makeUnlabeledEnumDriver(): MockDataDriver {
		const d = new MockDataDriver();
		d.registerDoctype('crm', 'Ticket', {
			doctype: 'Ticket',
			domain: 'crm',
			icon: 'ticket',
			fields: {
				title: { key: 'title', type: 'string', title: 'Title' },
				stage: {
					key: 'stage',
					type: 'enum',
					title: 'Stage',
					values: [{ key: 'in_review' }, { key: 'blocked', label: 'Blocked' }]
				}
			}
		});
		void d
			.domain('crm')
			.doctype('Ticket', [{ id: 'crm.Ticket.1', title: 'T-1', stage: 'in_review' }]);
		void d
			.domain('core')
			.doctype('DocType', [{ id: 'crm.Ticket', doctype: 'Ticket', domain: 'crm' }]);
		return d;
	}

	const noCardDriver = makeNoCardDriver();
	const noCardDef = parseDoctypeDef(noCardDriver.getDoctypeDefinition('crm.BoardDeal')!);
	const noCardCfg: KanbanViewConfig = { mode: 'values', group_by: 'status', page_size: 25 };

	const queueDriver = makeQueueDriver();
	const queueDef = parseDoctypeDef(queueDriver.getDoctypeDefinition('crm.Queue')!);
	const queueCfg: KanbanViewConfig = { mode: 'values', group_by: 'status', page_size: 25 };
	const queueDs = queueDriver.domain('crm').doctype('Queue');
	const listCallsQueue = (): ListParams[] => (queueDs as unknown as MockDataSource).listCalls;

	const unlabeledDriver = makeUnlabeledEnumDriver();
	const unlabeledDef = parseDoctypeDef(unlabeledDriver.getDoctypeDefinition('crm.Ticket')!);
	const unlabeledCfg: KanbanViewConfig = { mode: 'values', group_by: 'stage', page_size: 25 };

	const { Story } = defineMeta({
		title: 'Components/Data/Kanban',
		component: Kanban,
		tags: ['autodocs'],
		args: {
			driver,
			doctype: dealDef,
			onCardClick: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** Wait long enough for the per-lane fetches to settle in Storybook. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
</script>

<!--
	The kanban listing surface: one `list()` call per lane, cards rendered
	through the doctype's `card` view template. Stories are wrapped in a
	sized container so the horizontal lane scroll has room to lay out.
-->

<Story
	name="ValuesMode"
	args={{ config: pipelineCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// One lane per declared enum value, in declaration order. The lane
		// label is scoped to the lane head — the card bodies render the
		// status enum value as a badge too.
		const laneLabels = [...canvasElement.querySelectorAll('.kb-col-label')].map((e) =>
			e.textContent?.trim()
		);
		expect(laneLabels).toEqual(['Open', 'Won', 'Lost', 'Abandoned']);
		// The lane dot carries the declared enum colour.
		const openLabel = canvasElement.querySelectorAll('.kb-col-label')[0];
		expect(openLabel?.textContent?.trim()).toBe('Open');
		expect(openLabel?.querySelector('span[style*="816bb3"]')).toBeNull();
		const openDot = openLabel?.previousElementSibling;
		expect(openDot?.getAttribute('style')).toContain('rgb(129, 107, 179)');
		// Capped count badges: two open, one won, none lost/abandoned.
		const counts = [...canvasElement.querySelectorAll('.kb-col-count')].map((e) =>
			e.textContent?.trim()
		);
		expect(counts).toEqual(['2', '1', '0', '0']);
		// The three seeded deals render as cards.
		await expect(canvas.getByText('Acme Corp — Platform License')).toBeVisible();
		await expect(canvas.getByText('Globex Inc — Consultancy')).toBeVisible();
		await expect(canvas.getByText('Acme Corp — Renewal')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban {driver} doctype={dealDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="CustomModeMergesBaseFilter"
	args={{ config: byProbabilityCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Low odds')).toBeVisible();
		await expect(canvas.getByText('High odds')).toBeVisible();
		// Every lane query carries the base `status__ne` merged with its own
		// lane filter, the default sort, and the page cap.
		const laneCalls = listCalls().filter(
			(c) => c.filters && 'status__ne' in (c.filters as Record<string, unknown>)
		);
		const low = laneCalls.find(
			(c) => (c.filters as Record<string, unknown>)['probability__lt'] === 50
		);
		const high = laneCalls.find(
			(c) => (c.filters as Record<string, unknown>)['probability__gte'] === 50
		);
		expect(low).toBeTruthy();
		expect(high).toBeTruthy();
		expect(low!.filters).toEqual({ status__ne: 'abandoned', probability__lt: 50 });
		expect(high!.filters).toEqual({ status__ne: 'abandoned', probability__gte: 50 });
		expect(low!.sort).toEqual(['-updated_at']);
		expect(low!.items).toBe(25);
		// The partition holds the right documents: Globex (30) low, both
		// Acme deals (60 / 100) high.
		await expect(canvas.getByText('Globex Inc — Consultancy')).toBeVisible();
		await expect(canvas.getByText('Acme Corp — Platform License')).toBeVisible();
		await expect(canvas.getByText('Acme Corp — Renewal')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban {driver} doctype={dealDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="CardTemplateRenders"
	args={{ config: pipelineCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The `crm.Deal` card template (value / status / probability fields)
		// renders in every card body.
		expect(canvas.getAllByText('Deal Value').length).toBeGreaterThan(0);
		expect(canvas.getAllByText('Status').length).toBeGreaterThan(0);
		expect(canvas.getAllByText('Probability').length).toBeGreaterThan(0);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban {driver} doctype={dealDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="MoneyBuckets"
	args={{ config: byValueCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The money lanes bucket the seeded deals on the numeric value member:
		// none under 25k, two in the 25k-100k band, one over 100k.
		const counts = [...canvasElement.querySelectorAll('.kb-col-count')].map((e) =>
			e.textContent?.trim()
		);
		await expect(counts).toEqual(['0', '2', '1']);
		await expect(canvas.getByText('No documents')).toBeVisible();
		await expect(canvas.getByText('Globex Inc — Consultancy')).toBeVisible();
		await expect(canvas.getByText('Acme Corp — Renewal')).toBeVisible();
		await expect(canvas.getByText('Acme Corp — Platform License')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban {driver} doctype={dealDef} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="IdentityFallbackWithoutCardTemplate"
	args={{ driver: noCardDriver, doctype: noCardDef, config: noCardCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Without a `card` template the cards render the identity body alone:
		// display name + updated time, no template field labels.
		await expect(canvas.getByText('Aurora Print Studio')).toBeVisible();
		await expect(canvas.getByText('Northwind Supply Co')).toBeVisible();
		expect(canvas.queryByText('Title')).toBeNull();
		// The lanes still resolve from the enum, and the empty one shows the
		// placeholder.
		await expect(canvas.getByText('Open')).toBeVisible();
		await expect(canvas.getByText('Done')).toBeVisible();
		await expect(canvas.getByText('No documents')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban driver={args.driver} doctype={args.doctype} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="CardClickFiresWithDocId"
	args={{ config: pipelineCfg }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		const card = canvas.getByRole('button', { name: /Acme Corp — Platform License/ });
		await card.click();
		await expect(args.onCardClick).toHaveBeenCalledWith('crm.Deal.1');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban {driver} doctype={dealDef} config={args.config} onCardClick={args.onCardClick} />
		</div>
	{/snippet}
</Story>

<Story
	name="UnlabeledEnumLaneShowsHumanizedKey"
	args={{ driver: unlabeledDriver, doctype: unlabeledDef, config: unlabeledCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// `in_review` carries no declared label (the backend drops labels equal
		// to the humanized key) — the lane header shows the humanized form,
		// the same one the table derives, never the bare key.
		const laneLabels = [...canvasElement.querySelectorAll('.kb-col-label')].map((e) =>
			e.textContent?.trim()
		);
		expect(laneLabels).toEqual(['In Review', 'Blocked']);
		// The declared label still wins where one exists.
		expect(laneLabels).not.toContain('in_review');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban driver={args.driver} doctype={args.doctype} config={args.config} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyLaneAndShowMore"
	args={{ driver: queueDriver, doctype: queueDef, config: queueCfg }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The pending bucket holds 30 documents; the first page caps at 25,
		// so the Show more action renders and the badge shows the full count.
		await expect(canvas.getByText('30')).toBeVisible();
		const more = canvas.getByRole('button', { name: 'Show more' });
		// The empty lane renders the placeholder.
		await expect(canvas.getByText('No documents')).toBeVisible();
		// Show more bumps this lane's cap by 25 and re-fetches only it.
		await more.click();
		await sleep(200);
		const refetch = listCallsQueue().find((c) => c.items === 50);
		expect(refetch).toBeTruthy();
		expect(refetch!.filters).toEqual({ status__eq: 'pending' });
		// All 30 cards render now; the action is gone (30 < 50).
		await expect(canvas.queryByRole('button', { name: 'Show more' })).toBeNull();
		expect(canvas.getAllByText(/Task \d+/)).toHaveLength(30);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<Kanban driver={args.driver} doctype={args.doctype} config={args.config} />
		</div>
	{/snippet}
</Story>
