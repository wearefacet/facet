<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within, waitFor } from 'storybook/test';
	import DvtHeader from './DvtHeader.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { ArtifactGrant } from '$lib/artifacts.js';
	import type { DocumentMeta } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtHeader',
		component: DvtHeader,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			def: { control: 'object' },
			fetchArtifact: { control: false }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	function doc(data: Record<string, unknown>) {
		return {
			data,
			meta: {
				id: 'crm.Company.1',
				mid: 'crm.Company.1',
				domain: 'crm',
				doc_type: 'Company',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	// Minimal doctype def carrying a status enum with declared colors and a
	// couple of categorical enums (industry, size). Used to assert that only
	// the statusField chip picks up a tint; categorical chips stay neutral.
	const def: DoctypeDef = {
		doctype: 'Company',
		domain: 'crm',
		fields: [
			{
				key: 'status',
				type: 'enum',
				values: [
					{ key: 'lead', label: 'Lead', color: '#008c9b' },
					{ key: 'active', label: 'Active', color: '#b16147' },
					{ key: 'churned', label: 'Churned', color: '#7c6db6' },
					// A declared label that differs from the humanized key
					// ('On Hold') — the chip must show the declared form.
					{ key: 'on_hold', label: 'On hold' }
				]
			},
			{
				key: 'industry',
				type: 'enum',
				values: [{ key: 'technology', label: 'Technology', color: '#b25e5b' }]
			},
			{ key: 'company_size', type: 'enum', values: [{ key: '11-50', label: '11-50' }] },
			{
				key: 'partner_tier',
				type: 'enum',
				values: [{ key: 'gold_star', label: 'Gold star' }]
			},
			{ key: 'name', type: 'string' },
			{ key: 'domain_name', type: 'string' },
			{ key: 'logo', type: 'file', accept: ['image/*'] }
		],
		children: [],
		actions: []
	};

	const SYNTHETIC_LOGO_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';

	// Synthetic artifact metadata fetcher — mimics
	// `GET /Api/core/artifacts/:id` returning the `url` field that
	// `ArtifactImage` renders as the avatar `<img src>`.
	function syntheticFetchArtifact(id: string): Promise<ArtifactGrant> {
		return Promise.resolve({
			id,
			filename: 'acme-logo.png',
			mime_type: 'image/png',
			size: 12345,
			url: 'https://artifact.example/a/acme-logo?exp=1234&sig=abc'
		});
	}

	// ── Reference-subtitle fixtures (B-116) ─────────────────────────────────
	// One supplier document + a definition that declares `supplier` as a
	// `reference` to crm.Supplier. The mock derives display_name from `name`.
	const refDriver = new MockDataDriver();
	refDriver.domain('crm').doctype('Supplier', [{ id: 'crm.Supplier.1', name: 'Acme Supplies' }]);

	const refDef: DoctypeDef = {
		doctype: 'Company',
		domain: 'crm',
		fields: [
			{ key: 'name', type: 'string' },
			{ key: 'supplier', type: 'reference', doctype: 'crm.Supplier' }
		],
		children: [],
		actions: []
	};

	// ── Reference-chip + money-chip fixtures (F10-C / F10-D) ────────────────
	// One driver seeded with two suppliers; a definition declaring a scalar
	// reference, a collection reference, and a money field. The chips render
	// hydrated labels — never the stored tokens, never `[object Object]`.
	const chipDriver = new MockDataDriver();
	chipDriver.domain('crm').doctype('Supplier', [
		{ id: 'crm.Supplier.1', name: 'Acme Supplies' },
		{ id: 'crm.Supplier.2', name: 'Globex Supplies' }
	]);

	const chipDef: DoctypeDef = {
		doctype: 'Company',
		domain: 'crm',
		fields: [
			{ key: 'name', type: 'string' },
			{ key: 'supplier', type: 'reference', doctype: 'crm.Supplier' },
			{ key: 'suppliers', type: 'reference', doctype: 'crm.Supplier', collection: true }
		],
		children: [],
		actions: []
	};

	// The base def plus a money field — the chip formats the stored
	// `{value, currency}` pair through the show page's money pipeline.
	const moneyDef: DoctypeDef = {
		...def,
		fields: [...def.fields, { key: 'budget', type: 'money', currency: 'EUR' }]
	};
</script>

<!-- The declared enum label wins over the humanized key on both chip
		kinds: the status chip shows 'On hold', the categorical chip 'Gold star'. -->
<Story
	name="EnumLabelPreferredOverHumanized"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Initech')).toBeVisible();
		// Status chip: declared label, not the humanized key ('On Hold').
		await expect(canvas.getByText('On hold')).toBeVisible();
		await expect(canvas.queryByText('On Hold')).toBeNull();
		// Categorical chip: same rule.
		await expect(canvas.getByText('Gold star')).toBeVisible();
		await expect(canvas.queryByText('Gold Star')).toBeNull();
	}}
	args={{
		template: {
			type: 'header',
			title: '$name',
			statusField: 'status',
			chips: ['partner_tier']
		},
		document: doc({ name: 'Initech', status: 'on_hold', partner_tier: 'gold_star' }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="WithStatusAndChips"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Initech')).toBeVisible();
		// Status chip renders the enum label, humanized.
		await expect(canvas.getByText('Lead')).toBeVisible();
		// Categorical chips render neutral (humanized).
		await expect(canvas.getByText('Technology')).toBeVisible();
		// Subtitle line.
		await expect(canvas.getByText('initech.com')).toBeVisible();
	}}
	args={{
		template: {
			type: 'header',
			title: '$name',
			statusField: 'status',
			chips: ['industry', 'company_size'],
			subtitle: '$domain_name'
		},
		document: doc({
			name: 'Initech',
			status: 'lead',
			industry: 'technology',
			company_size: '11-50',
			domain_name: 'initech.com'
		}),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="NoStatus"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Acme Corp')).toBeVisible();
		// Only the categorical chip, no status chip.
		await expect(canvas.queryByText('Lead')).toBeNull();
	}}
	args={{
		template: {
			type: 'header',
			title: '$name',
			chips: ['industry']
		},
		document: doc({ name: 'Acme Corp', industry: 'finance' }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="TitleOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Standalone Inc')).toBeVisible();
	}}
	args={{
		template: { type: 'header', title: '$name' },
		document: doc({ name: 'Standalone Inc' }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingStatusValue"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Ghost Co')).toBeVisible();
		// No status chip renders when the field is empty.
		await expect(canvas.queryByText('Lead')).toBeNull();
	}}
	args={{
		template: {
			type: 'header',
			title: '$name',
			statusField: 'status',
			chips: ['industry']
		},
		document: doc({ name: 'Ghost Co', industry: 'retail' }),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="WithLogo"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Title + status + chips + subtitle all still render.
		await expect(canvas.getByText('Acme Corp')).toBeVisible();
		await expect(canvas.getByText('Active')).toBeVisible();
		await expect(canvas.getByText('Technology')).toBeVisible();
		// The logo avatar resolves its grant URL on mount — wait for the <img>.
		await waitFor(() => {
			const img = canvasElement.querySelector('img');
			expect(img).not.toBeNull();
			expect(img?.getAttribute('src')).toBe(
				'https://artifact.example/a/acme-logo?exp=1234&sig=abc'
			);
		});
	}}
	args={{
		template: {
			type: 'header',
			title: '$name',
			statusField: 'status',
			chips: ['industry', 'company_size'],
			subtitle: '$domain_name',
			logo: 'logo'
		},
		document: doc({
			name: 'Acme Corp',
			status: 'active',
			industry: 'technology',
			company_size: '51-200',
			domain_name: 'acme.com',
			logo: SYNTHETIC_LOGO_ID
		}),
		def,
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="NoTitleChromeOwnsH1"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// When the show route chrome renders the page h1, the DVT header omits
		// `title` and carries only the status chip + chips.
		await expect(canvas.queryByRole('heading', { name: 'Initech' })).toBeNull();
		await expect(canvas.getByText('Lead')).toBeVisible();
		await expect(canvas.getByText('Technology')).toBeVisible();
	}}
	args={{
		template: {
			type: 'header',
			statusField: 'status',
			chips: ['industry', 'company_size'],
			subtitle: '$domain_name'
		},
		document: doc({
			status: 'lead',
			industry: 'technology',
			company_size: '11-50',
			domain_name: 'initech.com'
		}),
		def
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<Story
	name="SubtitlePureReference"
	args={{
		template: { type: 'header', title: '$name', subtitle: '$supplier' },
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: refDef,
		onreferenceclick: fn()
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		// The subtitle's $supplier is a declared reference — it renders the
		// target document's label as a capsule, not the URN (B-116).
		await waitFor(() => {
			expect(canvas.getByText('Acme Supplies')).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
		// Click-through opens the referenced document.
		await userEvent.click(canvas.getByRole('button', { name: 'Acme Supplies' }));
		await expect(args.onreferenceclick).toHaveBeenCalledWith({
			domain: 'crm',
			doctype: 'Supplier',
			id: 'crm.Supplier.1'
		});
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={refDriver}
				onreferenceclick={args.onreferenceclick}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SubtitleMixedReference"
	args={{
		template: {
			type: 'header',
			title: '$name',
			subtitle: 'Supplied by $supplier (preferred)'
		},
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: refDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A mixed string resolves the reference token to its label inline.
		await waitFor(() => {
			expect(canvas.getByText('Supplied by Acme Supplies (preferred)')).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={refDriver}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SubtitleReferenceWithoutDriver"
	args={{
		template: { type: 'header', title: '$name', subtitle: '$supplier' },
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: refDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Without a driver nothing can hydrate — the subtitle falls back to
		// plain interpolation and shows the stored value.
		await expect(canvas.getByText('crm.Supplier.1')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
		</div>
	{/snippet}
</Story>

<!-- B-315: a title that is a single reference token renders the target
	document's label, not the stored URN. -->
<Story
	name="TitlePureReference"
	args={{
		template: { type: 'header', title: '$supplier' },
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: refDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The hydrated label replaces the raw token once it lands.
		await waitFor(() => {
			expect(canvas.getByRole('heading', { name: 'Acme Supplies' })).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={refDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- B-315: a mixed-interpolation title resolves the reference token inline. -->
<Story
	name="TitleMixedReference"
	args={{
		template: { type: 'header', title: 'Partner: $supplier' },
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: refDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => {
			expect(canvas.getByRole('heading', { name: 'Partner: Acme Supplies' })).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={refDriver}
			/>
		</div>
	{/snippet}
</Story>

<!-- F10-C: a chip bound to a scalar reference renders the target's label,
     never the stored URN. -->
<Story
	name="ReferenceChip"
	args={{
		template: { type: 'header', title: '$name', chips: ['supplier'] },
		document: doc({ name: 'Initech', supplier: 'crm.Supplier.1' }),
		def: chipDef,
		driver: chipDriver
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The hydrated label replaces the raw token once it lands.
		await waitFor(() => {
			expect(canvas.getByText('Acme Supplies')).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={args.driver}
			/>
		</div>
	{/snippet}
</Story>

<!-- F10-C: a chip bound to a collection reference renders one hydrated chip
     per stored token — no comma-joined raw tokens. -->
<Story
	name="ReferenceCollectionChip"
	args={{
		template: { type: 'header', title: '$name', chips: ['suppliers'] },
		document: doc({ name: 'Initech', suppliers: ['crm.Supplier.1', 'crm.Supplier.2'] }),
		def: chipDef,
		driver: chipDriver
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => {
			expect(canvas.getByText('Acme Supplies')).toBeVisible();
			expect(canvas.getByText('Globex Supplies')).toBeVisible();
		});
		await expect(canvas.queryByText('crm.Supplier.1')).toBeNull();
		await expect(canvas.queryByText('crm.Supplier.2')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader
				template={args.template}
				document={args.document}
				def={args.def}
				driver={args.driver}
			/>
		</div>
	{/snippet}
</Story>

<!-- F10-D / F10-08: a chip bound to a money field renders through the same
     `formatMoneyAmount` + `composeMoneyText` pair as the show page — the
     symbol and grouped amount, never the bare ticker with the raw value and
     never the `String(value)` artifact. The preview loader seeds the EUR row
     (`€`, 2 digits, standard grouping). -->
<Story
	name="MoneyChip"
	args={{
		template: { type: 'header', title: '$name', chips: ['budget'] },
		document: doc({ name: 'Initech', budget: { value: '12.50', currency: 'EUR' } }),
		def: moneyDef
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Initech')).toBeVisible();
		await expect(canvas.getByText('€ 12.50')).toBeVisible();
		await expect(canvas.queryByText('EUR 12.50')).toBeNull();
		await expect(canvas.queryByText('[object Object]')).toBeNull();
		await expect(canvas.queryByText('[Object Object]')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtHeader template={args.template} document={args.document} def={args.def} />
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
