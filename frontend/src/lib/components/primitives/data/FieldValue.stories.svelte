<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, waitFor, within } from 'storybook/test';
	import FieldValue from './FieldValue.svelte';
	import Capsule from './Capsule.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { FieldDef } from '$lib/doctype/types.js';

	/**
	 * Mock driver seeded with two partners. `MockDataSource` synthesises
	 * `display_name` from `name`, so the hydrated capsules carry a meaningful
	 * label without a doctype-def round-trip.
	 */
	const driver = new MockDataDriver();
	driver.domain('lab').doctype('Partner', [
		{ id: 'lab.Partner.1', name: 'Lab One' },
		{ id: 'lab.Partner.2', name: 'Lab Two' }
	]);

	/** The `{type: 'array', items: {type: 'reference'}}` spelling. */
	const arrayOfRefDef: FieldDef = {
		key: 'partners',
		type: 'array',
		items: { key: '(items)', type: 'reference', doctype: 'lab.Partner' }
	};

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/FieldValue',
		component: FieldValue,
		tags: ['autodocs']
	});
</script>

<!--
	The shared typed-value renderer. These stories pin the array-of-reference
	rendering: the stored token array must reach the `referenceCell` consumer
	one capsule per unique token — a repeated token renders once, because a
	duplicate each key makes Svelte throw and the whole table fails to render
	— never as raw JSON text. The array stories pin the primitive-item chips:
	one chip per item, a `+N` chip past the cap, the blank dash for `[]`, and
	the JSON-text fallback for object items. The duration stories pin the
	zero/negative contract: `Duration` renders `0s` for both, so a stored 0 is
	never the blank dash.
-->

<Story
	name="ArrayOfReferenceRendersOneCellPerToken"
	args={{
		value: ['lab.Partner.1', 'lab.Partner.2'],
		fieldType: 'array' as const,
		fieldDef: arrayOfRefDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Each element hydrates its own capsule — never the raw JSON array.
		await waitFor(() => {
			expect(canvas.getByText('Lab One')).toBeVisible();
			expect(canvas.getByText('Lab Two')).toBeVisible();
		});
		expect(canvas.queryByText('lab.Partner.1')).toBeNull();
		expect(canvas.queryByText('lab.Partner.2')).toBeNull();
		expect(canvas.queryByText(/lab.Partner.1.*lab.Partner.2/)).toBeNull();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef}>
			{#snippet referenceCell(ref, fd)}
				<Capsule {driver} reference={ref} qualifiedDoctype={fd?.doctype} />
			{/snippet}
		</FieldValue>
	{/snippet}
</Story>

<Story
	name="ArrayOfReferenceEmptyArrayRendersBlank"
	args={{ value: [], fieldType: 'array' as const, fieldDef: arrayOfRefDef }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// An empty array holds no content — the blank dash, never "[]".
		await expect(canvas.getByText('—')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef}>
			{#snippet referenceCell(ref, fd)}
				<Capsule {driver} reference={ref} qualifiedDoctype={fd?.doctype} />
			{/snippet}
		</FieldValue>
	{/snippet}
</Story>

<Story
	name="ArrayOfReferenceDuplicateTokenRendersOneCapsule"
	args={{
		value: ['lab.Partner.1', 'lab.Partner.2', 'lab.Partner.1'],
		fieldType: 'array' as const,
		fieldDef: arrayOfRefDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A repeated target renders one capsule, not two: the keyed each keys
		// on the token, and a duplicate key makes Svelte throw.
		await waitFor(() => {
			expect(canvas.getAllByText('Lab One')).toHaveLength(1);
			expect(canvas.getByText('Lab Two')).toBeVisible();
		});
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef}>
			{#snippet referenceCell(ref, fd)}
				<Capsule {driver} reference={ref} qualifiedDoctype={fd?.doctype} />
			{/snippet}
		</FieldValue>
	{/snippet}
</Story>

<Story
	name="ArrayOfStringRendersChips"
	args={{
		value: ['iam', 'grants', 'ui'],
		fieldType: 'array' as const,
		fieldDef: {
			key: 'tags',
			type: 'array',
			items: { key: '(items)', type: 'string' }
		} satisfies FieldDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// One chip per item — never the raw JSON dump.
		await expect(canvas.getByText('iam')).toBeVisible();
		await expect(canvas.getByText('grants')).toBeVisible();
		await expect(canvas.getByText('ui')).toBeVisible();
		expect(canvas.queryByText('["iam","grants","ui"]')).toBeNull();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
	{/snippet}
</Story>

<Story
	name="ArrayOfStringOverflowsWithPlusN"
	args={{
		value: ['alpha', 'beta', 'gamma', 'delta', 'epsilon'],
		fieldType: 'array' as const,
		fieldDef: {
			key: 'tags',
			type: 'array',
			items: { key: '(items)', type: 'string' }
		} satisfies FieldDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Three chips at the default cap, then the literal `+N` chip for the
		// rest. Hidden items stay out of the DOM.
		await expect(canvas.getByText('alpha')).toBeVisible();
		await expect(canvas.getByText('+2')).toBeVisible();
		expect(canvas.queryByText('delta')).toBeNull();
		expect(canvas.queryByText('epsilon')).toBeNull();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
	{/snippet}
</Story>

<Story
	name="ArrayOfStringEmptyRendersBlank"
	args={{
		value: [],
		fieldType: 'array' as const,
		fieldDef: {
			key: 'tags',
			type: 'array',
			items: { key: '(items)', type: 'string' }
		} satisfies FieldDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// An empty array holds no content — the blank dash, never "[]".
		await expect(canvas.getByText('—')).toBeVisible();
		expect(canvas.queryByText('[]')).toBeNull();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
	{/snippet}
</Story>

<Story
	name="ObjectItemArrayStaysText"
	args={{
		value: [{ zip: '94105' }],
		fieldType: 'array' as const,
		fieldDef: {
			key: 'rows',
			type: 'array',
			items: { key: '(items)', type: 'object' }
		} satisfies FieldDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Object items have no chip form — the JSON-text fallback stays.
		await expect(canvas.getByText('[{"zip":"94105"}]')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<FieldValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
	{/snippet}
</Story>

<Story
	name="DurationZeroRendersZeroSeconds"
	args={{ value: 0, fieldType: 'duration' as const }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// 0 is a value, not a blank — `Duration` renders `0s`.
		await expect(canvas.getByText('0s')).toBeVisible();
		expect(canvas.queryByText('—')).toBeNull();
	}}
/>

<Story
	name="DurationNegativeRendersZeroSeconds"
	args={{ value: -5, fieldType: 'duration' as const }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A negative clamps to `0s` — `Duration` owns the clamp.
		await expect(canvas.getByText('0s')).toBeVisible();
	}}
/>
