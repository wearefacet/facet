<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import MonthGrid from './MonthGrid.svelte';
	import MonthGridNav from './MonthGridNav.svelte';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { FieldDef } from '$lib/doctype/types';

	type DocItem = DocumentResponse<Record<string, unknown>>;

	const dueOnField: FieldDef = { key: 'due_on', type: 'date' };

	// Fixed 2026 months keep the fixtures deterministic: the March grid spans
	// Feb 23 – Apr 5 and the October grid spans Sep 28 – Nov 8, so neither
	// month's documents can appear in the other month's 42-cell window.
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

	const MARCH_DOCS = [doc('m1', 'Sky', '2026-03-05'), doc('m2', 'Lake', '2026-03-18')];

	const OCTOBER_DOCS = [
		doc('o1', 'Ash', '2026-10-01'),
		doc('o2', 'Elm', '2026-10-06'),
		doc('o3', 'Iris', '2026-10-13'),
		doc('o4', 'Oak', '2026-10-20'),
		doc('o5', 'Pine', '2026-10-27')
	];

	const ALL_DOCS = [...MARCH_DOCS, ...OCTOBER_DOCS];

	const { Story } = defineMeta({
		title: 'Components/Data/MonthGrid',
		component: MonthGrid,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, within, userEvent } from 'storybook/test';

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<!--
	Grid stories mount MonthGrid directly with fixed documents. Every button
	inside the canvas is either a chip or one of the two nav buttons of
	MonthGridNav, so counting buttons counts chips.
-->

<Story name="FixturesMarch2026">
	{#snippet template()}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<MonthGrid
				items={MARCH_DOCS}
				discriminator="due_on"
				kind="date"
				discriminatorField={dueOnField}
				endField={undefined}
				colorByField={undefined}
				titleTemplate={'{{ name }}'}
				fallbackFields={[]}
				year={2026}
				month={3}
				weekStart="monday"
			/>
		</div>
	{/snippet}
</Story>

<Story name="FixturesOctober2026">
	{#snippet template()}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<MonthGrid
				items={ALL_DOCS}
				discriminator="due_on"
				kind="date"
				discriminatorField={dueOnField}
				endField={undefined}
				colorByField={undefined}
				titleTemplate={'{{ name }}'}
				fallbackFields={[]}
				year={2026}
				month={10}
				weekStart="monday"
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ChipsFollowMonthNavigation"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// March 2026 on fresh mount: the two March chips, nothing from October.
		await expect(canvas.getByRole('button', { name: 'Sky' })).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Lake' })).toBeVisible();
		await expect(canvas.getAllByRole('button')).toHaveLength(4); // 2 chips + 2 nav
		await expect(canvas.queryByText('Ash')).toBeNull();
		// Navigate March → October, seven months forward.
		for (let i = 0; i < 7; i++) {
			await userEvent.click(canvas.getByRole('button', { name: 'Next month' }));
			await sleep(40);
		}
		await expect(canvas.getByText('2026-10')).toBeVisible();
		// The five October chips now render; the March chips are gone. The chip
		// count follows the data of the visible month, not the mount time.
		await expect(canvas.getAllByRole('button')).toHaveLength(7); // 5 chips + 2 nav
		for (const name of ['Ash', 'Elm', 'Iris', 'Oak', 'Pine']) {
			await expect(canvas.getByRole('button', { name })).toBeVisible();
		}
		await expect(canvas.queryByText('Sky')).toBeNull();
		await expect(canvas.queryByText('Lake')).toBeNull();
	}}
>
	{#snippet template()}
		<div style="padding: 24px; min-height: 720px; background: var(--ground);">
			<MonthGridNav initialYear={2026} initialMonth={3}>
				{#snippet grid(nav)}
					<MonthGrid
						items={ALL_DOCS}
						discriminator="due_on"
						kind="date"
						discriminatorField={dueOnField}
						endField={undefined}
						colorByField={undefined}
						titleTemplate={'{{ name }}'}
						fallbackFields={[]}
						year={nav.year}
						month={nav.month}
						weekStart="monday"
					/>
				{/snippet}
			</MonthGridNav>
		</div>
	{/snippet}
</Story>
