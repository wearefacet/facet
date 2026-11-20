<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import WeekGrid from './WeekGrid.svelte';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { FieldDef } from '$lib/doctype/types';

	type DocItem = DocumentResponse<Record<string, unknown>>;

	const dueOnField: FieldDef = { key: 'due_on', type: 'date' };

	function doc(id: string, name: string, dueOn: string): DocItem {
		return {
			data: { name, due_on: dueOn },
			meta: {
				id,
				mid: `mid-${id}`,
				domain: 'ops',
				doc_type: 'Task',
				version: 1,
				schema_version: 1,
				created_at: '2026-01-01T00:00:00Z',
				updated_at: '2026-01-01T00:00:00Z'
			}
		};
	}

	// Week of Mon Oct 12 – Sun Oct 18 2026; the anchor day is Wed Oct 14.
	const WEEK_DOCS = [
		doc('w1', 'Sky', '2026-10-12'),
		doc('w2', 'Lake', '2026-10-14'),
		doc('w3', 'Ash', '2026-10-16')
	];

	const { Story } = defineMeta({
		title: 'Components/Data/WeekGrid',
		component: WeekGrid,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
</script>

<!--
	Grid stories mount WeekGrid directly with fixed documents. Every button
	inside the canvas is a chip, so counting buttons counts chips.
-->

<Story name="FixturesWeekOctober2026">
	{#snippet template()}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<WeekGrid
				items={WEEK_DOCS}
				discriminator="due_on"
				kind="date"
				discriminatorField={dueOnField}
				endField={undefined}
				colorByField={undefined}
				titleTemplate={'{{ name }}'}
				fallbackFields={[]}
				year={2026}
				month={10}
				day={14}
				weekStart="monday"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DateKindChipsRenderInAllDayGutter"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Fresh mount on a `date` discriminator: all three documents of the
		// anchored week render as all-day chips. They have no time anchor, so
		// they must not sit on the hour grid — three buttons total.
		await expect(canvas.getAllByRole('button')).toHaveLength(3);
		// The chips live in the all-day row, next to the gutter label.
		const gutterRow = canvas.getByText('all-day').closest('[role="row"]');
		await expect(gutterRow).not.toBeNull();
		const rowScope = within(gutterRow as HTMLElement);
		await expect(rowScope.getByRole('button', { name: 'Sky' })).toBeVisible();
		await expect(rowScope.getByRole('button', { name: 'Lake' })).toBeVisible();
		await expect(rowScope.getByRole('button', { name: 'Ash' })).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<WeekGrid
				items={WEEK_DOCS}
				discriminator="due_on"
				kind="date"
				discriminatorField={dueOnField}
				endField={undefined}
				colorByField={undefined}
				titleTemplate={'{{ name }}'}
				fallbackFields={[]}
				year={2026}
				month={10}
				day={14}
				weekStart="monday"
			/>
		</div>
	{/snippet}
</Story>
