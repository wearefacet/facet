<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import BacklinksPanel from './BacklinksPanel.svelte';
	import { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { BackrefItem } from '$lib/datasource/types.js';

	/**
	 * BacklinksPanel stories drive the panel through a `MockDataDriver` whose
	 * target doctype store carries registered backlink rows (`onBackrefs` —
	 * the mock's stand-in for the backend `links`-column derivation).
	 *
	 * Variants: populated (same-domain + cross-domain referrers), capped
	 * (the "more" hint), and empty (the section self-hides).
	 */
	function makeDriver(docId: string, backrefs: BackrefItem[]): MockDataDriver {
		const driver = new MockDataDriver();
		const teams = driver
			.domain('bref')
			.doctype('Team', [{ id: docId, name: 'Core' }]) as MockDataSource<{
			id: string;
			name: string;
		}>;
		teams.onBackrefs(docId, backrefs);
		return driver;
	}

	const docId = 't1';

	const populatedRefs: BackrefItem[] = [
		{ id: 'p1', domain: 'bref', doc_type: 'Project', display_name: 'Apollo rollout' },
		{ id: 'p2', domain: 'bref', doc_type: 'Project', display_name: 'Helios migration' },
		{ id: 'n1', domain: 'brefx', doc_type: 'Note', display_name: 'Kickoff summary' }
	];

	const populatedDriver = makeDriver(docId, populatedRefs);
	// Three registered rows against a two-row cap — the third surfaces as
	// the "more" hint.
	const cappedDriver = makeDriver(docId, populatedRefs);
	const emptyDriver = makeDriver(docId, []);

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/BacklinksPanel',
		component: BacklinksPanel,
		tags: ['autodocs']
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
</script>

<Story
	name="Populated"
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Referenced by')).toBeVisible();
		// One row per referrer, labelled by display_name with the doctype tag.
		await expect(canvas.getByText('Apollo rollout')).toBeVisible();
		await expect(canvas.getByText('Helios migration')).toBeVisible();
		// Cross-domain referrers ride the same list.
		await expect(canvas.getByText('Kickoff summary')).toBeVisible();
		// Each row links to the referrer's show route.
		const link = canvas.getByRole('link', { name: /Apollo rollout/ });
		await expect(link.getAttribute('href')).toContain('/bref/Project/p1');
	}}
>
	{#snippet template()}
		<div style="max-width: 480px; padding: 24px;">
			<BacklinksPanel driver={populatedDriver} domain="bref" docType="Team" {docId} />
		</div>
	{/snippet}
</Story>

<Story
	name="Capped"
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Referenced by')).toBeVisible();
		// Two rows render; the third is summarized by the "more" hint.
		await expect(canvas.getByText('Apollo rollout')).toBeVisible();
		await expect(canvas.getByText('Helios migration')).toBeVisible();
		await expect(canvas.queryByText('Kickoff summary')).toBeNull();
		await expect(canvas.getByText(/2 more|2 de plus/)).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="max-width: 480px; padding: 24px;">
			<BacklinksPanel driver={cappedDriver} domain="bref" docType="Team" {docId} items={2} />
		</div>
	{/snippet}
</Story>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		// No referrers — the section self-hides instead of rendering a
		// placeholder.
		await expect(canvas.queryByText('Referenced by')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="max-width: 480px; padding: 24px;">
			<BacklinksPanel driver={emptyDriver} domain="bref" docType="Team" {docId} />
		</div>
	{/snippet}
</Story>
