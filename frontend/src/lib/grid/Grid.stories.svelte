<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import Grid from '$lib/grid/Grid.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { GridColumn } from '$lib/grid/types.js';

	/**
	 * A purpose-built fixture driver — 8 `crm.GridDeal` rows shaped like the
	 * design mock's opportunity board (title, status enum, money, integer,
	 * computed fx, date, boolean). The grid stories do not reuse `crm.Deal`:
	 * the boolean column and the state variety (nulls, mixed statuses) need
	 * their own seed, and a distinct doctype sidesteps the storybook page's
	 * shared doctype-views cache (the `DocumentCard` stories rule).
	 */
	function makeGridDriver(): MockDataDriver {
		const d = new MockDataDriver();
		d.registerDoctype('crm', 'GridDeal', {
			doctype: 'GridDeal',
			domain: 'crm',
			icon: 'handshake',
			color: '#FF9800',
			fields: {
				title: { key: 'title', type: 'string', title: 'Opportunité', required: true },
				status: {
					key: 'status',
					type: 'enum',
					title: 'Statut',
					values: [
						{ key: 'needs', color: '#6e93e0', label: 'Besoins identifiés' },
						{ key: 'framing', color: '#3fb39a', label: 'Cadrage' },
						{ key: 'pilot', color: '#f0a830', label: 'Pilote' },
						{ key: 'review', color: '#f08c3a', label: 'Bilan pilote' },
						{ key: 'quote', color: '#e8743b', label: 'Devis envoyé' }
					]
				},
				value: { key: 'value', type: 'money', title: 'CA prévisionnel', currency: 'USD' },
				probability: {
					key: 'probability',
					type: 'integer',
					title: 'Probabilité',
					min: 0,
					max: 100
				},
				weighted: { key: 'weighted', type: 'data', title: 'CA pondéré', compute: 'x' },
				close_date: { key: 'close_date', type: 'date', title: 'Clôture prévue' },
				won: { key: 'won', type: 'boolean', title: 'Gagné' }
			},
			children: [],
			actions: []
		});
		void d.domain('crm').doctype('GridDeal', [
			{
				id: 'crm.GridDeal.1',
				title: 'Déploiement plateforme qualité Meridian',
				status: 'review',
				value: { value: '130000', currency: 'USD' },
				probability: 50,
				weighted: 65000,
				close_date: '2027-01-31',
				won: false
			},
			{
				id: 'crm.GridDeal.2',
				title: 'Audit achats Groupe Vallon',
				status: 'quote',
				value: { value: '45000', currency: 'EUR' },
				probability: 80,
				weighted: 36000,
				close_date: '2026-12-20',
				won: false
			},
			{
				id: 'crm.GridDeal.3',
				title: 'Accompagnement certification NovaSyg',
				status: 'needs',
				value: { value: '85000', currency: 'USD' },
				probability: 10,
				weighted: 8500,
				close_date: '2027-03-31',
				won: false
			},
			{
				id: 'crm.GridDeal.4',
				title: 'Refonte reporting Atelier Garnier',
				status: 'framing',
				value: { value: '32000', currency: 'USD' },
				probability: 25,
				weighted: 8000,
				close_date: '2027-02-15',
				won: false
			},
			{
				id: 'crm.GridDeal.5',
				title: 'Migration ERP Brasserie du Port',
				status: 'pilot',
				value: { value: '68000', currency: 'EUR' },
				probability: 40,
				weighted: 27200,
				close_date: '2027-02-28',
				won: false
			},
			{
				id: 'crm.GridDeal.6',
				title: 'Automatisation factures Optilog',
				status: 'quote',
				value: { value: '24500', currency: 'USD' },
				probability: 90,
				weighted: 19600,
				close_date: '2026-12-15',
				won: true
			},
			{
				id: 'crm.GridDeal.7',
				title: 'Tableau de bord RH Sélène',
				status: 'needs',
				value: { value: '15000', currency: 'USD' },
				probability: 10,
				weighted: 1500,
				close_date: '2027-04-30',
				won: false
			},
			{
				id: 'crm.GridDeal.8',
				title: 'Portail fournisseurs Delta',
				status: 'framing',
				value: { value: '97000', currency: 'USD' },
				probability: 30,
				weighted: 29100,
				won: false
			}
		]);
		void d
			.domain('core')
			.doctype('DocType', [{ id: 'crm.GridDeal', doctype: 'GridDeal', domain: 'crm' }]);
		return d;
	}

	const gridDriver = makeGridDriver();

	function defFor(qualified: string): DoctypeDef {
		const raw = gridDriver.getDoctypeDefinition(qualified);
		if (!raw) throw new Error(`Missing doctype definition for ${qualified}`);
		return parseDoctypeDef(raw);
	}

	const dealDef = defFor('crm.GridDeal');

	/** The resolved column set — the host's `resolveColumnLabel` + sortable
	 *  resolution collapsed to literals for the fixture. */
	const dealColumns: GridColumn[] = [
		{ key: 'title', label: 'Opportunité', width: '300px', sortable: true },
		{ key: 'status', label: 'Statut', width: '180px', sortable: true },
		{
			key: 'value',
			label: 'CA prévisionnel',
			// Wide enough for the Σ row's two-currency bag
			// ("Sum EUR 113,000 · USD 368,500") to read in one line.
			width: '260px',
			align: 'right',
			summary: 'sum',
			sortable: true
		},
		{
			key: 'probability',
			label: 'Probabilité',
			width: '120px',
			align: 'right',
			summary: 'avg',
			sortable: true
		},
		{ key: 'weighted', label: 'CA pondéré', width: '160px', align: 'right', summary: 'sum' },
		{ key: 'close_date', label: 'Clôture prévue', width: '140px', sortable: true },
		{ key: 'won', label: 'Gagné', width: '96px', align: 'center', editable: false }
	];

	/** A driver with the GridDeal schema and zero documents — the empty state. */
	function makeEmptyDriver(): MockDataDriver {
		const d = new MockDataDriver();
		const source = makeGridDriver();
		const raw = source.getDoctypeDefinition('crm.GridDeal');
		if (raw) d.registerDoctype('crm', 'GridDeal', raw);
		void d.domain('core').doctype('DocType', []);
		return d;
	}

	/** Wait long enough for the page fetch + Σ aggregates to settle. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	const { Story } = defineMeta({
		title: 'Components/Data/Grid',
		component: Grid,
		tags: ['autodocs'],
		args: {
			columns: dealColumns,
			datasource: gridDriver.domain('crm').doctype('GridDeal'),
			doctype: dealDef,
			driver: gridDriver,
			rowKey: (item: unknown) => String((item as Record<string, unknown>).id),
			onRowClick: fn()
		}
	});
</script>

<!--
	The grid listing surface: one row per document, one column per field.
	Each story mirrors one slice of the design mock (the Σ row, the range
	selection, the frozen columns, the copy path).
-->

<Story
	name="Default"
	args={{ selectable: true, frozen: 1 }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Eight data rows render (header + foot excluded by the data-row attrs).
		const cells = canvasElement.querySelectorAll('[role="gridcell"][data-row]');
		expect(cells.length).toBe(56); // 8 rows × 7 columns
		// The Σ row aggregates the whole filtered set through the datasource.
		// The value column mixes currencies, so its sum renders as the
		// backend's per-currency bag: EUR 45,000 + 68,000, USD for the rest.
		// The probability avg rounds to one decimal; the weighted column is a
		// `data` field seeded with plain numbers, so its sum is bare.
		const foot = canvasElement.querySelector('.g-foot')!;
		expect(foot.textContent).toContain('EUR 113,000');
		expect(foot.textContent).toContain('USD 383,500');
		expect(foot.textContent).toContain('41.9');
		expect(foot.textContent).toContain('194,900');
		// The fx badge marks the computed column.
		const headers = [...canvasElement.querySelectorAll('[role="columnheader"]')];
		expect(
			headers.find((h) => h.textContent?.includes('CA pondéré'))?.querySelector('.fx')
		).toBeTruthy();
		// Layout guard: each body cell's left edge lines up with its header's —
		// they answer the finer drift cases (sticky offsets, padding).
		for (const c of [0, 1, 2, 6]) {
			const header = canvasElement.querySelector(
				`[role="columnheader"][aria-colindex="${c + 1}"]`
			)!;
			const cell = canvasElement.querySelector(`[data-row="0"][data-col="${c}"]`)!;
			const drift = Math.abs(
				header.getBoundingClientRect().left - cell.getBoundingClientRect().left
			);
			expect(drift).toBeLessThan(2);
		}
		// Track guard: the resolved template carries the gutter (48px), the
		// checkbox (40px), then every column width. A template missing the
		// gutter once shifted every cell one track left and wrapped the last
		// cell to a second line — header and body shift together there, so
		// neither the drift check nor the cell count can see it. The rows are
		// the grid containers (the wrapper only defines the custom property),
		// so the computed template reads off a row. Compared numerically with
		// sub-pixel slack: getComputedStyle reports used track sizes, and
		// Chromium's LayoutUnit snapping renders 48px as 47.998px on some
		// device scales — exact strings would flake per environment.
		const row = canvasElement.querySelector('.g-row:not(.g-head):not(.g-foot)')!;
		const tracks = getComputedStyle(row)
			.gridTemplateColumns.split(' ')
			.map((t) => Number.parseFloat(t));
		const expectedTracks = [48, 40, 300, 180, 260, 120, 160, 140, 96];
		expect(tracks).toHaveLength(expectedTracks.length);
		for (const [i, w] of expectedTracks.entries()) {
			expect(tracks[i]).toBeCloseTo(w, 1);
		}
		// A body row renders on one 40px line — a wrapped cell doubles it.
		expect(row.getBoundingClientRect().height).toBeCloseTo(40, 1);
		// The footer carries the exact range — 8 rows fit one page.
		expect(canvas.getByText('1–8 of 8')).toBeTruthy();
	}}
/>

<Story
	name="KeyboardAndRange"
	args={{ selectable: true, frozen: 1 }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// Click the first title cell — the focus collapses onto it.
		const first = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(first);
		expect(first.getAttribute('aria-selected')).toBe('true');
		// ArrowDown moves the focus; shift+arrows extend the range into a
		// 2×2 block (down to row 2, then up-left under shift re-anchors the
		// rectangle around both rows and both first columns).
		await userEvent.keyboard('{ArrowDown}');
		await userEvent.keyboard('{Shift>}{ArrowUp}{ArrowRight}{/Shift}');
		const selected = canvasElement.querySelectorAll('[aria-selected="true"]');
		expect(selected.length).toBe(4); // 2 rows × 2 columns
		// The footer chip counts the range and its numeric stats.
		const chip = canvasElement.querySelector('.sel-chip');
		expect(chip?.textContent).toContain('4');
		// Escape clears the selection.
		await userEvent.keyboard('{Escape}');
		expect(canvasElement.querySelectorAll('[aria-selected="true"]').length).toBe(0);
	}}
/>

<Story
	name="CopyTSV"
	args={{ selectable: true, frozen: 1 }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// Stub the clipboard — copyText prefers the async API.
		let copied = '';
		const writeText = async (text: string) => {
			copied = text;
		};
		Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
		// Select a 2×2 block: title + status on rows 1–2. userEvent.click has
		// no modifier option, so the extend is a raw shift-mousedown.
		await userEvent.click(canvasElement.querySelector('[data-row="0"][data-col="0"]')!);
		canvasElement
			.querySelector('[data-row="1"][data-col="1"]')!
			.dispatchEvent(new MouseEvent('mousedown', { shiftKey: true, bubbles: true }));
		await userEvent.keyboard('{Control>}c{/Control}');
		expect(copied).toBe(
			'Déploiement plateforme qualité Meridian\treview\n' + 'Audit achats Groupe Vallon\tquote'
		);
	}}
/>

<Story
	name="FrozenColumns"
	args={{ selectable: true, frozen: 2 }}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// With two frozen columns the sticky offsets start after gutter +
		// checkbox (88px): title at 88, status at 88 + 300.
		const headers = [...canvasElement.querySelectorAll('[role="columnheader"]')];
		const title = headers.find((h) => h.textContent?.includes('Opportunité'))!;
		const status = headers.find((h) => h.textContent?.includes('Statut'))!;
		expect((title as HTMLElement).style.left).toBe('88px');
		expect((status as HTMLElement).style.left).toBe('388px');
		expect(status.className).toContain('frozen-last');
		// The value column scrolls — no sticky left.
		const value = headers.find((h) => h.textContent?.includes('CA prévisionnel'))!;
		expect((value as HTMLElement).style.left).toBe('');
	}}
/>

<Story
	name="EmptyState"
	args={{
		datasource: makeEmptyDriver().domain('crm').doctype('GridDeal'),
		selectable: true,
		frozen: 1
	}}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// No rows and no Σ row — the empty message renders instead.
		expect(canvasElement.querySelectorAll('[role="gridcell"][data-row]').length).toBe(0);
		expect(canvasElement.querySelector('.g-foot')).toBeNull();
		expect(canvasElement.textContent).toContain('No records');
	}}
/>

<Story
	name="HeaderSort"
	args={{ onSort: fn() }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// The sortable header reports clicks; the host owns the sort state.
		const headers = [...canvasElement.querySelectorAll('[role="columnheader"]')];
		const title = headers.find((h) => h.textContent?.includes('Opportunité'))!;
		await userEvent.click(title.querySelector('.head-sort')!);
		expect(args.onSort).toHaveBeenCalledWith('title');
		// The computed column is not sortable — no callback.
		const weighted = headers.find((h) => h.textContent?.includes('CA pondéré'))!;
		expect(weighted.querySelector('.head-sort')).toBeNull();
		await userEvent.click(weighted);
		expect(args.onSort).toHaveBeenCalledTimes(1);
	}}
/>
