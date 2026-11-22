<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import DvtInputFile from './DvtInputFile.svelte';
	import { sessionBag } from './session-bag.svelte.js';
	import { artifactMetadataCache } from '$lib/datasource/clientCache.js';
	import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
	import type { InputFileNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtInputFile',
		component: DvtInputFile,
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
				doc_type: 'Asset',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}

	// Synthetic uploader — mimics `POST /Api/core/artifacts` returning an id
	// and the original filename. The id is a fixed 26-char Crockford Base32
	// ULID so the value written into `values[field]` matches the doctype
	// `file` field's ULID shape.
	const SYNTHETIC_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';

	function syntheticUpload(file: File): Promise<{ id: string; filename: string }> {
		return Promise.resolve({ id: SYNTHETIC_ID, filename: file.name });
	}

	// Synthetic artifact metadata fetcher — mimics
	// `GET /Api/core/artifacts/:id` returning the filename for an
	// already-stored artifact, so the edit / read-only surfaces can show
	// the human filename rather than the raw ULID without a live backend.
	function syntheticFetchArtifact(
		id: string
	): Promise<{ id: string; filename: string; url: string }> {
		return Promise.resolve({
			id,
			filename: 'pixel.png',
			url: 'https://artifact.example/a/grant-1?exp=1234&sig=abc'
		});
	}

	const file = new File(['hello'], 'pixel.png', { type: 'image/png' });

	// Doctype definition carrying an `accept` allow-list on the `avatar`
	// field. Used by the accept-related stories to verify the constraint
	// flows from the parsed definition into the `<input type="file">`
	// attribute and into the client-side rejection path.
	const imageOnlyDef: DoctypeDef = {
		domain: 'test',
		doctype: 'Asset',
		schema_version: 1,
		fields: [{ key: 'avatar', type: 'file', accept: ['image/*'] }],
		children: [],
		actions: []
	};
</script>

<Story
	name="UploadWritesArtifactId"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Avatar') as HTMLInputElement;
		await userEvent.upload(input, file);
		// After the upload resolves, the field value carries the artifact id
		// and the rendered surface shows the filename.
		await expect(canvas.getByText('pixel.png')).toBeVisible();
		await expect(canvas.getByText(SYNTHETIC_ID)).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar',
			placeholder: 'Drop a file or click to attach'
		} satisfies InputFileNode,
		document: doc({}),
		values: { avatar: '' },
		uploadFile: syntheticUpload
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				uploadFile={args.uploadFile}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DisplaysExistingId"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A document loaded with an existing artifact id resolves the
		// filename via the metadata fetcher; the capsule shows the filename
		// (label) alongside the stored id (monospace sub-label).
		await waitFor(() => {
			expect(canvas.getByText('pixel.png')).toBeVisible();
		});
		await expect(canvas.getByText(SYNTHETIC_ID)).toBeVisible();
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar'
		} satisfies InputFileNode,
		document: doc({ avatar: SYNTHETIC_ID }),
		values: { avatar: SYNTHETIC_ID },
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReadOnly"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Read-only mode delegates to `<FileArtifact>`, which resolves the
		// filename on mount. The metadata cache is shared across stories, so
		// drop this id's entry to guarantee the mount fetch runs. No uploader
		// surface is rendered.
		artifactMetadataCache.invalidate(SYNTHETIC_ID);
		await waitFor(() => {
			expect(canvas.getByText('pixel.png')).toBeVisible();
		});
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar'
		} satisfies InputFileNode,
		document: doc({ avatar: SYNTHETIC_ID }),
		fetchArtifact: syntheticFetchArtifact
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				fetchArtifact={args.fetchArtifact}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ClickDropZoneOpensFilePicker"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const drop = canvas.getByRole('button', { name: /drop a file or click to attach/i });
		// Stub the real file-picker open — JSDOM cannot surface an OS dialog.
		// Asserting the call proves the click chain reaches the hidden input,
		// which is the regression this story guards against (a prior version
		// wired only `onkeydown` + `ondrop`, leaving mouse clicks inert).
		const input = canvas.getByLabelText('Avatar') as HTMLInputElement;
		let clicks = 0;
		const realClick = input.click;
		input.click = () => {
			clicks++;
		};
		await userEvent.click(drop);
		await expect(clicks).toBe(1);
		input.click = realClick;
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar',
			placeholder: 'Drop a file or click to attach'
		} satisfies InputFileNode,
		document: doc({}),
		values: { avatar: '' },
		uploadFile: syntheticUpload
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				uploadFile={args.uploadFile}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="AcceptAttributeFlowsFromDefinition"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The `accept` allow-list on the doctype definition must reach the
		// underlying <input type="file"> so the OS file picker filters to
		// image MIMEs.
		const input = canvas.getByLabelText('Avatar') as HTMLInputElement;
		await expect(input.accept).toBe('image/*');
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar',
			placeholder: 'Drop a file or click to attach'
		} satisfies InputFileNode,
		document: doc({}),
		values: { avatar: '' },
		def: imageOnlyDef,
		uploadFile: syntheticUpload
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
				uploadFile={args.uploadFile}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="RejectsMismatchedMime"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const drop = canvas.getByRole('button', { name: /drop a file or click to attach/i });
		// Simulate a drag-and-drop of a PDF onto an image-only field. The
		// HTML `accept` attribute only filters the OS file picker — drag-drop
		// bypasses it, which is exactly the surface the client-side rejection
		// path guards against (mirroring the server-side `FileMimeCheck`).
		const mismatched = new File(['x'], 'notes.pdf', { type: 'application/pdf' });
		const dt = new DataTransfer();
		try {
			dt.items.add(mismatched);
		} catch {
			Object.defineProperty(dt, 'files', { value: [mismatched], writable: false });
		}
		drop.dispatchEvent(new DragEvent('drop', { dataTransfer: dt }));
		// Svelte flushes the rejection error on the next microtask.
		await waitFor(() => {
			expect(canvas.getByText(/application\/pdf/)).toBeVisible();
			expect(canvas.getByText(/image\/\*/)).toBeVisible();
		});
	}}
	args={{
		template: {
			type: 'input-file',
			field: 'avatar',
			label: 'Avatar',
			placeholder: 'Drop a file or click to attach'
		} satisfies InputFileNode,
		document: doc({}),
		values: { avatar: '' },
		def: imageOnlyDef,
		uploadFile: async (file: File) => ({ id: SYNTHETIC_ID, filename: file.name })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtInputFile
				template={args.template}
				document={args.document}
				values={sessionBag(args.values)}
				def={args.def}
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
