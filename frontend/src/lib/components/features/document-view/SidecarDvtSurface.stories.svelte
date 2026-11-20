<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import SidecarDvtSurface from './SidecarDvtSurface.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { TemplateNode } from '$lib/template-types';

	/**
	 * One shared driver per fixture family: `crm.Comment` (with an `inline`
	 * document view) drives the template rows and the empty state, while
	 * `crm.Note` has no definition and no views — it exercises the capsule
	 * fallback. The sidecar records carry the host reference in both forms
	 * the mock forgives (qualified and bare).
	 */
	function makeDriver(seedComments: boolean = true): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Deal', {
			doctype: 'Deal',
			domain: 'crm',
			sidecar: true,
			sidecars: {
				comments: { doctype: 'crm.Comment', column: 'target' },
				notes: { doctype: 'crm.Note', column: 'target' }
			}
		});
		driver.registerDoctype('crm', 'Comment', {
			doctype: 'Comment',
			domain: 'crm',
			display_name: '$body',
			fields: {
				target: { key: 'target', type: 'reference', read_only: true, title: 'Target' },
				author: { key: 'author', type: 'reference', read_only: true, title: 'Author' },
				body: { key: 'body', type: 'longtext', title: 'Body' }
			}
		});
		void driver.domain('crm').doctype('Deal', [{ id: 'crm.Deal.1', name: 'Platform License' }]);
		if (seedComments) {
			void driver.domain('crm').doctype('Comment', [
				{ id: 'c1', body: 'First comment on the deal', target: 'crm.Deal.crm.Deal.1' },
				{ id: 'c2', body: 'Second comment with more detail', target: 'crm.Deal.1' },
				{ id: 'c3', body: 'Third comment, added last', target: 'crm.Deal.crm.Deal.1' }
			]);
			void driver.domain('core').doctype('DocumentView', [
				{
					id: 'crm.Comment.document_view.inline',
					kind: 'inline',
					template: { type: 'field', label: 'Body', value: '$body' } as TemplateNode
				}
			]);
		}
		// Capsule-fallback doctype: no definition, no views, readable titles.
		// Seeded under `crm` — the mock sidecar store scopes by the sidecar
		// doctype's qualified parts (`crm.Note` → domain `crm`).
		void driver.domain('crm').doctype('Note', [
			{ id: 'n1', title: 'Kickoff summary', target: 'crm.Deal.crm.Deal.1' },
			{ id: 'n2', title: 'Follow-up actions', target: 'crm.Deal.1' }
		]);
		return driver;
	}

	const driver = makeDriver();

	// Empty-state driver: same host + sidecar definitions, no sidecar records.
	const emptyDriver = makeDriver(false);

	const hostDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('crm.Deal') as Record<string, unknown>
	);
	const commentDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('crm.Comment') as Record<string, unknown>
	);

	const hostDoc: DocumentResponse = {
		data: { name: 'Platform License' },
		meta: {
			id: 'crm.Deal.1',
			mid: 'crm.Deal.1',
			domain: 'crm',
			doc_type: 'Deal',
			version: 1,
			schema_version: 1,
			display_name: 'Platform License',
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString()
		}
	};

	/** Unrestricted creator — the Add affordance is visible. */
	const adminManifest = { '*.*': ['*'] };

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/SidecarDvtSurface',
		component: SidecarDvtSurface,
		tags: ['autodocs']
	});

	/** Wait long enough for the async list + template fetches to settle. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
</script>

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		await sleep(500);
		const canvas = within(canvasElement);
		// The three seeded comments render through the inline template rows.
		await expect(canvas.getByText('First comment on the deal')).toBeVisible();
		await expect(canvas.getByText('Second comment with more detail')).toBeVisible();
		await expect(canvas.getByText('Third comment, added last')).toBeVisible();
		// The Add affordance is visible with the host create grant.
		await expect(canvas.getByRole('button', { name: 'Add' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarDvtSurface
					{driver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	No `inline` and no `quickView` view exists for the sidecar doctype (and
	no definition at all) — every row degrades to a plain capsule instead of
	disappearing. Without a definition there are no renderable writable
	fields, so the Add affordance stays hidden even with the create grant.
-->

<Story
	name="FallbackCapsuleRows"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Kickoff summary')).toBeVisible();
		await expect(canvas.getByText('Follow-up actions')).toBeVisible();
		await expect(canvas.queryByRole('button', { name: 'Add' })).toBeNull();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarDvtSurface {driver} {hostDef} {hostDoc} segment="notes" sidecarDef={null} />
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('No comments yet.')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Add' })).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarDvtSurface
					driver={emptyDriver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="NoCreatePermission"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// With no manifest, `can()` is fail-closed: the Add affordance hides
		// entirely, but the seeded rows still render.
		await expect(canvas.queryByRole('button', { name: 'Add' })).toBeNull();
		await expect(canvas.getByText('First comment on the deal')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={null}>
			<div style="max-width: 480px; padding: 24px;">
				<SidecarDvtSurface
					{driver}
					{hostDef}
					{hostDoc}
					segment="comments"
					sidecarDef={commentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>
