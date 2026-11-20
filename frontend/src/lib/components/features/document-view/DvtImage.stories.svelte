<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtImage from './DvtImage.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtImage',
		component: DvtImage,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>) {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="AvatarFromField"
	args={{
		template: {
			type: 'image',
			src: '$avatar_url',
			variant: 'avatar',
			alt: 'User avatar'
		},
		document: doc({
			avatar_url: 'https://api.dicebear.com/9.x/notionists/svg?seed=Alice'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImage template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="FullImage"
	args={{
		template: {
			type: 'image',
			src: '$photo_url',
			alt: 'Photo'
		},
		document: doc({
			photo_url: 'https://picsum.photos/seed/test/400/300'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImage template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="LiteralSrc"
	args={{
		template: {
			type: 'image',
			src: 'https://api.dicebear.com/9.x/notionists/svg?seed=Static',
			alt: 'Static avatar'
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImage template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptySrc"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		expect(canvas.queryByRole('img')).toBeNull();
	}}
	args={{
		template: {
			type: 'image',
			src: '$photo_url',
			alt: 'Photo'
		},
		document: doc({ photo_url: '' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtImage template={args.template} document={args.document} />
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
