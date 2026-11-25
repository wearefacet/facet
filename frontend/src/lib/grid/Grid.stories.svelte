<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import Grid from '$lib/grid/Grid.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { DataSourceError } from '$lib/datasource/types.js';
	import { setPermissions } from '$lib/permissions.svelte';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { GridColumn } from '$lib/grid/types.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import { wallToUtcIso, type Wall } from '$lib/zonedTime.js';
	import { displayTimezone } from '$lib/settings.svelte';

	// The edit affordances gate on the viewer's `update` grant — the module
	// grants everything so the editing stories can drive the write path.
	setPermissions({ '*.*': ['*'] });

	/**
	 * A purpose-built fixture driver — 8 `crm.GridDeal` rows shaped like the
	 * design mock's opportunity board (title, status enum, money, integer,
	 * computed fx, date, boolean) plus the full editable-type set the
	 * editing stories walk through: longtext, datetime, period, dateperiod,
	 * duration, reference, colour, url. The grid stories do not reuse
	 * `crm.Deal`: the boolean column and the state variety (nulls, mixed
	 * statuses) need their own seed, and a distinct doctype sidesteps the
	 * storybook page's shared doctype-views cache (the `DocumentCard`
	 * stories rule).
	 */
	function makeGridDriver(): MockDataDriver {
		const d = new MockDataDriver();
		// The reference target — three contacts the `owner` picker searches.
		// The `search` template makes the corpus searchable (the D3 rule: no
		// template matches nothing), and `name` doubles as the display label.
		d.registerDoctype('crm', 'GridContact', {
			doctype: 'GridContact',
			domain: 'crm',
			icon: 'user',
			color: '#7986CB',
			fields: {
				name: { key: 'name', type: 'string', title: 'Nom', required: true }
			},
			search: '{{ name }}',
			children: [],
			actions: []
		});
		void d.domain('crm').doctype('GridContact', [
			{ id: 'crm.GridContact.1', name: 'Thomas Lefèvre' },
			{ id: 'crm.GridContact.2', name: 'Nina Bergström' },
			{ id: 'crm.GridContact.3', name: 'Paulo Mendes' }
		]);
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
				due_at: { key: 'due_at', type: 'datetime', title: 'Échéance' },
				term: { key: 'term', type: 'period', title: 'Période' },
				sprint: { key: 'sprint', type: 'dateperiod', title: 'Sprint' },
				effort: { key: 'effort', type: 'duration', title: 'Effort' },
				owner: {
					key: 'owner',
					type: 'reference',
					title: 'Responsable',
					doctype: 'crm.GridContact'
				},
				tint: { key: 'tint', type: 'color', title: 'Couleur' },
				notes: { key: 'notes', type: 'longtext', title: 'Notes' },
				site: { key: 'site', type: 'url', title: 'Site' },
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
				due_at: '2027-01-15T17:00:00Z',
				term: { start: '2026-11-01T00:00:00Z', end: '2027-01-31T23:59:59Z' },
				sprint: { start: '2026-12-01', end: '2026-12-21' },
				effort: 5400,
				owner: 'crm.GridContact.1',
				tint: '#3FB39A',
				notes: 'Client souhaite un pilote sur deux sites avant signature.',
				site: 'https://meridian.example.com',
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
				due_at: '2026-12-18T09:30:00Z',
				sprint: { start: '2026-12-01', end: '2026-12-14' },
				effort: 9000,
				owner: 'crm.GridContact.2',
				tint: '#6E93E0',
				notes: 'Devis à remettre avant le comité achats de janvier.',
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
				effort: 16200,
				owner: 'crm.GridContact.3',
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
				term: { start: '2027-01-01T00:00:00Z', end: '2027-02-15T23:59:59Z' },
				effort: 7200,
				tint: '#F0A830',
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
				due_at: '2027-02-01T08:00:00Z',
				sprint: { start: '2027-01-04', end: '2027-01-29' },
				effort: 27000,
				owner: 'crm.GridContact.1',
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
				due_at: '2026-12-10T12:00:00Z',
				effort: 3600,
				owner: 'crm.GridContact.2',
				tint: '#E8743B',
				notes: 'Le pilote facturation tourne — 340 factures traitées.',
				site: 'https://optilog.example.com',
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
				effort: 1800,
				won: false
			},
			{
				id: 'crm.GridDeal.8',
				title: 'Portail fournisseurs Delta',
				status: 'framing',
				value: { value: '97000', currency: 'USD' },
				probability: 30,
				weighted: 29100,
				term: { start: '2026-12-01T00:00:00Z', end: '2027-03-31T23:59:59Z' },
				effort: 45000,
				owner: 'crm.GridContact.3',
				won: false
			}
		]);
		void d.domain('core').doctype('DocType', [
			{ id: 'crm.GridDeal', doctype: 'GridDeal', domain: 'crm' },
			{
				id: 'crm.GridContact',
				doctype: 'GridContact',
				domain: 'crm',
				color: '#7986CB',
				search: '{{ name }}'
			}
		]);
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

	/**
	 * Every editable type in one strip — the manual playground. The grid
	 * treats a writable column as editable unless `false`; the fixture's
	 * `weighted` (`data`) column stays read-only behind its fx badge.
	 */
	const allTypeColumns: GridColumn[] = [
		{ key: 'title', label: 'Opportunité', width: '240px' },
		{ key: 'status', label: 'Statut', width: '170px' },
		{ key: 'value', label: 'CA prévisionnel', width: '180px', align: 'right' },
		{ key: 'probability', label: 'Probabilité', width: '120px', align: 'right' },
		{ key: 'close_date', label: 'Clôture', width: '150px' },
		{ key: 'due_at', label: 'Échéance', width: '200px' },
		{ key: 'term', label: 'Période', width: '220px' },
		{ key: 'sprint', label: 'Sprint', width: '200px' },
		{ key: 'effort', label: 'Effort', width: '130px', align: 'right' },
		{ key: 'owner', label: 'Responsable', width: '180px' },
		{ key: 'tint', label: 'Couleur', width: '130px' },
		{ key: 'notes', label: 'Notes', width: '240px' },
		{ key: 'site', label: 'Site', width: '200px' },
		{ key: 'weighted', label: 'CA pondéré', width: '160px', align: 'right', summary: 'sum' },
		{ key: 'won', label: 'Gagné', width: '96px', align: 'center' }
	];

	/** The editing stories' strips — one editor column, always data-col 0. */
	const one = (key: string, label: string, width: string, extra?: Partial<GridColumn>): GridColumn[] => [
		{ key, label, width, ...extra }
	];

	/** The editing stories' arg set — a fresh driver, one strip, the schema. */
	function storyArgs(
		bundle: { driver: MockDataDriver; ds: DataSource<Record<string, unknown>> },
		columns?: GridColumn[]
	) {
		return {
			columns: columns ?? allTypeColumns,
			datasource: bundle.ds,
			doctype: dealDef,
			driver: bundle.driver,
			rowKey: (item: unknown) => String((item as Record<string, unknown>).id),
			onRowClick: fn()
		};
	}

	/**
	 * The 422 story's arg set — the same fresh driver, but `doc(id).update`
	 * rejects with the backend's conflict error when the title carries the
	 * trigger word. `Object.create` keeps the datasource's prototype chain:
	 * only the one method shadows.
	 */
	function errorStoryArgs() {
		const bundle = editDriver();
		const failing = Object.create(bundle.ds) as DataSource<Record<string, unknown>>;
		failing.doc = (id: string) => {
			const ref = bundle.ds.doc(id);
			const wrapped = Object.create(ref);
			wrapped.update = (diff: unknown) => {
				const title = (diff as Record<string, unknown>).title;
				if (typeof title === 'string' && title.toLowerCase().includes('boom')) {
					return Promise.reject(new DataSourceError(422, 'Ce titre est déjà pris'));
				}
				return ref.update(diff);
			};
			return wrapped;
		};
		return storyArgs({ driver: bundle.driver, ds: failing }, one('title', 'Opportunité', '280px'));
	}

	/** A driver with the GridDeal schema and zero documents — the empty state. */
	function makeEmptyDriver(): MockDataDriver {
		const d = new MockDataDriver();
		const source = makeGridDriver();
		const raw = source.getDoctypeDefinition('crm.GridDeal');
		if (raw) d.registerDoctype('crm', 'GridDeal', raw);
		void d.domain('core').doctype('DocType', []);
		return d;
	}

	/**
	 * A fresh driver + datasource per editing story — each story mutates its
	 * own store, so the plays never read another story's writes and the
	 * shared `gridDriver` keeps its seed for the read-only stories.
	 */
	function editDriver(): { driver: MockDataDriver; ds: DataSource<Record<string, unknown>> } {
		const driver = makeGridDriver();
		const ds = driver
			.domain('crm')
			.doctype('GridDeal') as unknown as DataSource<Record<string, unknown>>;
		return { driver, ds };
	}

	/** Read one row's content back through a datasource. */
	async function stored(
		ds: DataSource<unknown>,
		id: string
	): Promise<Record<string, unknown>> {
		const res = await ds.doc(id).show();
		return res.data as Record<string, unknown>;
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
	name="DragSelect"
	args={{ ...storyArgs(editDriver(), dealColumns.slice(0, 4)) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// A press on a cell arms the drag: a held-button pass over the cells
		// below extends the range — the mouse drag-select.
		const anchor = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		anchor.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
		const far = canvasElement.querySelector('[data-row="2"][data-col="1"]')!;
		far.dispatchEvent(new MouseEvent('mouseenter', { buttons: 1 }));
		await sleep(100); // the range paints on the flush after the dispatch
		expect(far.getAttribute('aria-selected')).toBe('true');
		// The press ends wherever the pointer is — the drag disarms.
		window.dispatchEvent(new MouseEvent('mouseup'));
		await sleep(50);
		const strayed = canvasElement.querySelector('[data-row="4"][data-col="3"]')!;
		strayed.dispatchEvent(new MouseEvent('mouseenter', { buttons: 1 }));
		await sleep(50);
		expect(strayed.getAttribute('aria-selected')).toBe('false');
		// An enum pick closes its editor under the held button. The press
		// belongs to the editor — the cells exposed underneath must not
		// sweep-select, and the pick commits as one cell.
		const status = canvasElement.querySelector('[data-row="0"][data-col="1"]')!;
		await userEvent.dblClick(status);
		const option = [...status.querySelectorAll('.enum-opt')].find((b) =>
			b.textContent?.includes('Cadrage')
		)!;
		option.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
		await sleep(150);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.status).toBe('framing');
		const below = canvasElement.querySelector('[data-row="3"][data-col="0"]')!;
		below.dispatchEvent(new MouseEvent('mouseenter', { buttons: 1 }));
		await sleep(50);
		expect(below.getAttribute('aria-selected')).toBe('false');
		expect(canvasElement.querySelectorAll('[aria-selected="true"]').length).toBe(1);
		window.dispatchEvent(new MouseEvent('mouseup'));
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

// ═══════════════════════════════════════════════════════════════════════
// Editing stories — one per cell editor, plus the flip, the 422 state,
// and the undo. Each story drives a fresh driver, so its writes never
// leak into another story's seed. The edited column is always data-col 0.
// ═══════════════════════════════════════════════════════════════════════

<Story
	name="TextEdit"
	args={{ ...storyArgs(editDriver(), one('title', 'Opportunité', '300px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Click the title cell, then type — the first char opens the editor
		// with that seed (type-to-replace), the rest fills the draft.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		await userEvent.keyboard('Nouveau titre');
		// The editor is open over the cell — Enter commits and moves down.
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		expect(cell.textContent).toContain('Nouveau titre');
		// The PATCH went through the datasource — the mock store holds it.
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.title).toBe('Nouveau titre');
	}}
/>

<Story
	name="LongTextEdit"
	args={{ ...storyArgs(editDriver(), one('notes', 'Notes', '280px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the floating textarea on the current value.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const textarea = cell.querySelector('textarea')!;
		expect(textarea.value).toContain('pilote sur deux sites');
		// A bare Enter inserts a line; ⌘↵ commits.
		await userEvent.type(textarea, '{Enter}');
		await userEvent.type(textarea, 'Deuxième ligne.');
		await userEvent.keyboard('{Meta>}{Enter}{/Meta}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.notes).toBe(
			'Client souhaite un pilote sur deux sites avant signature.\nDeuxième ligne.'
		);
	}}
/>

<Story
	name="EnumEdit"
	args={{ ...storyArgs(editDriver(), one('status', 'Statut', '180px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the filter listbox on the declared values.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const input = cell.querySelector('input')!;
		// Typing narrows by key or label; Enter picks the highlighted one.
		// `devis` matches exactly one declared value (Devis envoyé).
		await userEvent.type(input, 'devis');
		const list = canvasElement.querySelector('[role="listbox"]')!;
		expect(list.querySelectorAll('.enum-opt').length).toBe(1);
		expect(list.textContent).toContain('Devis envoyé');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		expect(cell.textContent).toContain('Devis envoyé');
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.status).toBe('quote');
	}}
/>

<Story
	name="IntegerEdit"
	args={{ ...storyArgs(editDriver(), one('probability', 'Probabilité', '150px', { align: 'right' })) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		// Type-to-replace: the first char opens the editor with the seed.
		await userEvent.keyboard('150');
		// Above the declared max — the commit blocks, the editor stays open.
		await userEvent.keyboard('{Enter}');
		await sleep(50);
		const editor = cell.querySelector('input')!;
		expect(editor.className).toContain('invalid');
		// Escape cancels — the cell keeps its stored value.
		await userEvent.keyboard('{Escape}');
		await sleep(50);
		expect(cell.textContent).toContain('50');
		// A valid entry commits — the editor reopens on a fresh click (the
		// Escape cleared the selection).
		await userEvent.click(cell);
		await userEvent.keyboard('66');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.probability).toBe(66);
	}}
/>

<Story
	name="DurationEdit"
	args={{ ...storyArgs(editDriver(), one('effort', 'Effort', '170px', { align: 'right' })) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// The free-form parser takes `3h 15m`; the committed value is seconds.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		await userEvent.keyboard('3h 15m');
		// The live hint shows the parsed total while typing.
		expect(cell.textContent).toContain('3h');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.effort).toBe(11700);
	}}
/>

<Story
	name="MoneyEdit"
	args={{ ...storyArgs(editDriver(), one('value', 'CA prévisionnel', '220px', { align: 'right' })) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens MoneyInput — currency chip + amount.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const amount = cell.querySelector<HTMLInputElement>('input.money-amount')!;
		expect(amount.value).not.toBe('');
		// Replace the amount; the currency stays USD.
		await userEvent.clear(amount);
		await userEvent.type(amount, '51000');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.value).toEqual({ value: '51000', currency: 'USD' });
	}}
/>

<Story
	name="DateEdit"
	args={{ ...storyArgs(editDriver(), one('close_date', 'Clôture prévue', '190px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the compact segment field; the year segment
		// holds the focus. Typing fills and auto-advances.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const year = cell.querySelector<HTMLInputElement>('input.dtp-seg-y')!;
		expect(document.activeElement).toBe(year);
		// The segments hold the stored date, and the keystroke simulation
		// skips full inputs — clear each segment, then type it.
		await userEvent.clear(year);
		await userEvent.type(year, '2028');
		const month = cell.querySelector<HTMLInputElement>('input[aria-label="month"]')!;
		await userEvent.clear(month);
		await userEvent.type(month, '03');
		const day = cell.querySelector<HTMLInputElement>('input[aria-label="day"]')!;
		await userEvent.clear(day);
		await userEvent.type(day, '15');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.close_date).toBe('2028-03-15');
	}}
/>

<Story
	name="PeriodEdit"
	args={{ ...storyArgs(editDriver(), one('sprint', 'Sprint', '260px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the floating two-bound picker (dateperiod —
		// calendar dates, never timezone-converted).
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		// The Start bound's year segment holds the focus. The segments hold
		// the stored range — clear each, then type it.
		const inputs = [...cell.querySelectorAll<HTMLInputElement>('input.dtp-seg')];
		expect(inputs.length).toBe(6);
		await userEvent.clear(inputs[0]!);
		await userEvent.type(inputs[0]!, '2027');
		await userEvent.clear(inputs[1]!);
		await userEvent.type(inputs[1]!, '02');
		await userEvent.clear(inputs[2]!);
		await userEvent.type(inputs[2]!, '02');
		// The End bound — the picker's own segment inputs, in DOM order.
		await userEvent.clear(inputs[3]!);
		await userEvent.type(inputs[3]!, '2027');
		await userEvent.clear(inputs[4]!);
		await userEvent.type(inputs[4]!, '02');
		await userEvent.clear(inputs[5]!);
		await userEvent.type(inputs[5]!, '28');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.sprint).toEqual({ start: '2027-02-02', end: '2027-02-28' });
	}}
/>

<Story
	name="DatetimeEdit"
	args={{ ...storyArgs(editDriver(), one('due_at', 'Échéance', '220px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the floating datetime frame — five segments plus
		// the buttons never fit one column. The year segment holds the focus.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const year = cell.querySelector<HTMLInputElement>('input.dtp-seg-y')!;
		expect(document.activeElement).toBe(year);
		// Wall-clock entry — the segments convert through the display
		// timezone on commit, so the expected UTC form comes from the same
		// conversion (never a hardcoded offset).
		const expected = wallToUtcIso({ y: 2028, m: 3, d: 15, h: 9, mi: 30 }, displayTimezone());
		await userEvent.clear(year);
		await userEvent.type(year, '2028');
		const month = cell.querySelector<HTMLInputElement>('input[aria-label="month"]')!;
		await userEvent.clear(month);
		await userEvent.type(month, '03');
		const day = cell.querySelector<HTMLInputElement>('input[aria-label="day"]')!;
		await userEvent.clear(day);
		await userEvent.type(day, '15');
		const hour = cell.querySelector<HTMLInputElement>('input[aria-label="hour"]')!;
		await userEvent.clear(hour);
		await userEvent.type(hour, '09');
		const minute = cell.querySelector<HTMLInputElement>('input[aria-label="minute"]')!;
		await userEvent.clear(minute);
		await userEvent.type(minute, '30');
		// The parsed line shows the stored UTC form the segments commit.
		expect(cell.querySelector('.parsed-hint')?.textContent).toContain(expected);
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.due_at).toBe(expected);
	}}
/>

<Story
	name="DatetimePeriodEdit"
	args={{ ...storyArgs(editDriver(), one('term', 'Période', '220px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the floating two-bound picker in datetime mode —
		// ten segment inputs, five per bound, converting through the display
		// timezone on commit.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		const inputs = [...cell.querySelectorAll<HTMLInputElement>('input.dtp-seg')];
		expect(inputs.length).toBe(10);
		const tz = displayTimezone();
		const startWall: Wall = { y: 2027, m: 2, d: 1, h: 8, mi: 0 };
		const endWall: Wall = { y: 2027, m: 2, d: 28, h: 23, mi: 59 };
		const order = ['2027', '02', '01', '08', '00', '2027', '02', '28', '23', '59'];
		for (let i = 0; i < order.length; i++) {
			await userEvent.clear(inputs[i]!);
			await userEvent.type(inputs[i]!, order[i]!);
		}
		// The committed-text foot shows the parsed pair in the stored form.
		expect(cell.querySelector('.pp-committed')?.textContent).toBe(
			`${wallToUtcIso(startWall, tz)} → ${wallToUtcIso(endWall, tz)}`
		);
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.term).toEqual({
			start: wallToUtcIso(startWall, tz),
			end: wallToUtcIso(endWall, tz)
		});
	}}
/>

<Story
	name="ReferenceEdit"
	args={{ ...storyArgs(editDriver(), one('owner', 'Responsable', '220px')) }}
	// A11y backlog (audit 22): the selected chip nests the ✕ button inside
	// the role=button row — the same nested-interactive finding logged on
	// the picker's own stories. Fix the picker structure, then remove this.
	parameters={{ a11y: { test: 'todo' } }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Double-click opens the ReferencePicker — it hydrates the stored
		// record's label through the driver.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.dblClick(cell);
		// The picker hydrates the stored record — its chip shows first; the
		// ✕ affordance starts the edit and reveals the search input.
		await userEvent.click(cell.querySelector('button.ref-clear')!);
		const input = cell.querySelector<HTMLInputElement>('input.ref-input')!;
		// Search narrows to one contact; Enter picks it and the focus lands
		// on the chip; a second Enter commits the cell.
		await userEvent.type(input, 'Nina');
		await sleep(500); // the search debounces 220ms
		await userEvent.keyboard('{Enter}'); // pick the record
		await sleep(100);
		await userEvent.keyboard('{Enter}'); // commit the cell
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.owner).toBe('crm.GridContact.2');
	}}
/>

<Story
	name="ColorEdit"
	args={{ ...storyArgs(editDriver(), one('tint', 'Couleur', '170px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// The bare hex input carries a live swatch.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		await userEvent.keyboard('6e93e0');
		// The swatch previews the parsed colour before the commit (the DOM
		// serializes the hex to its rgb form).
		const swatch = cell.querySelector('.color-swatch')!;
		expect(swatch.getAttribute('style')).toContain('110, 147, 224');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.tint).toBe('#6E93E0');
	}}
/>

<Story
	name="BooleanFlip"
	args={{ ...storyArgs(editDriver(), one('won', 'Gagné', '130px', { align: 'center' })) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Booleans have no edit mode — the flip is one click, one PATCH.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		const button = cell.querySelector('button.cell-bool')!;
		expect(button.getAttribute('aria-pressed')).toBe('false');
		await userEvent.click(button);
		await sleep(100);
		expect(cell.querySelector('button.cell-bool')!.getAttribute('aria-pressed')).toBe('true');
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.won).toBe(true);
		// A second click flips back — each click is one PATCH.
		await userEvent.click(cell.querySelector('button.cell-bool')!);
		await sleep(100);
		const after = await stored(args.datasource, 'crm.GridDeal.1');
		expect(after.won).toBe(false);
	}}
/>

<Story
	name="EditError422"
	args={{ ...errorStoryArgs() }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// A driver that 422s titles carrying the trigger word.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		await userEvent.keyboard('boom deal');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		// The cell keeps the typed text under the error frame + tooltip.
		expect(cell.textContent).toContain('boom deal');
		expect(cell.className).toContain('cell-error');
		expect(cell.getAttribute('title')).toContain('pris');
		// Escape reverts — the typed text drops, the stored value returns.
		await userEvent.keyboard('{Escape}');
		await sleep(100);
		expect(cell.className).not.toContain('cell-error');
		expect(cell.textContent).not.toContain('boom deal');
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.title).toBe('Déploiement plateforme qualité Meridian');
	}}
/>

<Story
	name="UndoEdit"
	args={{ ...storyArgs(editDriver(), one('title', 'Opportunité', '300px')) }}
	play={async ({ canvasElement, args }) => {
		await sleep(400);
		// Commit a retitle, then ⌘Z inverts it through the queue.
		const cell = canvasElement.querySelector('[data-row="0"][data-col="0"]')!;
		await userEvent.click(cell);
		await userEvent.keyboard('Retitre');
		await userEvent.keyboard('{Enter}');
		await sleep(100);
		expect(cell.textContent).toContain('Retitre');
		await userEvent.keyboard('{Control>}z{/Control}');
		await sleep(100);
		expect(cell.textContent).toContain('Déploiement');
		const row = await stored(args.datasource, 'crm.GridDeal.1');
		expect(row.title).toBe('Déploiement plateforme qualité Meridian');
	}}
/>

<Story
	name="AllTypes"
	args={{
		...storyArgs(editDriver()),
		selectable: true,
		frozen: 1
	}}
	play={async ({ canvasElement }) => {
		await sleep(400);
		// The manual playground — every editable type in one strip. A smoke
		// check: the fx badge still marks the computed column read-only and
		// the boolean column renders its flip (no editable:false here).
		const headers = [...canvasElement.querySelectorAll('[role="columnheader"]')];
		expect(
			headers.find((h) => h.textContent?.includes('CA pondéré'))?.querySelector('.fx')
		).toBeTruthy();
		expect(canvasElement.querySelector('[data-row="0"] button.cell-bool')).toBeTruthy();
	}}
/>
