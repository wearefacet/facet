<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import DomainEditorsTab from './DomainEditorsTab.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { MockDataDriver } from '$lib/datasource/MockDriver';
	import type { ListItem } from '$lib/datasource/types.js';
	import type { DomainEditorContent } from './domainSecurity.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/DomainEditorsTab',
		component: DomainEditorsTab,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	/** Seed one `core.DomainEditor` grant row into a mock driver. */
	function seedEditorRow(
		driver: MockDataDriver,
		id: string,
		accountId: string,
		domainId: string
	): void {
		const now_ = new Date().toISOString();
		driver.docs.set(id, {
			id,
			domain: 'core',
			doc_type: 'DomainEditor',
			content: { account: `iam.Account.${accountId}`, domain: domainId },
			version: 1,
			schema_version: 1,
			created_at: now_,
			updated_at: now_,
			mutations: [],
			deleted_at: null
		});
	}

	/** List the grant rows of one domain through the driver (live rows only). */
	async function listRows(
		driver: MockDataDriver,
		domainId: string
	): Promise<ListItem<DomainEditorContent>[]> {
		const res = await driver
			.domain('core')
			.doctype<DomainEditorContent>('DomainEditor')
			.list({ filters: { domain__eq: domainId }, items: 1000 });
		return res.data;
	}
</script>

<!--
	The tab reads accounts through the registry (the mock driver seeds the
	`iam.Account` fixtures) and takes its rows from the parent. Each story
	hydrates the permission store through `CanFixture` — the manifest decides
	whether the add/remove affordances render, mirroring the backend's
	admin-only carve-out of `core.DomainEditor` from the editor role.
-->

<script lang="ts">
	const driver = createMockDriver();
	seedEditorRow(driver, 'de_pm_alex', 'account_pm_alex', 'crm');
	seedEditorRow(driver, 'de_dao', 'account_eng_dao', 'crm');

	// Rows the parent would hold — refreshed through the harness on reload.
	// The remove scenario keeps a single row so its Remove button is unique.
	let crmRows = $state<ListItem<DomainEditorContent>[]>([]);
	let emptyRows = $state<ListItem<DomainEditorContent>[]>([]);
	let removeRows = $state<ListItem<DomainEditorContent>[]>([]);

	$effect(() => {
		void (async () => {
			crmRows = await listRows(driver, 'crm');
			removeRows = (await listRows(driver, 'crm')).filter((r) => r.meta.id === 'de_pm_alex');
		})();
	});

	const crmReload = fn(async () => {
		crmRows = await listRows(driver, 'crm');
	});
	const emptyReload = fn();
	const removeReload = fn(async () => {
		removeRows = (await listRows(driver, 'crm')).filter((r) => r.meta.id === 'de_pm_alex');
	});
</script>

<Story
	name="Editors"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Section title + helper.
		await expect(canvas.getByText('Domain editors')).toBeVisible();
		// The two grant rows resolve to the fixture accounts' display names.
		await waitFor(() => {
			expect(canvas.getByText('Alex Okafor')).toBeVisible();
			expect(canvas.getByText('Dao Chen')).toBeVisible();
		});
		// The add picker is present but inert until an account is selected.
		const addBtn = canvas.getByRole('button', { name: 'Add editor' });
		expect(addBtn).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<DomainEditorsTab registry={driver} domain="crm" rows={crmRows} onreload={crmReload} />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="AddFlow"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByPlaceholderText('Add an editor to this domain…');
		await userEvent.click(input);
		// The dropdown portals to document.body — pick Kim Nguyen there.
		const body = within(document.body);
		await userEvent.click(body.getByText('Kim Nguyen'));
		const addBtn = canvas.getByRole('button', { name: 'Add editor' });
		await expect(addBtn).toBeEnabled();
		await userEvent.click(addBtn);
		await waitFor(() => {
			expect(emptyReload).toHaveBeenCalledOnce();
		});
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<DomainEditorsTab registry={driver} domain="crm" rows={emptyRows} onreload={emptyReload} />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="RemoveFlow"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The rows arrive through the parent's async read — wait for the row
		// before interacting.
		await waitFor(() => {
			expect(canvas.getByText('Alex Okafor')).toBeVisible();
		});
		await userEvent.click(canvas.getByRole('button', { name: 'Remove' }));
		await waitFor(() => {
			expect(removeReload).toHaveBeenCalledOnce();
		});
		// The mock driver soft-deleted the grant row.
		const doc = driver.docs.get('de_pm_alex') as { deleted_at: string | null } | undefined;
		expect(doc?.deleted_at).not.toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<DomainEditorsTab registry={driver} domain="crm" rows={removeRows} onreload={removeReload} />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(/No editors on this domain yet\./)).toBeVisible();
		// The picker renders for an administrator; the add button stays
		// disabled until an account is picked in the combobox.
		expect(canvas.getByPlaceholderText('Add an editor to this domain…')).toBeVisible();
		expect(canvas.getByRole('button', { name: 'Add editor' })).toBeDisabled();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<DomainEditorsTab registry={driver} domain="crm" rows={[]} onreload={emptyReload} />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Read stays blanket: the list renders for any role…
		await waitFor(() => {
			expect(canvas.getByText('Alex Okafor')).toBeVisible();
		});
		// …but the manage affordances stay hidden without the grants.
		expect(canvas.queryByPlaceholderText('Add an editor to this domain…')).toBeNull();
		expect(canvas.queryByRole('button', { name: 'Add editor' })).toBeNull();
		expect(canvas.queryByRole('button', { name: 'Remove' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['read'] }}>
			<DomainEditorsTab registry={driver} domain="crm" rows={crmRows} onreload={crmReload} />
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="SystemDomain"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(/The application manages the system domains\./)).toBeVisible();
		expect(canvas.queryByRole('button', { name: 'Add editor' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ '*.*': ['*'] }}>
			<DomainEditorsTab registry={driver} domain="core" rows={[]} onreload={emptyReload} />
		</CanFixture>
	{/snippet}
</Story>
