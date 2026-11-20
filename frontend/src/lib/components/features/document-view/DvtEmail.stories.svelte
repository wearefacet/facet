<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtEmail from './DvtEmail.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtEmail',
		component: DvtEmail,
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
	name="StaticEmail"
	args={{
		template: {
			type: 'email',
			href: 'mailto:alice@example.com',
			label: 'alice@example.com'
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtEmail template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="FieldDrivenEmail"
	args={{
		template: {
			type: 'email',
			href: 'mailto:$email',
			label: '$email_label'
		},
		document: doc({
			email: 'jane.doe@company.com',
			email_label: 'jane.doe@company.com'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtEmail template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="CustomLabel"
	args={{
		template: {
			type: 'email',
			href: 'mailto:$email',
			label: 'Contact $first_name $last_name'
		},
		document: doc({
			email: 'bob.smith@example.com',
			first_name: 'Bob',
			last_name: 'Smith'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtEmail template={args.template} document={args.document} />
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
