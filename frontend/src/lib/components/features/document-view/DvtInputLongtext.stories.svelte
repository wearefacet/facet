<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import DvtInputLongtext from './DvtInputLongtext.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputLongtextNode } from '$lib/template-types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputLongtext',
		component: DvtInputLongtext,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' },
			values: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	function doc(data: Record<string, unknown>): DocumentResponse {
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

	// Synthetic uploader — mimics `POST /Api/core/artifacts` returning a
	// 26-char ULID and the original filename. The play function asserts that
	// a dropped image produces a node whose markdown references the
	// `urn:facet:artifact:<id>` URI.
	const SYNTHETIC_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';

	function syntheticUpload(file: File): Promise<{ id: string; filename: string }> {
		return Promise.resolve({ id: SYNTHETIC_ID, filename: file.name });
	}

	// Drop an image file onto the ProseMirror editor surface. Crepe's upload
	// plugin routes it through the configured `onUpload` and inserts an image
	// node whose src is the returned URI. ProseMirror resolves the insert
	// position from the event coordinates, so they must be inside the editor.
	async function dropFile(editor: HTMLElement, file: File): Promise<void> {
		const transfer = new DataTransfer();
		transfer.items.add(file);
		const rect = editor.getBoundingClientRect();
		editor.dispatchEvent(
			new DragEvent('drop', {
				dataTransfer: transfer,
				bubbles: true,
				clientX: rect.left + rect.width / 2,
				clientY: rect.top + rect.height / 2
			})
		);
	}
</script>

<Story
	name="Edit"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Notes')).toBeVisible();
		// Typing into the WYSIWYG editor updates the document.
		const editor = await waitFor(() => canvas.getByRole('textbox'));
		// A story that closed a Bits modal leaves `pointer-events: none` on
		// <body> for a tick; the editor div inherits it and `type` fails its
		// pointer assertion (see ApiKeyManager stories for the same trap).
		// Retry until the transient state clears.
		await waitFor(async () => {
			await userEvent.type(editor, 'hello world');
		});
		await waitFor(() => expect(editor.textContent).toContain('hello world'));
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes',
			placeholder: 'Enter notes…'
		} satisfies InputLongtextNode,
		document: doc({ notes: 'Existing note.' }),
		values: { notes: 'Existing note.' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="MarkdownSourceToggle"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The toggle switches between the WYSIWYG editor and a raw markdown
		// source editor holding the same content.
		const mdBtn = canvas.getByRole('button', { name: 'Markdown' });
		// Retry the first pointer interaction: a story that closed a Bits modal
		// leaves `pointer-events: none` on <body> for a tick (see ApiKeyManager
		// stories and the Edit story above).
		await waitFor(async () => {
			await userEvent.click(mdBtn);
		});
		const source = await waitFor(() => canvas.getByRole('textbox'));
		// CodeMirror lays the document out in per-line divs, so the assertion
		// reads the editor content element, not the textbox root's text.
		await expect(canvasElement.querySelector('.cm-content')?.textContent).toContain(
			'Existing note.'
		);
		await expect(source).toBeVisible();
		// Back to WYSIWYG — the source editor unmounts, the WYSIWYG editor
		// takes over with the same content.
		await userEvent.click(canvas.getByRole('button', { name: 'Write' }));
		const wysiwyg = await waitFor(() => canvas.getByRole('textbox'));
		await expect(wysiwyg.classList.contains('cm-content')).toBe(false);
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes'
		} satisfies InputLongtextNode,
		document: doc({ notes: 'Existing note.' }),
		values: { notes: 'Existing note.' }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="WithError"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Notes are required')).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes'
		} satisfies InputLongtextNode,
		document: doc({}),
		values: { notes: '' },
		fieldErrors: { notes: [{ message: 'Notes are required' }] }
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				fieldErrors={args.fieldErrors}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Notes')).toBeVisible();
		// A read-only longtext renders the stored markdown through the same
		// Milkdown engine (readonly preview): the editor mounts asynchronously
		// with the content, and editing is disabled (`contenteditable=false`).
		await waitFor(() => {
			expect(canvas.getByText('Existing note.')).toBeVisible();
		});
		const editor = canvas.getByRole('textbox');
		await waitFor(() => {
			expect(editor.getAttribute('contenteditable')).toBe('false');
		});
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes'
		} satisfies InputLongtextNode,
		document: doc({ notes: 'Existing note.' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="DropUploadsArtifact"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const editor = await waitFor(() => canvas.getByRole('textbox'));

		await dropFile(editor, new File(['hello'], 'pixel.png', { type: 'image/png' }));

		// The synthetic uploader resolves on the next microtask; wait for the
		// editor to hold an image node referencing the artifact. The editor
		// DOM loads the URN through the download gateway (Crepe's
		// `proxyDomURL`). The persisted markdown is asserted on the uncontrolled
		// `Markdown` component stories (the plain-object values bag here is
		// not reactive — see workflow.md → Reactivity).
		await waitFor(() => {
			const img = editor.querySelector('img');
			expect(img?.getAttribute('src')).toBe(`/Api/core/artifacts/${SYNTHETIC_ID}/download`);
		});
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes',
			placeholder: 'Drop a file…'
		} satisfies InputLongtextNode,
		document: doc({ notes: 'Existing note.' }),
		values: { notes: 'Existing note.' },
		uploadFile: syntheticUpload
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				uploadFile={args.uploadFile}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DropNonImageInsertsCapsuleLink"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const editor = await waitFor(() => canvas.getByRole('textbox'));

		// A non-image file uploads to the artifact service and inserts as a
		// capsule link labelled by the filename.
		await dropFile(editor, new File(['pdf-bytes'], 'contract.pdf', { type: 'application/pdf' }));

		// The editor DOM renders the capsule link as a decorated span inside
		// the (href-sanitized) anchor; the serialized markdown keeps the URN.
		await waitFor(() => {
			const link = canvasElement.querySelector('.md-artifact-capsule-link');
			expect(link?.textContent).toBe('contract.pdf');
		});
	}}
	args={{
		template: {
			type: 'input-longtext',
			field: 'notes',
			label: 'Notes',
			placeholder: 'Drop a file…'
		} satisfies InputLongtextNode,
		document: doc({ notes: 'Existing note.' }),
		values: { notes: 'Existing note.' },
		uploadFile: syntheticUpload
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputLongtext
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				uploadFile={args.uploadFile}
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
		min-height: 80px;
	}
</style>
