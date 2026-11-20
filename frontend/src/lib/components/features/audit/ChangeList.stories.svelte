<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import ChangeList from './ChangeList.svelte';
	import { mutationChanges, VALUE_PREVIEW_LIMIT, type ChangeEntry } from './auditDiff.js';
	import type { MutationRecord } from '$lib/datasource/types.js';

	const changes: ChangeEntry[] = [
		{ path: '/status', kind: 'set', value: 'approved' },
		{ path: '/notes', kind: 'patch' },
		{ path: '/internal_flag', kind: 'unset' },
		{ path: '/created_at', kind: 'init', value: '2026-01-15T08:00:00Z' },
		{ path: '/shipping', kind: 'set', value: { carrier: 'DHL', legs: 2 } }
	];

	/** Longer than the preview limit — renders truncated. */
	const LONG_VALUE = 'x'.repeat(VALUE_PREVIEW_LIMIT + 256);

	/**
	 * A server-redacted update: `salary` is listed in `redacted`, so the
	 * derivation must show the hidden chip — the raw value carried in this
	 * fixture's diff must never reach the DOM.
	 */
	const REDACTED_RECORD: MutationRecord = {
		id: '01JAAAAAAAAAAAAAAAAAAAAAAA',
		domain: 'hr',
		doc_type: 'Employee',
		doc_id: '01JBBBBBBBBBBBBBBBBBBBBBB',
		idx: 4,
		action: 'update',
		actioner_id: 'system',
		arguments: {
			diff: {
				set: [
					{ path: ['status'], value: 'approved' },
					{ path: ['salary'], value: 125000 }
				],
				unset: []
			}
		},
		redacted: [['salary']],
		channel: 'session',
		cause_kind: 'request',
		cause_trace: '01JAAAAAAAAAAAAAAAAAAAAAAA',
		emitted_at: '2026-01-15T08:00:00Z'
	};

	const redactedChanges: ChangeEntry[] = mutationChanges(REDACTED_RECORD);

	const { Story } = defineMeta({
		title: 'Components/Features/Audit/ChangeList',
		component: ChangeList,
		tags: ['autodocs']
	});
</script>

<Story
	name="SideLayout"
	args={{ changes }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// One badge per kind group — the fixture holds two `set` entries
		// (`/status`, `/shipping`) under a single `set` group header.
		await expect(canvas.getByText('/status')).toBeVisible();
		await expect(canvas.getAllByText('set').length).toBe(1);
		await expect(canvas.getByText('init')).toBeVisible();
		await expect(canvas.getByText('patch')).toBeVisible();
		await expect(canvas.getByText('removed')).toBeVisible();
		// Scalars render as code, objects as a JSON block.
		await expect(canvas.getByText('approved')).toBeVisible();
		await expect(canvas.getByText(/"carrier": "DHL"/)).toBeVisible();
	}}
/>

<Story
	name="LongValueTruncated"
	args={{ changes: [{ path: '/body', kind: 'set', value: LONG_VALUE }] }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The rendered text cuts at the preview limit; the hover title keeps
		// the full value so no information is lost.
		const code = canvas.getByTitle(LONG_VALUE);
		await expect(code.textContent?.length).toBe(VALUE_PREVIEW_LIMIT + 1);
		await expect(code.textContent?.endsWith('…')).toBe(true);
	}}
/>

<Story
	name="StackedLayout"
	args={{ changes, layout: 'stacked' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('/internal_flag')).toBeVisible();
		await expect(canvas.getByText('removed')).toBeVisible();
	}}
/>

<Story
	name="RedactedValues"
	args={{ changes: redactedChanges }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// One row for the hidden path, with the chip instead of a value —
		// the raw number in the diff fixture never reaches the DOM.
		await expect(canvas.getAllByText('/salary').length).toBe(1);
		await expect(canvas.getByText('Value hidden')).toBeVisible();
		await expect(canvas.getByText('redacted')).toBeVisible();
		await expect(canvas.queryByText('125000')).toBeNull();
		// The visible sibling set renders normally under its badge.
		await expect(canvas.getAllByText('set').length).toBe(1);
		await expect(canvas.getByText('approved')).toBeVisible();
	}}
/>

<Story name="PatchOnly" args={{ changes: [{ path: '/body', kind: 'patch' }] }} />
