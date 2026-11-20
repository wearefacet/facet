<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, waitFor } from 'storybook/test';
	import DvtImageArtifact from './DvtImageArtifact.svelte';
	import type { ArtifactGrant } from '$lib/components/primitives/data/FileArtifact.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';
	import type { ImageArtifactNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtImageArtifact',
		component: DvtImageArtifact,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			fetchArtifact: { control: false }
		}
	});

	function doc(data: Record<string, unknown>): {
		data: Record<string, unknown>;
		meta: DocumentMeta;
	} {
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

	const SYNTHETIC_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';

	// Synthetic artifact metadata fetcher — mimics `GET /Api/core/artifacts/:id`
	// returning the `url` field that `ArtifactImage` renders as the `<img src>`.
	function syntheticFetchArtifact(id: string): Promise<ArtifactGrant> {
		return Promise.resolve({
			id,
			filename: 'acme-logo.png',
			mime_type: 'image/png',
			url: 'https://artifact.example/a/grant-1?exp=1234&sig=abc'
		});
	}

	function failingFetchArtifact(_id: string): Promise<ArtifactGrant> {
		return Promise.reject(new Error('not found'));
	}

	const thumbnailTemplate: ImageArtifactNode = {
		type: 'image-artifact',
		field: 'logo',
		variant: 'thumbnail',
		alt: '$name logo'
	};

	const avatarTemplate: ImageArtifactNode = {
		type: 'image-artifact',
		field: 'logo',
		variant: 'avatar',
		alt: '$name logo'
	};
</script>

<script lang="ts">
	function sleep(ms: number): Promise<void> {
		return new Promise((r) => setTimeout(r, ms));
	}
</script>

<Story
	name="Thumbnail"
	play={async ({ canvasElement }) => {
		await waitFor(() => {
			const img = canvasElement.querySelector('img');
			expect(img).not.toBeNull();
			expect(img?.getAttribute('src')).toBe('https://artifact.example/a/grant-1?exp=1234&sig=abc');
		});
	}}
	args={{
		template: thumbnailTemplate,
		document: doc({ name: 'Acme Corp', logo: SYNTHETIC_ID }),
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImageArtifact
				template={args.template}
				document={args.document}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="Avatar"
	play={async ({ canvasElement }) => {
		await waitFor(() => {
			const img = canvasElement.querySelector('img');
			expect(img?.getAttribute('src')).toBe('https://artifact.example/a/grant-1?exp=1234&sig=abc');
		});
	}}
	args={{
		template: avatarTemplate,
		document: doc({ name: 'Acme Corp', logo: SYNTHETIC_ID }),
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImageArtifact
				template={args.template}
				document={args.document}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyField"
	play={async ({ canvasElement }) => {
		await sleep(60);
		// No artifact id stored — the blank em-dash renders, no <img>, no fetch.
		const canvas = within(canvasElement);
		await expect(canvas.queryByText('—')).not.toBeNull();
		await expect(canvasElement.querySelector('img')).toBeNull();
	}}
	args={{
		template: thumbnailTemplate,
		document: doc({ name: 'Acme Corp', logo: '' }),
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImageArtifact
				template={args.template}
				document={args.document}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="FetchFailure"
	play={async ({ canvasElement }) => {
		// The fetch rejects — the failed placeholder renders in place of the <img>.
		await waitFor(() => {
			const placeholder = canvasElement.querySelector('.artifact-image-placeholder.failed');
			expect(placeholder).not.toBeNull();
		});
		await expect(canvasElement.querySelector('img')).toBeNull();
	}}
	args={{
		template: thumbnailTemplate,
		document: doc({ name: 'Acme Corp', logo: SYNTHETIC_ID }),
		fetchArtifact: failingFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImageArtifact
				template={args.template}
				document={args.document}
				fetchArtifact={args.fetchArtifact}
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
