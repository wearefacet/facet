<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, waitFor } from 'storybook/test';
	import DvtMarkdown from './DvtMarkdown.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';
	import type { MarkdownNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtMarkdown',
		component: DvtMarkdown,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): the embedded
		// Milkdown editor surface has axe violations (ARIA structure), same as
		// the DvtInputLongtext stories. Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	function doc(data: Record<string, unknown>): {
		data: Record<string, unknown>;
		meta: DocumentMeta;
	} {
		return {
			data,
			meta: {
				id: 'crm.Activity.1',
				mid: 'crm.Activity.1',
				domain: 'crm',
				doc_type: 'Activity',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	const template: MarkdownNode = { type: 'markdown', field: 'body' };
</script>

<Story
	name="RendersMarkdownAsProse"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The editor mounts asynchronously with the content rendered as
		// markdown prose (headings and paragraphs, not the raw source).
		await waitFor(() => {
			expect(canvas.getByText('Meeting notes')).toBeVisible();
		});
		await waitFor(() => {
			expect(canvas.getByText('Discussed the renewal.')).toBeVisible();
		});
		// The surface is the readonly Milkdown editor — not a plain-text row
		// and not the raw markdown source.
		const editor = canvas.getByRole('textbox');
		await waitFor(() => {
			expect(editor.getAttribute('contenteditable')).toBe('false');
		});
		const heading = editor.querySelector('h2');
		expect(heading?.textContent).toBe('Meeting notes');
	}}
	args={{
		template,
		document: doc({ body: '## Meeting notes\n\nDiscussed the renewal.\n' })
	}}
/>

<Story
	name="EmptyRendersNothing"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// An empty field renders no editor at all — the section simply has
		// no body.
		await waitFor(() => {
			expect(canvas.queryByRole('textbox')).toBeNull();
		});
	}}
	args={{ template, document: doc({}) }}
/>
