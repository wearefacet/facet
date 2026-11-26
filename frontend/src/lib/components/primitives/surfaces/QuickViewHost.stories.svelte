<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import QuickViewHost from './QuickViewHost.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { DataSourceError } from '$lib/datasource/types.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import * as m from '$lib/paraglide/messages';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/QuickViewHost',
		component: QuickViewHost,
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const STUB_ROOT_DEF: DoctypeDef = {
		domain: 'crm',
		doctype: 'Company',
		fields: [],
		children: [],
		actions: []
	};

	// A driver with one tombstoned membership: the registry knows the doctype
	// so the drawer resolves the def, then `show()` fails with the backend's
	// `410` tombstone contract (label + timestamp, no content).
	const driver = new MockDataDriver();
	driver.registerDoctype('crm', 'CompanyMembership', {
		domain: 'crm',
		doctype: 'CompanyMembership',
		fields: {
			name: { key: 'name', type: 'string' },
			// Self-reference: the drawer's fallback body hydrates it into a
			// clickable capsule that pushes a second nav entry.
			manager: { key: 'manager', type: 'reference', doctype: 'crm.CompanyMembership' }
		}
	});

	const seedDeleted = async () => {
		const ds = driver.domain('crm').doctype('CompanyMembership');
		const created = await ds.create({ name: 'secondary at Bob Williams' });
		await ds.doc(created.meta.id).delete();
		return created.meta.id;
	};

	let deletedId: string | null = null;

	async function ensureSeed(): Promise<string> {
		deletedId ??= await seedDeleted();
		return deletedId;
	}

	/** A live (non-tombstoned) membership for the drawer to display. */
	let liveId: string | null = null;

	async function ensureLiveSeed(): Promise<string> {
		if (liveId === null) {
			const created = await driver
				.domain('crm')
				.doctype('CompanyMembership')
				.create({ name: 'primary at Acme Ltd' });
			liveId = created.meta.id;
		}
		return liveId;
	}

	/**
	 * A reference target whose doctype is absent from the registry (the
	 * RBAC-scoped `core.DocType` list omits it) and whose REST read answers
	 * `403` — the caller lacks the read grant. The peek must say "no access",
	 * not "not found in registry".
	 */
	let forbiddenId: string | null = null;

	async function ensureForbiddenSeed(): Promise<string> {
		if (forbiddenId === null) {
			const ds = driver.domain('pay').doctype('Payroll');
			const created = await ds.create({ name: 'March payroll' });
			forbiddenId = created.meta.id;
			const originalDoc = ds.doc.bind(ds);
			ds.doc = (id: string) =>
				new Proxy(originalDoc(id), {
					get(target, prop, receiver) {
						if (prop === 'show') {
							return () => Promise.reject(new DataSourceError(403, 'Forbidden'));
						}
						const value = Reflect.get(target, prop, receiver);
						return typeof value === 'function' ? value.bind(target) : value;
					}
				});
		}
		return forbiddenId;
	}

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

	/**
	 * Two live memberships linked by reference — `crm.CompanyMembership`
	 * references itself (`manager`), so opening one in the drawer and following
	 * the `manager` capsule pushes a second nav entry.
	 */
	let linkedIds: { first: string; second: string } | null = null;

	async function ensureLinkedSeed(): Promise<{ first: string; second: string }> {
		if (linkedIds === null) {
			const ds = driver.domain('crm').doctype('CompanyMembership');
			const second = await ds.create({ name: 'primary at Initech' });
			const first = await ds.create({
				name: 'secondary at Initech',
				manager: `crm.CompanyMembership.${second.meta.id}`
			});
			linkedIds = { first: first.meta.id, second: second.meta.id };
		}
		return linkedIds;
	}
</script>

<!--
	The QuickViewHost wraps a host surface and hands it `openReference` /
	`openRootDoc`. This story covers the tombstone path: the requested document
	exists as a tombstone, so the drawer renders a deleted card with a Restore
	affordance instead of the raw error.
-->
<Story
	name="DeletedReferenceShowsRestoreCard"
	play={async () => {
		const id = await ensureSeed();
		const canvas = within(document.body);
		await userEvent.click(canvas.getByRole('button', { name: 'Open deleted document' }));
		// The deleted card: surviving label, tombstone badge, dated note.
		await waitFor(() => expect(canvas.getByText('secondary at Bob Williams')).toBeVisible());
		await expect(canvas.getByText('Deleted')).toBeVisible();
		await expect(canvas.getByText(/This document has been deleted/)).toBeVisible();
		// Restore runs the full loop: the mock clears the tombstone and the
		// drawer loads the live document.
		await userEvent.click(canvas.getByRole('button', { name: 'Restore' }));
		await waitFor(() => expect(canvas.getByText('v1')).toBeVisible());
		expect(id).toBeTruthy();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'crm.CompanyMembership': ['update'] }}>
			{#await ensureSeed() then id}
				<div style="min-height: 480px; padding: 16px;">
					<QuickViewHost {driver} rootDef={STUB_ROOT_DEF} rootParentDocId="crm.Company">
						{#snippet trigger(api)}
							<button
								type="button"
								onclick={() =>
									api.openReference({ domain: 'crm', doctype: 'CompanyMembership', id })}
							>
								Open deleted document
							</button>
						{/snippet}
					</QuickViewHost>
				</div>
			{/await}
		</CanFixture>
	{/snippet}
</Story>

<!--
	An unreadable reference: the doctype is absent from the RBAC-scoped
	registry, and the REST read answers `403`. The peek must name the access
	cause instead of claiming the doctype is unknown.
-->
<Story
	name="UnreadableReferenceShowsNoAccess"
	play={async () => {
		await ensureForbiddenSeed();
		const canvas = within(document.body);
		await userEvent.click(canvas.getByRole('button', { name: 'Open unreadable document' }));
		await waitFor(() => expect(canvas.getByText(m.errors_reference_no_access())).toBeVisible());
		await expect(canvas.queryByText(/not found in registry/)).toBeNull();
	}}
>
	{#snippet template()}
		{#await ensureForbiddenSeed() then id}
			<div style="min-height: 480px; padding: 16px;">
				<QuickViewHost {driver} rootDef={STUB_ROOT_DEF} rootParentDocId="crm.Company">
					{#snippet trigger(api)}
						<button
							type="button"
							onclick={() => api.openReference({ domain: 'pay', doctype: 'Payroll', id })}
						>
							Open unreadable document
						</button>
					{/snippet}
				</QuickViewHost>
			</div>
		{/await}
	{/snippet}
</Story>

<!--
	With the drawer open, Enter opens the displayed document's full show page
	(the same target as the header's external-link affordance). The trigger
	button is blurred first — a focused control owns Enter natively, and the
	shortcut must not steal it.
-->
<Story
	name="EnterWithDrawerOpenNavigatesToShowPage"
	play={async () => {
		const id = await ensureLiveSeed();
		const canvas = within(document.body);
		await userEvent.click(canvas.getByRole('button', { name: 'Open live document' }));
		await waitFor(() =>
			expect(canvas.getAllByText('primary at Acme Ltd').length).toBeGreaterThan(0)
		);
		// Move focus off the trigger button — a focused button would keep its
		// native Enter click (the button re-opens the drawer instead).
		(document.activeElement as HTMLElement | null)?.blur();
		const gotoEvents = collectGotoEvents();
		try {
			await userEvent.keyboard('{Enter}');
			await waitFor(() => {
				expect(gotoEvents.urls.some((u) => u.includes(`/crm/CompanyMembership/${id}`))).toBe(true);
			});
		} finally {
			gotoEvents.done();
		}
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'crm.CompanyMembership': ['update'] }}>
			{#await ensureLiveSeed() then id}
				<div style="min-height: 480px; padding: 16px;">
					<QuickViewHost {driver} rootDef={STUB_ROOT_DEF} rootParentDocId="crm.Company">
						{#snippet trigger(api)}
							<button
								type="button"
								onclick={() =>
									api.openReference({ domain: 'crm', doctype: 'CompanyMembership', id })}
							>
								Open live document
							</button>
						{/snippet}
					</QuickViewHost>
				</div>
			{/await}
		</CanFixture>
	{/snippet}
</Story>

<!--
	Escape closes the peek drawer from anywhere on the page — including from
	the row the table still highlights after opening it (the table's own
	Escape would otherwise only clear that highlight).
-->
<Story
	name="EscapeClosesDrawer"
	play={async () => {
		await ensureLiveSeed();
		const canvas = within(document.body);
		await userEvent.click(canvas.getByRole('button', { name: 'Open live document' }));
		await waitFor(() =>
			expect(canvas.getByRole('link', { name: m.doc_peek_open_aria() })).toBeVisible()
		);
		await userEvent.keyboard('{Escape}');
		// The drawer slides out, then drops its content.
		await waitFor(() =>
			expect(canvas.queryByRole('link', { name: m.doc_peek_open_aria() })).toBeNull()
		);
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'crm.CompanyMembership': ['update'] }}>
			{#await ensureLiveSeed() then id}
				<div style="min-height: 480px; padding: 16px;">
					<QuickViewHost {driver} rootDef={STUB_ROOT_DEF} rootParentDocId="crm.Company">
						{#snippet trigger(api)}
							<button
								type="button"
								onclick={() =>
									api.openReference({ domain: 'crm', doctype: 'CompanyMembership', id })}
							>
								Open live document
							</button>
						{/snippet}
					</QuickViewHost>
				</div>
			{/await}
		</CanFixture>
	{/snippet}
</Story>

<!--
	Escape walks the nav stack back: after following a reference, the first
	Escape returns to the previous document (header Back still shown), the
	second closes the drawer.
-->
<Story
	name="EscapePopsBackThenCloses"
	play={async () => {
		await ensureLinkedSeed();
		const canvas = within(document.body);
		// The identity title names the document the drawer displays.
		const title = (name: string) => canvas.getByRole('heading', { name, level: 2 });
		await userEvent.click(canvas.getByRole('button', { name: 'Open linked document' }));
		await waitFor(() => expect(title('secondary at Initech')).toBeVisible());
		// Follow the `manager` reference onto the second document.
		const manager = await waitFor(() => canvas.getByRole('button', { name: /primary at Initech/ }));
		await userEvent.click(manager);
		await waitFor(() => expect(title('primary at Initech')).toBeVisible());
		// First Escape: back to the first document, drawer still open.
		await userEvent.keyboard('{Escape}');
		await waitFor(() => expect(title('secondary at Initech')).toBeVisible());
		// Second Escape: the stack holds one entry — the drawer closes.
		await userEvent.keyboard('{Escape}');
		await waitFor(() =>
			expect(canvas.queryByRole('link', { name: m.doc_peek_open_aria() })).toBeNull()
		);
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'crm.CompanyMembership': ['update'] }}>
			{#await ensureLinkedSeed() then ids}
				<div style="min-height: 480px; padding: 16px;">
					<QuickViewHost {driver} rootDef={STUB_ROOT_DEF} rootParentDocId="crm.Company">
						{#snippet trigger(api)}
							<button
								type="button"
								onclick={() =>
									api.openReference({ domain: 'crm', doctype: 'CompanyMembership', id: ids.first })}
							>
								Open linked document
							</button>
						{/snippet}
					</QuickViewHost>
				</div>
			{/await}
		</CanFixture>
	{/snippet}
</Story>
