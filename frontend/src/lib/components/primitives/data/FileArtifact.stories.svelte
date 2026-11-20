<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, waitFor } from 'storybook/test';
	import FileArtifact from './FileArtifact.svelte';
	import type { ArtifactGrant } from './FileArtifact.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/FileArtifact',
		component: FileArtifact,
		tags: ['autodocs'],
		argTypes: {
			artifactId: { control: 'text' },
			fetchArtifact: { control: false }
		}
	});

	const SYNTHETIC_ID = '01HZZZZZZZZZZZZZZZZZZZZZZZ';
	const SYNTHETIC_DOWNLOAD_HREF = `/Api/core/artifacts/${SYNTHETIC_ID}/download`;

	function syntheticGrant(id: string): Promise<ArtifactGrant> {
		return Promise.resolve({
			id,
			filename: 'pixel.png',
			mime_type: 'image/png',
			size: 5,
			url: 'https://artifact.example/a/grant-1?exp=1234&sig=abc',
			expires_at: '2026-08-21T12:00:00Z'
		});
	}
</script>

<Story
	name="Default"
	args={{ artifactId: SYNTHETIC_ID, fetchArtifact: syntheticGrant }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// On mount the component resolves the artifact metadata, so the
		// link label flips from the bare id to the filename. Until the
		// fetch resolves, the id remains the visible fallback.
		await waitFor(() => {
			const link = canvas.getByRole('link');
			expect(link.textContent ?? '').toContain('pixel.png');
		});
		const link = canvas.getByRole('link');
		await expect(link).toHaveAttribute('target', '_blank');
		await expect(link).toHaveAttribute('rel', 'noopener noreferrer external');
		// The href is the gateway download route — no client-side mint, no
		// stale signed URL in the DOM. The grant is minted server-side on
		// every click and the browser follows a 302 to the serve URL.
		await expect(link).toHaveAttribute('href', SYNTHETIC_DOWNLOAD_HREF);
	}}
>
	{#snippet template(args)}
		<FileArtifact artifactId={args.artifactId} fetchArtifact={args.fetchArtifact} />
	{/snippet}
</Story>

<Story
	name="FallsBackOnFetchError"
	args={{
		artifactId: SYNTHETIC_ID,
		fetchArtifact: () => Promise.reject(new Error('boom'))
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// When filename resolution fails on mount, the label falls back to the
		// raw artifact id and remains visible. The download link is unaffected
		// — the gateway mints a grant server-side regardless of filename
		// fetch outcome, so the href is still the gateway route.
		await waitFor(() => {
			const link = canvas.getByRole('link');
			expect(link.textContent ?? '').toContain(SYNTHETIC_ID);
		});
		const link = canvas.getByRole('link');
		await expect(link).toHaveAttribute('href', SYNTHETIC_DOWNLOAD_HREF);
		// No error flag — the filename fetch is best-effort and the link works
		// regardless (the gateway route handles auth + mint server-side).
	}}
>
	{#snippet template(args)}
		<FileArtifact artifactId={args.artifactId} fetchArtifact={args.fetchArtifact} />
	{/snippet}
</Story>

<Story name="LongId">
	<div style="width: 180px">
		<FileArtifact artifactId="01HZZZZZZZZZZZZZZZZZZZZZZZ" fetchArtifact={syntheticGrant} />
	</div>
</Story>
