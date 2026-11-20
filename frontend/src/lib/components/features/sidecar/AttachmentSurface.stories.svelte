<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import AttachmentSurface from './AttachmentSurface.svelte';
	import CanFixture from '$lib/components/features/admin/CanFixture.svelte';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';

	/**
	 * AttachmentSurface stories mount the file-attachment sidecar against a
	 * mock host. Artifact metadata (MIME type, size) resolves through an
	 * injectable synthetic fetcher — the real surface defaults to the
	 * cookie-auth `GET /Api/core/artifacts/:id` metadata route. The upload
	 * flow is driven through the hidden file input with a synthetic uploader
	 * (the real path is `POST /Api/core/artifacts` → nested JSON create);
	 * the mock route stamps `target`, the backend forces `uploaded_by`
	 * server-side via Lua.
	 */

	type SyntheticMeta = { mime_type: string; size: number; filename: string };

	function makeDriver(seedAttachments: boolean): MockDataDriver {
		const driver = new MockDataDriver();
		driver.registerDoctype('crm', 'Deal', {
			doctype: 'Deal',
			domain: 'crm',
			sidecar: true,
			sidecars: { attachments: { doctype: 'core.Attachment', column: 'target' } }
		});
		driver.registerDoctype('core', 'Attachment', {
			doctype: 'Attachment',
			domain: 'core',
			surface: 'attachment',
			fields: {
				target: { key: 'target', type: 'reference', read_only: true, title: 'Target' },
				uploaded_by: {
					key: 'uploaded_by',
					type: 'reference',
					read_only: true,
					title: 'Uploaded by'
				},
				name: { key: 'name', type: 'string', required: true, title: 'Name' },
				file: { key: 'file', type: 'file', required: true, title: 'File' }
			}
		});
		driver.registerDoctype('iam', 'Account', {
			doctype: 'Account',
			domain: 'iam',
			fields: {
				name: { key: 'name', type: 'string', title: 'Name' }
			}
		});
		void driver.domain('crm').doctype('Deal', [{ id: 'crm.Deal.1', name: 'Platform License' }]);
		void driver.domain('iam').doctype('Account', [
			{ id: 'account_kim', name: 'Kim Alvein' },
			{ id: 'account_rex', name: 'Rex Mundi' }
		]);
		if (seedAttachments) {
			void driver.domain('core').doctype('Attachment', [
				{
					id: 'a1',
					name: 'Employment contract.pdf',
					file: 'art_contract',
					target: 'crm.Deal.1',
					uploaded_by: 'iam.Account.account_kim'
				},
				{
					id: 'a2',
					name: 'Onboarding photo.png',
					file: 'art_photo',
					target: 'crm.Deal.1',
					uploaded_by: 'iam.Account.account_rex'
				},
				// System-created attachment: no uploader — the identity degrades.
				{
					id: 'a3',
					name: 'Scanner output',
					file: 'art_scan',
					target: 'crm.Deal.1'
				}
			]);
		}
		return driver;
	}

	/** Metadata the synthetic fetcher serves, keyed by artifact id. */
	const syntheticMeta: Record<string, SyntheticMeta> = {
		art_contract: { mime_type: 'application/pdf', size: 1_284_312, filename: 'contract.pdf' },
		art_photo: { mime_type: 'image/png', size: 348_112, filename: 'photo.png' },
		art_scan: { mime_type: 'application/octet-stream', size: 51_200, filename: 'scan.bin' }
	};

	/** Builds a driver whose uploads register synthetic artifact metadata. */
	function makeUploadingDriver(seedAttachments: boolean): {
		driver: MockDataDriver;
		uploadFile: (file: File) => Promise<{ id: string; filename: string }>;
	} {
		const driver = makeDriver(seedAttachments);
		let seq = 0;
		const uploadFile = async (file: File) => {
			seq += 1;
			const id = `art_upload_${seq}`;
			syntheticMeta[id] = {
				mime_type: file.type || 'application/octet-stream',
				size: file.size,
				filename: file.name
			};
			return { id, filename: file.name };
		};
		return { driver, uploadFile };
	}

	const seeded = makeDriver(true);
	const empty = makeDriver(false);
	// Fresh instances for the stories whose play functions mutate state —
	// module state is shared across stories in one browser run
	// (vite.config.ts → storybook project, isolate: false).
	const uploadInstance = makeUploadingDriver(true);
	const renameInstance = makeUploadingDriver(true);
	const thumbnailInstance = makeDriver(true);

	const driver = seeded;
	const uploadDriver = uploadInstance.driver;
	const renameDriver = renameInstance.driver;
	const thumbnailDriver = thumbnailInstance;

	const hostDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('crm.Deal') as Record<string, unknown>
	);
	const attachmentDef: DoctypeDef = parseDoctypeDef(
		driver.getDoctypeDefinition('core.Attachment') as Record<string, unknown>
	);

	const hostDoc: DocumentResponse = {
		data: { name: 'Platform License' },
		meta: {
			id: 'crm.Deal.1',
			mid: 'crm.Deal.1',
			domain: 'crm',
			doc_type: 'Deal',
			version: 1,
			schema_version: 1,
			display_name: 'Platform License',
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString()
		}
	};

	/** Unrestricted — composer plus every affordance is visible. */
	const adminManifest = { '*.*': ['*'] };
	/** Composer only: host create grant, no flat `core.Attachment` grants —
	 *  the per-row rename/delete affordances stay hidden. */
	const composerOnlyManifest = { 'crm.Deal': ['create'] };
	/**
	 * `$mine`-shaped flat grants on the attachment doctype (the seeded
	 * `attachment_owner` role): the host create grant enables the composer,
	 * the `core.Attachment` grants enable rename/delete affordances.
	 */
	const mineManifest = {
		'crm.Deal': ['create'],
		'core.Attachment': ['read', 'update', 'delete']
	};

	const { Story } = defineMeta({
		title: 'Components/Features/Sidecar/AttachmentSurface',
		component: AttachmentSurface,
		tags: ['autodocs'],
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});

	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

	/** Synthetic metadata fetcher bound to the shared meta table. */
	function syntheticFetchMeta(id: string): Promise<SyntheticMeta | null> {
		return Promise.resolve(syntheticMeta[id] ?? null);
	}

	/**
	 * Synthetic artifact URL for the thumbnail story. The real gateway URL is
	 * `/Api/core/artifacts/:id/download`, which 404s in the test browser — the
	 * surface's `onerror` fallback would then replace the thumbnail with the
	 * icon. This seam keeps the `<img>` mounted and loaded: an image artifact
	 * resolves to a 1×1 transparent pixel, a same-origin data URL that never
	 * touches the backend. Non-image artifacts keep the gateway-shaped path so
	 * the link assertions stay meaningful.
	 */
	const PIXEL =
		'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

	function syntheticArtifactUrl(id: string): string {
		const mime = syntheticMeta[id]?.mime_type ?? '';
		return mime.startsWith('image/') ? PIXEL : `/Api/core/artifacts/${id}/download`;
	}
</script>

<script lang="ts">
	import { expect, within, userEvent } from 'storybook/test';
</script>

<Story
	name="Empty"
	play={async ({ canvasElement }) => {
		await sleep(300);
		const canvas = within(canvasElement);
		await expect(canvas.getByText('No attachments yet.')).toBeVisible();
		// The composer is present with the host create grant.
		await expect(canvas.getByTestId('attachment-composer')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={adminManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<AttachmentSurface
					driver={empty}
					{hostDef}
					{hostDoc}
					segment="attachments"
					sidecarDef={attachmentDef}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="Seeded"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Rows render oldest first with resolved uploader identities.
		await expect(canvas.getByText('Employment contract.pdf')).toBeVisible();
		await expect(canvas.getByText('Onboarding photo.png')).toBeVisible();
		await expect(canvas.getByText('by Kim Alvein')).toBeVisible();
		await expect(canvas.getByText('by Rex Mundi')).toBeVisible();
		// Type labels derive from the artifact MIME (synthetic metadata).
		await expect(canvas.getByText('PDF')).toBeVisible();
		await expect(canvas.getByText('PNG')).toBeVisible();
		// Unknown MIME degrades to the OCT label.
		await expect(canvas.getByText('OCT')).toBeVisible();
		// Sizes render in human form.
		await expect(canvas.getByText('1.2 MB')).toBeVisible();
		await expect(canvas.getByText('340.0 KB')).toBeVisible();
		// One download gateway link per row. Inline-renderable types (images)
		// must not navigate the app tab away — links open a new tab.
		const downloadLinks = canvas.getAllByRole('link', { name: 'Download attachment' });
		await expect(downloadLinks.length).toBe(3);
		for (const link of downloadLinks) {
			await expect(link).toHaveAttribute('target', '_blank');
			await expect(link).toHaveAttribute('rel', 'noopener noreferrer external');
		}
		// No flat `core.Attachment` grants → no rename/delete affordances.
		await expect(canvas.queryByRole('button', { name: 'Rename attachment' })).toBeNull();
		await expect(canvas.queryByRole('button', { name: 'Delete attachment' })).toBeNull();

		// Upload flow: pick a file (the label pre-fills from its name), then
		// attach — the new row appears with the derived name and type label.
		const input = canvasElement.querySelector<HTMLInputElement>(
			'[data-testid="attachment-file-input"]'
		);
		if (!input) throw new Error('File input not mounted');
		const pdf = new File(['%PDF-1.4 fake'], 'termination letter.pdf', { type: 'application/pdf' });
		await userEvent.upload(input, pdf);
		await sleep(100);
		const nameInput = canvas.getByRole('textbox', { name: 'Attachment name' }) as HTMLInputElement;
		await expect(nameInput.value).toBe('termination letter.pdf');
		const attachBtn = canvas.getByRole('button', { name: 'Attach' }) as HTMLButtonElement;
		await expect(attachBtn).toBeEnabled();
		await userEvent.click(attachBtn);
		await sleep(300);
		await expect(canvas.getByText('termination letter.pdf')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={composerOnlyManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<AttachmentSurface
					driver={uploadDriver}
					{hostDef}
					{hostDoc}
					segment="attachments"
					sidecarDef={attachmentDef}
					uploadFile={uploadInstance.uploadFile}
					fetchArtifactMeta={syntheticFetchMeta}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<!--
	The flat `attachment_owner` role shape: `create` on the host (implied
	nested-create grant) plus flat `update`/`delete` on `core.Attachment` —
	rename and delete affordances become visible per row; the play renames
	one attachment through the inline editor.
-->

<Story
	name="MineAffordances"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		await expect(canvas.getAllByRole('button', { name: 'Rename attachment' }).length).toBe(3);
		await expect(canvas.getAllByRole('button', { name: 'Delete attachment' }).length).toBe(3);
		await expect(canvas.getByTestId('attachment-composer')).toBeVisible();

		// Rename the first attachment: the inline editor pre-fills, saving
		// swaps the row label.
		const firstRow = canvasElement.querySelector<HTMLElement>('[data-attachment-id]');
		if (!firstRow) throw new Error('No attachment row found');
		const renameBtn = firstRow.querySelector<HTMLButtonElement>(
			'button[aria-label="Rename attachment"]'
		);
		if (!renameBtn) throw new Error('Rename affordance not found');
		await userEvent.click(renameBtn);
		await sleep(100);
		const input = firstRow.querySelector<HTMLInputElement>('input[aria-label="Attachment name"]');
		if (!input) throw new Error('Rename input not mounted');
		await userEvent.clear(input);
		await userEvent.type(input, 'Signed contract.pdf');
		await sleep(100);
		const saveBtn = firstRow.querySelector<HTMLButtonElement>('button.at-btn-primary');
		if (!saveBtn) throw new Error('Save button not found');
		await userEvent.click(saveBtn);
		await sleep(300);
		await expect(canvas.getByText('Signed contract.pdf')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={mineManifest}>
			<div style="max-width: 480px; padding: 24px;">
				<AttachmentSurface
					driver={renameDriver}
					{hostDef}
					{hostDoc}
					segment="attachments"
					sidecarDef={attachmentDef}
					fetchArtifactMeta={syntheticFetchMeta}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="ThumbnailsAndPreview"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// The image-mime row renders a lazy thumbnail through the download
		// gateway; the PDF row keeps its icon and gains a preview link.
		const photoRow = canvasElement.querySelector<HTMLElement>('[data-attachment-id="a2"]');
		if (!photoRow) throw new Error('Photo row not found');
		// No backend in the test browser: the download gateway URL 404s within a
		// few milliseconds and the documented `onerror` fallback swaps the
		// thumbnail for the image icon before any assertion can sample it. The
		// story therefore injects a synthetic `artifactUrl` serving a 1×1 pixel,
		// so the thumbnail actually loads and the fallback stays dormant. The
		// gateway URL shape itself is asserted on the download/preview links.
		const thumb = photoRow.querySelector<HTMLImageElement>('img.at-thumb');
		if (!thumb) throw new Error('Thumbnail not rendered');
		await expect(thumb.getAttribute('src')).toBe(PIXEL);
		await expect(thumb).toHaveAttribute('loading', 'lazy');
		await expect(thumb).toHaveAttribute('alt', '');
		await expect(thumb.naturalWidth).toBe(1);

		const contractRow = canvasElement.querySelector<HTMLElement>('[data-attachment-id="a1"]');
		if (!contractRow) throw new Error('Contract row not found');
		await expect(contractRow.querySelector('img.at-thumb')).toBeNull();
		const preview = contractRow.querySelector<HTMLAnchorElement>(
			'a[data-testid^="attachment-preview-"]'
		);
		if (!preview) throw new Error('PDF preview link not found');
		await expect(preview.getAttribute('href')).toBe('/Api/core/artifacts/art_contract/download');
		await expect(preview).toHaveAttribute('target', '_blank');

		// Non-PDF, non-image rows (octet-stream) get no preview link.
		const scanRow = canvasElement.querySelector<HTMLElement>('[data-attachment-id="a3"]');
		if (!scanRow) throw new Error('Scan row not found');
		await expect(scanRow.querySelector('a[data-testid^="attachment-preview-"]')).toBeNull();

		// One preview link in the whole list — the PDF row only.
		await expect(canvas.getAllByRole('link', { name: 'Preview attachment' }).length).toBe(1);
		// The download link per row is unchanged.
		await expect(canvas.getAllByRole('link', { name: 'Download attachment' }).length).toBe(3);
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'core.Attachment': ['read'] }}>
			<div style="max-width: 480px; padding: 24px;">
				<AttachmentSurface
					driver={thumbnailDriver}
					{hostDef}
					{hostDoc}
					segment="attachments"
					sidecarDef={attachmentDef}
					fetchArtifactMeta={syntheticFetchMeta}
					artifactUrl={syntheticArtifactUrl}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>

<Story
	name="NoHostCreateGrant"
	play={async ({ canvasElement }) => {
		await sleep(400);
		const canvas = within(canvasElement);
		// Without the host create grant the composer is locked with a hint.
		await expect(canvas.getByText('You cannot attach files to this document.')).toBeVisible();
		await expect(canvas.queryByTestId('attachment-composer')).toBeNull();
		// The list still renders.
		await expect(canvas.getByText('Employment contract.pdf')).toBeVisible();
	}}
>
	{#snippet template()}
		<CanFixture manifest={{ 'core.Attachment': ['read'] }}>
			<div style="max-width: 480px; padding: 24px;">
				<AttachmentSurface
					{driver}
					{hostDef}
					{hostDoc}
					segment="attachments"
					sidecarDef={attachmentDef}
					fetchArtifactMeta={syntheticFetchMeta}
				/>
			</div>
		</CanFixture>
	{/snippet}
</Story>
