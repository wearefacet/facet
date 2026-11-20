<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtRecordMeta from './DvtRecordMeta.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtRecordMeta',
		component: DvtRecordMeta,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			historyHref: { control: 'text' }
		}
	});

	function doc(over: Partial<DocumentMeta> = {}): {
		data: Record<string, unknown>;
		meta: DocumentMeta;
	} {
		return {
			data: {},
			meta: {
				id: 'crm.Company.1',
				mid: 'crm.Company.1',
				domain: 'crm',
				doc_type: 'Company',
				version: 7,
				schema_version: 1,
				created_at: '2025-03-14T09:00:00Z',
				updated_at: '2026-08-14T09:00:00Z',
				...over
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="WithHistory"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Record')).toBeVisible();
		await expect(canvas.getByText('Created')).toBeVisible();
		await expect(canvas.getByText('Updated')).toBeVisible();
		await expect(canvas.getByText('History')).toBeVisible();
		await expect(canvas.getByText('v7')).toBeVisible();
	}}
	args={{
		template: { type: 'record-meta', history: true },
		document: doc(),
		historyHref: '/crm/Company/1/history'
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRecordMeta
				template={args.template}
				document={args.document}
				historyHref={args.historyHref}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithoutHistoryHref"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Record')).toBeVisible();
		// History row is hidden when no href is provided.
		await expect(canvas.queryByText('History')).toBeNull();
	}}
	args={{
		template: { type: 'record-meta', history: true },
		document: doc()
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRecordMeta template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="HistoryDisabled"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// history: false hides the link even when a href is available.
		await expect(canvas.queryByText('History')).toBeNull();
	}}
	args={{
		template: { type: 'record-meta', history: false },
		document: doc(),
		historyHref: '/crm/Company/1/history'
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRecordMeta
				template={args.template}
				document={args.document}
				historyHref={args.historyHref}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DifferentVersion"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('v42')).toBeVisible();
	}}
	args={{
		template: { type: 'record-meta' },
		document: doc({ version: 42 }),
		historyHref: '/crm/Company/1/history'
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRecordMeta
				template={args.template}
				document={args.document}
				historyHref={args.historyHref}
			/>
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}
</style>
