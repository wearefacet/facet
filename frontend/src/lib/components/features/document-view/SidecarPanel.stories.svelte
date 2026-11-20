<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import SidecarPanel from './SidecarPanel.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';

	/**
	 * SidecarPanel stories mount the panel with the built-in comment surface
	 * registered (the panel imports `features/sidecar/surfaces.js` itself).
	 * Each variant gets its own driver so the host definition's `sidecars`
	 * wiring can differ per story: one entry (no tab strip), two entries
	 * (tab strip + counts), label and order overrides.
	 *
	 * `core.Comment` carries `surface: 'comment'`; `core.Note` is registered
	 * without a definition on purpose — its surface falls back to the basic
	 * DVT surface and its rows degrade to capsules.
	 */
	function makeDriver(
		sidecars: Record<string, Record<string, unknown>>,
		comments: { id: string; body: string }[]
	): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Deal', {
			doctype: 'Deal',
			domain: 'crm',
			sidecar: true,
			sidecars
		});
		driver.registerDoctype('core', 'Comment', {
			doctype: 'Comment',
			domain: 'core',
			surface: 'comment',
			display_name: '$body',
			fields: {
				target: { key: 'target', type: 'reference', read_only: true, title: 'Target' },
				author: { key: 'author', type: 'reference', read_only: true, title: 'Author' },
				body: { key: 'body', type: 'longtext', title: 'Body' }
			}
		});
		void driver.domain('crm').doctype('Deal', [{ id: 'crm.Deal.1', name: 'Platform License' }]);
		if (comments.length > 0) {
			void driver.domain('core').doctype(
				'Comment',
				comments.map((c) => ({ ...c, target: 'crm.Deal.crm.Deal.1' }))
			);
		}
		// Seeded under `core` — the mock sidecar store scopes by the sidecar
		// doctype's qualified parts (`core.Note` → domain `core`).
		void driver.domain('core').doctype('Note', [
			{ id: 'n1', title: 'Kickoff summary', target: 'crm.Deal.crm.Deal.1' },
			{ id: 'n2', title: 'Follow-up actions', target: 'crm.Deal.crm.Deal.1' }
		]);
		return driver;
	}

	function hostDefFor(driver: MockDataDriver): DoctypeDef {
		return parseDoctypeDef(driver.getDoctypeDefinition('crm.Deal') as Record<string, unknown>);
	}

	function hostDoc(): DocumentResponse {
		const now_ = new Date().toISOString();
		return {
			data: { name: 'Platform License' },
			meta: {
				id: 'crm.Deal.1',
				mid: 'crm.Deal.1',
				domain: 'crm',
				doc_type: 'Deal',
				version: 1,
				schema_version: 1,
				display_name: 'Platform License',
				created_at: now_,
				updated_at: now_
			}
		};
	}

	const seededComments = [
		{ id: 'c1', body: 'First comment on the deal' },
		{ id: 'c2', body: 'Second comment with more detail' }
	];

	// One sidecar only — no tab strip.
	const oneDriver = makeDriver(
		{ comments: { doctype: 'core.Comment', column: 'target' } },
		seededComments
	);
	const oneDef = hostDefFor(oneDriver);

	// Two sidecars — tab strip with count badges. `core.Note` has no surface
	// id → resolves to the DVT fallback surface (capsule rows).
	const twoDriver = makeDriver(
		{
			comments: { doctype: 'core.Comment', column: 'target' },
			notes: { doctype: 'core.Note', column: 'target' }
		},
		seededComments
	);
	const twoDef = hostDefFor(twoDriver);

	// Label override: the tab reads "Notes" instead of humanize("attachments").
	const labelDriver = makeDriver(
		{
			comments: { doctype: 'core.Comment', column: 'target' },
			attachments: { doctype: 'core.Note', column: 'target', label: 'Notes' }
		},
		seededComments
	);
	const labelDef = hostDefFor(labelDriver);

	// Order override: notes (order 0) sort before comments (order 5) even
	// though the definition lists comments first.
	const orderDriver = makeDriver(
		{
			comments: { doctype: 'core.Comment', column: 'target', order: 5 },
			notes: { doctype: 'core.Note', column: 'target', order: 0 }
		},
		seededComments
	);
	const orderDef = hostDefFor(orderDriver);

	// Zero sidecars — the panel renders nothing.
	const noneDriver = makeDriver({}, seededComments);
	const noneDef = hostDefFor(noneDriver);

	/** Unrestricted creator/updater — composer and affordances are visible. */
	const adminManifest = { '*.*': ['*'] };

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/SidecarPanel',
		component: SidecarPanel,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within, fireEvent } from 'storybook/test';
</script>

<Story
	name="NoSidecars"
	play={async ({ canvasElement }) => {
		await sleep(300);
		// Nothing renders — the show route collapses the two-column layout.
		expect(canvasElement.querySelector('[data-sidecar-panel]')).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarPanel driver={noneDriver} def={noneDef} doc={hostDoc()} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="OneSidecar"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// A single entry renders the surface directly — no tab strip.
		await expect(canvas.queryByRole('tab')).toBeNull();
		await expect(canvas.getByText('First comment on the deal')).toBeVisible();
		await expect(canvas.getByText('Second comment with more detail')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarPanel driver={oneDriver} def={oneDef} doc={hostDoc()} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="TwoSidecarsTabSwitching"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// Comments tab is active first; its count badge shows 2.
		const commentsTab = canvas.getByRole('tab', { name: /Comments/ });
		await expect(commentsTab).toHaveAttribute('aria-selected', 'true');
		await expect(canvas.getByText('First comment on the deal')).toBeVisible();

		// Switching to Notes shows the fallback DVT surface's capsule rows and
		// unmounts the comment thread.
		const notesTab = canvas.getByRole('tab', { name: /Notes/ });
		await fireEvent.click(notesTab);
		await sleep(200);
		await expect(notesTab).toHaveAttribute('aria-selected', 'true');
		await expect(canvas.getByText('Kickoff summary')).toBeVisible();
		await expect(canvas.queryByText('First comment on the deal')).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarPanel driver={twoDriver} def={twoDef} doc={hostDoc()} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="LabelOverride"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// The host-owned `label: "Notes"` overrides humanize("attachments").
		await expect(canvas.getByRole('tab', { name: /Notes/ })).toBeVisible();
		await expect(canvas.queryByRole('tab', { name: /Attachments/ })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarPanel driver={labelDriver} def={labelDef} doc={hostDoc()} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="OrderOverride"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// notes (order 0) sort before comments (order 5): the first tab is
		// Notes and the Notes surface is the initially active one.
		const tabs = canvas.getAllByRole('tab');
		await expect(tabs[0]).toHaveAccessibleName(/Notes/);
		await expect(tabs[0]).toHaveAttribute('aria-selected', 'true');
		await expect(canvas.getByText('Kickoff summary')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarPanel driver={orderDriver} def={orderDef} doc={hostDoc()} />
			</div>
		</CanFixture>
	{/snippet}
</Story>
