<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtRow from './DvtRow.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtRow',
		component: DvtRow,
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
	name="EducationEntry"
	args={{
		template: {
			type: 'row',
			layout: 'auto auto auto 1fr',
			children: [
				{ type: 'label', value: '$school' },
				{ type: 'capsule', value: '$degree' },
				{ type: 'capsule', value: '$field' },
				{ type: 'label', value: '$start — $end' }
			]
		},
		document: doc({
			school: 'Stanford University',
			degree: 'BSc',
			field: 'Computer Science',
			start: '2018',
			end: '2022'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRow template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="ExperienceEntry"
	args={{
		template: {
			type: 'row',
			layout: 'auto auto 1fr auto',
			children: [
				{ type: 'label', value: '$title' },
				{ type: 'capsule', value: '$company' },
				{ type: 'label', value: '$start — $end' },
				{ type: 'capsule', value: '$type' }
			]
		},
		document: doc({
			title: 'Senior Engineer',
			company: 'Acme Corp',
			start: '2022-03',
			end: 'present',
			type: 'full-time'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRow template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="SkillEntry"
	args={{
		template: {
			type: 'row',
			layout: 'auto auto auto auto',
			children: [
				{ type: 'label', value: '$name' },
				{ type: 'capsule', value: '$category' },
				{ type: 'label', value: 'Level $level' },
				{ type: 'label', value: '$years yrs' }
			]
		},
		document: doc({
			name: 'TypeScript',
			category: 'languages',
			level: 4,
			years: 6
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtRow template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 16px 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 60px;
	}
</style>
