<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn, waitFor } from 'storybook/test';
	import DvtValue from './DvtValue.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtValue',
		component: DvtValue,
		tags: ['autodocs'],
		argTypes: {
			value: { control: 'object' },
			fieldType: { control: 'text' }
		}
	});

	/** A def with a scalar and a collection reference to the same doctype. */
	const refDef: DoctypeDef = {
		domain: 'shop',
		doctype: 'Product',
		schema_version: 1,
		aggregate_root: false,
		fields: [
			{
				key: 'brand',
				type: 'reference',
				title: 'Brand',
				doctype: 'shop.Brand'
			} satisfies FieldDef,
			{
				key: 'alt_brands',
				type: 'reference',
				title: 'Alt brands',
				doctype: 'shop.Brand',
				collection: true
			} satisfies FieldDef
		],
		children: [],
		actions: []
	};

	/**
	 * Driver with two seeded `shop.Brand` rows. Seeding is synchronous (the
	 * MockDataSource constructor), so the reference resolves deterministically
	 * when the capsule hydrates: `meta.display_name` derives from the `name`
	 * content field.
	 */
	function refDriver(): { driver: DataDriver; reference: string } {
		const driver = new MockDataDriver();
		driver.domain('shop').doctype('Brand', [
			{ id: 'brand-1', name: 'Acme Brand' },
			{ id: 'brand-2', name: 'Globex Brand' }
		]);
		return { driver, reference: 'shop.Brand.brand-1' };
	}
	const seeded = refDriver();
</script>

<Story
	name="PlainText"
	args={{
		value: 'Alice Johnson',
		fieldType: 'string'
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtValue value={args.value} fieldType={args.fieldType as 'string'} />
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceCapsule"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// B-132: a reference value hydrates to the target's display name —
		// the raw qualified token never shows.
		await expect(canvas.getByText('Acme Brand')).toBeVisible();
		await expect(canvas.queryByText(seeded.reference)).toBeNull();
		// Clicking the capsule follows the reference. Capsule hands the stored
		// token through verbatim (consumers resolve the id shape).
		const capsule = canvas.getByRole('button');
		await userEvent.click(capsule);
		await expect(args.onreferenceclick).toHaveBeenCalledWith({
			domain: 'shop',
			doctype: 'Brand',
			id: seeded.reference
		});
	}}
	args={{
		value: seeded.reference,
		fieldType: 'reference' as const,
		fieldDef: refDef.fields[0],
		driver: seeded.driver,
		onreferenceclick: fn()
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtValue
				value={args.value}
				fieldType={args.fieldType}
				fieldDef={args.fieldDef}
				driver={args.driver}
				onreferenceclick={args.onreferenceclick}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceWithoutDriver"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No driver — the degraded path keeps the plain-text rendering of the
		// stored token instead of a capsule that could not hydrate.
		await expect(canvas.getByText(seeded.reference)).toBeVisible();
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
	args={{
		value: seeded.reference,
		fieldType: 'reference' as const,
		fieldDef: refDef.fields[0]
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceCollectionCapsules"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// F10-F: a collection reference stores a JSON array. With a driver the
		// value renders one hydrated Capsule per stored token — the same
		// reference-cell rendering the table uses. The raw tokens never join
		// into one plain-text string.
		await waitFor(() => {
			expect(canvas.getByText('Acme Brand')).toBeVisible();
			expect(canvas.getByText('Globex Brand')).toBeVisible();
		});
		await expect(canvas.queryByText('shop.Brand.brand-1, shop.Brand.brand-2')).toBeNull();
		await expect(canvas.queryByText('shop.Brand.brand-1')).toBeNull();
		// Click-through fires with the stored token, as the scalar story does.
		await expect(canvas.getAllByRole('button')).toHaveLength(2);
		await userEvent.click(canvas.getByRole('button', { name: 'Acme Brand' }));
		await expect(args.onreferenceclick).toHaveBeenCalledWith({
			domain: 'shop',
			doctype: 'Brand',
			id: 'shop.Brand.brand-1'
		});
	}}
	args={{
		value: ['shop.Brand.brand-1', 'shop.Brand.brand-2'],
		fieldType: 'reference' as const,
		fieldDef: refDef.fields[1],
		driver: seeded.driver,
		onreferenceclick: fn()
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtValue
				value={args.value}
				fieldType={args.fieldType}
				fieldDef={args.fieldDef}
				driver={args.driver}
				onreferenceclick={args.onreferenceclick}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReferenceCollectionWithoutDriver"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No driver — nothing can hydrate. The degraded path keeps the
		// plain-text rendering of the stored tokens.
		await expect(canvas.getByText('shop.Brand.brand-1, shop.Brand.brand-2')).toBeVisible();
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
	args={{
		value: ['shop.Brand.brand-1', 'shop.Brand.brand-2'],
		fieldType: 'reference' as const,
		fieldDef: refDef.fields[1]
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtValue value={args.value} fieldType={args.fieldType} fieldDef={args.fieldDef} />
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
		min-height: 80px;
	}
</style>
