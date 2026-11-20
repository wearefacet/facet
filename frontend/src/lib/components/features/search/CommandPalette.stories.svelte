<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import CommandPalette from './CommandPalette.svelte';
	import type { PaletteCommand } from './searchGroups.js';
	import { setRecordSearchTransport, type SearchResponse } from './searchRecords.js';
	import { setLiveNav } from '$lib/navState.svelte';
	import { getRecentDocuments, recordRecentDocument } from '$lib/recentDocuments.svelte';
	import type { NavDomain } from '$lib/navTypes';

	// ── Module-level seams ────────────────────────────────────────────────
	//
	// The palette reads the nav model, the recent documents, and the search
	// transport from module stores, so the stories seed them here instead of
	// through props. The storybook project runs one file at a time and the
	// stores back no other component story, so the seeds stay file-local in
	// practice.

	const navModel: NavDomain[] = [
		{
			id: 'crm',
			label: 'CRM',
			color: '#3F51B5',
			doctypes: [
				{ qualified: 'crm.Company', label: 'Company', color: '#3F51B5', icon: 'building-2' },
				{ qualified: 'crm.Contact', label: 'Contact', color: '#1B5E20', icon: null }
			]
		},
		{
			id: 'hr',
			label: 'Human Resources',
			color: '#E91E63',
			doctypes: [{ qualified: 'hr.Employee', label: 'Employee', color: '#E91E63' }]
		}
	];
	setLiveNav(navModel);

	recordRecentDocument({ id: 'crm.Company.1', domain: 'crm', doctype: 'Company' });
	recordRecentDocument({ id: 'crm.Company.2', domain: 'crm', doctype: 'Company' });

	// Spy capture for the action rows (reset inside the plays that use it).
	const runSpy = fn();

	const baseCommands: PaletteCommand[] = [
		{ id: 'app.sidebar', label: 'Toggle sidebar', run: runSpy },
		{
			id: 'app.help',
			label: 'Show keyboard shortcuts',
			group: 'Help',
			icon: 'circle-help',
			run: runSpy
		}
	];

	/** Resolved goto() targets — the storybook `$app/navigation` mock turns
	 *  every goto into a `storybook:goto` window event. */
	function collectGotoEvents(): { urls: string[]; done: () => void } {
		const urls: string[] = [];
		const handler = (e: Event) => {
			const detail = (e as CustomEvent).detail as unknown[];
			urls.push(String(detail[0]));
		};
		window.addEventListener('storybook:goto', handler);
		return { urls, done: () => window.removeEventListener('storybook:goto', handler) };
	}

	// ── Transport fixtures — shaped like the backend contract ─────────────

	function json(body: unknown): Response {
		return new Response(JSON.stringify(body), {
			status: 200,
			headers: { 'Content-Type': 'application/json' }
		});
	}

	// ── Label-resolve stub ───────────────────────────────────────────────
	//
	// The palette resolves each recent's label through the real driver →
	// apiFetch → fetch, and (B-392) prunes the entry when the API answers
	// "gone" (404/410). The iframe has no backend: every show() would 404 and
	// prune the module-seeded recents mid-story. The stub answers those two
	// show() calls with display-name documents — labels then resolve the way
	// the dashboard's chips do — and passes every other URL through untouched,
	// so it changes no other story's network behaviour.
	const originalFetch = window.fetch.bind(window);
	const recentDocResponse = (id: string, displayName: string): Response =>
		json({
			data: { name: displayName },
			meta: {
				id,
				mid: id,
				domain: 'crm',
				doc_type: 'Company',
				version: 1,
				schema_version: 1,
				created_at: '2026-01-01T00:00:00Z',
				updated_at: '2026-01-01T00:00:00Z',
				display_name: displayName
			}
		});
	window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
		const url =
			typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
		if (url === '/Api/crm/Company/crm.Company.1')
			return recentDocResponse('crm.Company.1', 'Company North');
		if (url === '/Api/crm/Company/crm.Company.2')
			return recentDocResponse('crm.Company.2', 'Company South');
		return originalFetch(input, init);
	}) as typeof fetch;

	function domainResponse(term: string): SearchResponse {
		return {
			data: [
				{
					domain: 'crm',
					doctype: 'Company',
					hits: [
						{
							id: 'crm.Company.1',
							display_name: 'Acme Corp',
							rank: 0.9,
							root_doctype: 'Company',
							root_id: 'crm.Company.1',
							root_display_name: 'Acme Corp',
							child_label: null
						}
					]
				}
			],
			meta: { q: term, count: 1, scope: 'domain' }
		};
	}

	function childHitResponse(term: string): SearchResponse {
		return {
			data: [
				{
					domain: 'crm',
					doctype: 'CompanyMembership',
					hits: [
						{
							id: 'crm.CompanyMembership.2',
							display_name: 'Bronze plan',
							rank: 0.7,
							root_doctype: 'Company',
							root_id: 'crm.Company.1',
							root_display_name: 'Acme Corp',
							child_label: 'Bronze plan'
						}
					]
				}
			],
			meta: { q: term, count: 1, scope: 'domain' }
		};
	}

	function appWideResponse(term: string): SearchResponse {
		return {
			data: [
				{
					domain: 'hr',
					doctype: 'Employee',
					hits: [
						{
							id: 'hr.Employee.7',
							display_name: 'Alice',
							rank: 0.8,
							root_doctype: 'Employee',
							root_id: 'hr.Employee.7',
							root_display_name: 'Alice',
							child_label: null
						}
					]
				}
			],
			meta: { q: term, count: 1, scope: 'app' }
		};
	}

	interface TransportCall {
		url: string;
	}

	/** Installs a transport that answers per scope and records every call. */
	function installTransport(responder: (url: string) => Response): TransportCall[] {
		const calls: TransportCall[] = [];
		setRecordSearchTransport((async (input: string | URL | Request) => {
			const url = typeof input === 'string' ? input : input.toString();
			calls.push({ url });
			return responder(url);
		}) as unknown as typeof fetch);
		return calls;
	}

	/** Small settle budget for debounced fetches and portal restores. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	const { Story } = defineMeta({
		title: 'Components/Features/Search/CommandPalette',
		component: CommandPalette,
		tags: ['autodocs'],
		args: {
			open: true,
			commands: baseCommands,
			activeDomain: 'crm'
		}
	});
</script>

<!--
	CommandPalette — the global search surface. Bits UI `Dialog.Portal` mounts
	content into `document.body`, so the play functions query
	`within(document.body)`. Every play closes the palette at the end (or its
	own activation does) so later stories start with a clean portal.
-->

<Story
	name="GroupsRender"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);

		// The dialog is portalled and named for assistive tech.
		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());

		// All four synchronous groups render with the seeded nav model…
		await waitFor(() => {
			expect(body.getByText('Navigate')).toBeVisible();
			expect(body.getByText('Recent')).toBeVisible();
			expect(body.getByText('Actions')).toBeVisible();
		});
		// …including the active domain's doctypes under Navigate.
		expect(body.getByText('Company')).toBeVisible();
		expect(body.getByText('crm.Company')).toBeVisible();
		// The records group holds no result rows before the first search lands;
		// its only entry is the escalation row, the path to a cross-domain hit.
		expect(body.getByText('Records')).toBeVisible();
		expect(body.getByText(/Search all domains for/)).toBeVisible();
		// The recents group resolves the seeded entry through the label stub —
		// the row shows the display name, not the raw id.
		expect(body.getByText('Company North')).toBeVisible();

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="ListboxSemantics"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		await waitFor(() => expect(body.getByText('Company')).toBeVisible());

		// The input is a combobox with popup state and an owned listbox (B-392).
		const input = body.getByRole('combobox', { name: 'Search records and actions' });
		await expect(input).toHaveAttribute('aria-expanded', 'true');
		await expect(input).toHaveAttribute('aria-controls', 'palette-listbox');

		// The rows render as options; the visible group labels name their
		// `group` owners inside the listbox.
		const listbox = await waitFor(() => body.getByRole('listbox'));
		await expect(listbox).toBeVisible();
		expect(body.getAllByRole('group').length).toBeGreaterThan(0);
		const options = body.getAllByRole('option');
		expect(options.length).toBeGreaterThan(0);
		for (const option of options) {
			expect(option).toHaveAttribute('aria-selected');
		}

		// Exactly one selected option, and the input points at it.
		const selected = (): Element[] =>
			[...body.getAllByRole('option')].filter((o) => o.getAttribute('aria-selected') === 'true');
		expect(selected()).toHaveLength(1);
		const firstId = selected()[0]?.id;
		expect(firstId).toBeTruthy();
		await expect(input.getAttribute('aria-activedescendant')).toBe(firstId);

		// Arrow down moves the selection: another option is selected and
		// `aria-activedescendant` follows the highlight.
		await userEvent.keyboard('{ArrowDown}');
		const secondId = selected()[0]?.id;
		expect(secondId).toBeTruthy();
		expect(secondId).not.toBe(firstId);
		await expect(input.getAttribute('aria-activedescendant')).toBe(secondId);

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="RecentsPruneWhenGone"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);

		// A recent whose document no longer exists. The resolve loop asks the
		// API once the palette opens; the API answers 404; the entry leaves the
		// store — the raw-id row must not linger and Enter must not 404 (B-392).
		recordRecentDocument({ id: 'crm.Company.9', domain: 'crm', doctype: 'Company' });

		// Force the "gone" answer for this id only; every other URL keeps the
		// module-level label stub.
		const prevFetch = window.fetch;
		window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
			const url =
				typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
			if (url === '/Api/crm/Company/crm.Company.9') {
				return new Response(JSON.stringify({ error: 'not found' }), {
					status: 404,
					headers: { 'Content-Type': 'application/json' }
				});
			}
			return prevFetch.call(window, input, init);
		}) as typeof fetch;

		try {
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			// The failed resolve prunes the entry — the row disappears and the
			// store no longer holds it.
			await waitFor(() => expect(body.queryByText('crm.Company.9')).toBeNull());
			expect(getRecentDocuments('crm').map((d) => d.id)).not.toContain('crm.Company.9');
			// The healthy recents stay — only the gone one pruned.
			expect(body.getByText('Company North')).toBeVisible();

			await userEvent.keyboard('{Escape}');
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
		} finally {
			window.fetch = prevFetch;
		}
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="ArrowKeysHighlightAndEnterActivate"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const gotoEvents = collectGotoEvents();

		try {
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			await waitFor(() => expect(body.getByText('Company')).toBeVisible());

			// The rows render as options; the highlight is the `active` class
			// and rides `aria-activedescendant` on the input.
			const highlighted = (): Element[] =>
				[...document.body.querySelectorAll('button.palette-row')].filter((el) =>
					el.className.includes('active')
				);

			// The first row holds the highlight on open.
			await waitFor(() => expect(highlighted()).toHaveLength(1));
			const firstLabel = highlighted()[0]?.textContent;

			// ArrowDown moves the highlight to the second row…
			await userEvent.keyboard('{ArrowDown}');
			await waitFor(() => expect(highlighted()).toHaveLength(1));
			const secondLabel = highlighted()[0]?.textContent;
			expect(secondLabel).not.toBe(firstLabel);

			// …ArrowUp moves it back…
			await userEvent.keyboard('{ArrowUp}');
			await waitFor(() => expect(highlighted()[0]?.textContent).toBe(firstLabel));

			// …ArrowDown again, then Enter activates the highlighted row.
			await userEvent.keyboard('{ArrowDown}');
			await userEvent.keyboard('{Enter}');
			await waitFor(() => expect(gotoEvents.urls.length).toBeGreaterThan(0));
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
		} finally {
			gotoEvents.done();
		}
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="HighlightSurvivesSameRowsChurn"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		await waitFor(() => expect(body.getByText('Company')).toBeVisible());

		const highlighted = (): Element[] =>
			[...document.body.querySelectorAll('button.palette-row')].filter((el) =>
				el.className.includes('active')
			);
		await waitFor(() => expect(highlighted()).toHaveLength(1));

		// Walk down two rows, then rebuild the nav model with the same
		// domains and doctypes (a fresh array, like a backend-driven nav
		// rebuild). The row keys are unchanged, so the highlight must hold.
		await userEvent.keyboard('{ArrowDown}');
		await userEvent.keyboard('{ArrowDown}');
		const moved = highlighted()[0]?.textContent;
		expect(moved).toBeTruthy();

		setLiveNav([
			{
				id: 'crm',
				label: 'Customer Relations',
				color: '#2196F3',
				doctypes: [
					{ qualified: 'crm.Company', label: 'Company', color: '#2196F3', icon: null },
					{ qualified: 'crm.Contact', label: 'Contact', color: '#4CAF50', icon: null }
				]
			},
			{
				id: 'hr',
				label: 'Human Resources',
				color: '#E91E63',
				doctypes: [{ qualified: 'hr.Employee', label: 'Employee', color: '#E91E63' }]
			}
		]);

		await sleep(100);
		expect(highlighted()).toHaveLength(1);
		expect(highlighted()[0]?.textContent).toBe(moved);

		// A later query edit still resets the selection to the first row.
		const input = body.getByRole('combobox', { name: 'Search records and actions' });
		await userEvent.type(input, 'comp');
		await sleep(50);
		await waitFor(() => expect(highlighted()).toHaveLength(1));

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="CtrlKOpensThenKeyboardWorks"
	args={{ open: false }}
	play={async () => {
		const body = within(document.body);
		const gotoEvents = collectGotoEvents();

		try {
			// The app path: the palette is mounted closed and Ctrl+K opens it
			// through the component-owned window listener.
			await expect(body.queryByRole('dialog')).toBeNull();
			await userEvent.keyboard('{Control>}k{/Control}');
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			await waitFor(() => expect(body.getByText('Company')).toBeVisible());

			await userEvent.keyboard('{ArrowDown}');
			await userEvent.keyboard('{ArrowDown}');
			await userEvent.keyboard('{Enter}');
			await waitFor(() => expect(gotoEvents.urls.length).toBeGreaterThan(0));
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
		} finally {
			gotoEvents.done();
		}
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="ArrowAfterQueryActivatesRecord"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(domainResponse('acme')));
		const gotoEvents = collectGotoEvents();

		try {
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			const input = body.getByRole('combobox', { name: 'Search records and actions' });
			await userEvent.type(input, 'acme');
			await sleep(500);
			await waitFor(() => expect(body.getByText('Acme Corp')).toBeVisible());

			const highlighted = (): Element[] =>
				[...document.body.querySelectorAll('button.palette-row')].filter((el) =>
					el.className.includes('active')
				);
			await waitFor(() => expect(highlighted()).toHaveLength(1));

			// Walk down to the record row and activate it with Enter. With the
			// 'acme' query only the records group survives the filter, so the
			// first row is the record and one Enter activates it.
			await userEvent.keyboard('{Enter}');
			await waitFor(() =>
				expect(gotoEvents.urls.some((u) => u.includes('/crm/Company/crm.Company.1'))).toBe(true)
			);
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
			expect(calls).toHaveLength(1);
		} finally {
			gotoEvents.done();
		}
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyQueryShowsSynchronousGroups"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(domainResponse('')));

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		await sleep(400); // longer than the search debounce

		// No fetch ever fired: the records group holds only its escalation
		// row, no result rows.
		expect(calls).toHaveLength(0);
		expect(body.getByText('Records')).toBeVisible();
		expect(body.getByText(/Search all domains for/)).toBeVisible();
		// The synchronous groups render.
		expect(body.getByText('Navigate')).toBeVisible();
		expect(body.getByText('Actions')).toBeVisible();

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="GroupsFilterOnQuery"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(domainResponse('comp')));

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		const input = body.getByRole('combobox', { name: 'Search records and actions' });
		await userEvent.type(input, 'comp');
		await sleep(400);

		// Navigate filtered down to the matching doctype…
		await waitFor(() => expect(body.getAllByText('Company').length).toBeGreaterThan(0));
		expect(body.queryByText('Human Resources')).toBeNull();
		// …the recents label matched too…
		expect(body.getByText('Company North')).toBeVisible();
		// …and the records group appeared once the (single) search landed.
		expect(calls).toHaveLength(1);
		expect(calls[0]?.url).toBe('/Api/crm/search?q=comp');
		expect(body.getByText('Records')).toBeVisible();
		expect(body.getByText('Acme Corp')).toBeVisible();
		// The escalation row rides last in the records group.
		expect(body.getByText('Search all domains for “comp”')).toBeVisible();

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="KeyboardNavigatesAndActivates"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(domainResponse('')));
		const gotoEvents = collectGotoEvents();

		try {
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			await userEvent.click(body.getByRole('combobox', { name: 'Search records and actions' }));

			// Two rows down from the first Navigate row lands on the active
			// domain's first doctype (domains first, then doctypes).
			await userEvent.keyboard('{ArrowDown}');
			await userEvent.keyboard('{ArrowDown}');
			await userEvent.keyboard('{Enter}');

			// Activation navigated to the doctype table and closed the palette.
			await waitFor(() => {
				expect(gotoEvents.urls.some((u) => u.includes('/crm/Company'))).toBe(true);
			});
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
			expect(calls).toHaveLength(0); // keyboard-only flow never searched
		} finally {
			gotoEvents.done();
		}

		// The component-owned keybind reopens the palette.
		await sleep(100); // let the portal restore settle
		await userEvent.keyboard('{Control>}k{/Control}');
		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());

		// An action row runs its command and closes. The accessible name
		// carries the row's group tag, so match on the label part.
		runSpy.mockClear();
		await userEvent.click(body.getByRole('option', { name: /Show keyboard shortcuts/ }));
		await waitFor(() => expect(runSpy).toHaveBeenCalled());
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="RecordsOneCallPerBurst"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(domainResponse('acme')));

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		const input = body.getByRole('combobox', { name: 'Search records and actions' });

		// One burst: the intermediate term never issues its own request — the
		// debounce folds the whole typing sequence into one call.
		await userEvent.type(input, 'acm');
		await sleep(100); // inside the debounce window
		await userEvent.type(input, 'e');
		await sleep(500);

		expect(calls).toHaveLength(1);
		expect(calls[0]?.url).toBe('/Api/crm/search?q=acme');
		await waitFor(() => expect(body.getByText('Acme Corp')).toBeVisible());

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="EscalationRowReRunsAppWide"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport((url) =>
			url.startsWith('/Api/search') ? json(appWideResponse('acme')) : json(domainResponse('acme'))
		);

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		const input = body.getByRole('combobox', { name: 'Search records and actions' });
		await userEvent.type(input, 'acme');
		await sleep(500);

		// Domain scope first: one call against the domain route, the
		// escalation row visible, no chip yet.
		expect(calls).toHaveLength(1);
		expect(calls[0]?.url).toBe('/Api/crm/search?q=acme');
		const escalate = body.getByRole('option', { name: 'Search all domains for “acme”' });
		expect(body.queryByText('All domains')).toBeNull();

		// Escalate: the query re-runs against the app-wide route and the
		// scope chip appears.
		await userEvent.click(escalate);
		await waitFor(() => {
			expect(calls.some((c) => c.url === '/Api/search?q=acme')).toBe(true);
		});
		await waitFor(() => expect(body.getByText('All domains')).toBeVisible());
		// The app-wide hit rendered; its row tag is domain-qualified.
		await waitFor(() => expect(body.getByText('Alice')).toBeVisible());
		expect(body.getByText('hr · Employee')).toBeVisible();
		// The escalation row is gone — the palette is already app-wide.
		expect(body.queryByRole('option', { name: 'Search all domains for “acme”' })).toBeNull();

		// The chip returns to the active domain and re-runs.
		await userEvent.click(body.getByRole('button', { name: 'All domains' }));
		await waitFor(() => {
			expect(calls.filter((c) => c.url === '/Api/crm/search?q=acme').length).toBe(2);
		});
		await waitFor(() => expect(body.queryByText('All domains')).toBeNull());
		await waitFor(() => expect(body.getByText('Acme Corp')).toBeVisible());

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="ChildHitRendersAsRootEntry"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		const calls = installTransport(() => json(childHitResponse('bronze')));
		const gotoEvents = collectGotoEvents();

		try {
			await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
			const input = body.getByRole('combobox', { name: 'Search records and actions' });
			await userEvent.type(input, 'bronze');
			await sleep(500);

			expect(calls).toHaveLength(1);
			// The row reads as the aggregate root, with the matched child as
			// the subtitle.
			const row = body.getByRole('option', { name: /Acme Corp/ });
			expect(row.textContent).toContain('CompanyMembership · Bronze plan');
			expect(row.textContent).toContain('Company');

			// Activation lands on the root's page, not the child's.
			await userEvent.click(row);
			await waitFor(() => {
				expect(gotoEvents.urls.some((u) => u.includes('/crm/Company/crm.Company.1'))).toBe(true);
			});
			await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
		} finally {
			gotoEvents.done();
		}
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>

<Story
	name="FailedSearchDropsRecordsGroup"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		installTransport(() => new Response(null, { status: 500 }));

		await waitFor(() => expect(body.getByRole('dialog')).toBeVisible());
		const input = body.getByRole('combobox', { name: 'Search records and actions' });
		await userEvent.type(input, 'comp');
		await sleep(500);

		// No error state: the records group keeps only its escalation row — no
		// result rows, no message — while the synchronously filtered groups
		// stay usable.
		expect(body.getByText('Records')).toBeVisible();
		expect(body.getByText(/Search all domains for/)).toBeVisible();
		expect(body.getAllByText('Company').length).toBeGreaterThan(0);
		expect(body.getByText('Company North')).toBeVisible();
		expect(body.queryByText('Search all domains for')).toBeNull();

		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(body.queryByRole('dialog')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<CommandPalette open={args.open} commands={baseCommands} activeDomain={args.activeDomain} />
		</div>
	{/snippet}
</Story>
