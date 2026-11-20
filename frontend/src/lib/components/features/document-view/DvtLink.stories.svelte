<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtLink from './DvtLink.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtLink',
		component: DvtLink,
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
	name="StaticLink"
	args={{
		template: {
			type: 'link',
			href: 'https://example.com',
			label: 'Visit Example'
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLink template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="FieldDrivenLink"
	args={{
		template: {
			type: 'link',
			href: '$profile_url',
			label: '$display_name'
		},
		document: doc({
			profile_url: 'https://example.com/users/42',
			display_name: 'Alice Johnson'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLink template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="InterpolatedLink"
	args={{
		template: {
			type: 'link',
			href: 'https://$domain/profile/$user_id',
			label: 'Profile of $first_name $last_name'
		},
		document: doc({
			domain: 'app.example.com',
			user_id: '42',
			first_name: 'Alice',
			last_name: 'Johnson'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLink template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyHref"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		expect(canvas.queryByRole('link')).toBeNull();
	}}
	args={{
		template: {
			type: 'link',
			href: '$profile_url',
			label: 'Visit profile'
		},
		document: doc({ profile_url: '' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtLink template={args.template} document={args.document} />
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
