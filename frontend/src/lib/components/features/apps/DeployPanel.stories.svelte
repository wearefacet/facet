<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor, fireEvent, fn } from 'storybook/test';
	import DeployPanel from './DeployPanel.svelte';
	import { setPermissions } from '$lib/permissions.svelte';

	/**
	 * Component tests for the deploy flow panel. `onDeploy` and `onCancel`
	 * are spies, so no backend runs. The whole form sits inside
	 * `<Can doctype="app.App" action="update">`, so the admin wildcard
	 * hydrates the global permission store before the first story mounts.
	 * The picker inputs are hidden (the label is the click target); the
	 * plays feed them through `fireEvent.change`, which sets `files`
	 * without a pointer walk.
	 */

	setPermissions({ '*.*': ['*'] });

	/** The loose-files picker input (the folder picker comes first in the DOM). */
	function looseInput(canvasElement: HTMLElement): HTMLInputElement {
		const input = canvasElement.querySelectorAll('input[type="file"]')[1];
		if (!input) throw new Error('Loose-files input not mounted');
		return input as HTMLInputElement;
	}

	/** The args type erases the Mock; every play casts through this shape. */
	type AnyMock = { mock: { calls: unknown[][] } };
	const cbMock = (args: Record<string, unknown>, key: string): AnyMock =>
		args[key] as unknown as AnyMock;

	const baseArgs = () => ({
		busy: false,
		onDeploy: fn(
			async (_input: { files: unknown[]; note: string; spa: boolean; activate: boolean }) => {}
		),
		onCancel: fn(() => {})
	});

	const { Story } = defineMeta({
		title: 'Components/Features/Apps/DeployPanel',
		component: DeployPanel,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Both pickers and the CLI notice render.
		await expect(canvas.getByText('Build folder')).toBeVisible();
		await expect(canvas.getByText('Loose files')).toBeVisible();
		await expect(canvas.getByText('Deployment guide')).toBeVisible();
		// Options default to SPA + activate; the note field is empty.
		await expect(canvas.getByLabelText('Note (optional)')).toHaveValue('');
		await expect(
			canvas.getByRole('switch', { name: 'Serve as SPA (unknown paths fall back to index.html)' })
		).toHaveAttribute('aria-checked', 'true');
		await expect(
			canvas.getByRole('switch', { name: 'Activate this build after upload' })
		).toHaveAttribute('aria-checked', 'true');
		// Without files the deploy action stays blocked.
		await expect(canvas.getByRole('button', { name: 'Deploy and activate' })).toBeDisabled();
		await expect(canvas.getByRole('button', { name: 'Cancel' })).toBeEnabled();
		// The SPA flag only controls the fallback behaviour — the action
		// label follows the activate flag. Turning activate off renames the
		// action to a plain deploy (still blocked without files).
		await userEvent.click(
			canvas.getByRole('switch', { name: 'Serve as SPA (unknown paths fall back to index.html)' })
		);
		await expect(
			canvas.getByRole('switch', { name: 'Serve as SPA (unknown paths fall back to index.html)' })
		).toHaveAttribute('aria-checked', 'false');
		await expect(canvas.getByRole('button', { name: 'Deploy and activate' })).toBeDisabled();
		await userEvent.click(canvas.getByRole('switch', { name: 'Activate this build after upload' }));
		await expect(canvas.getByRole('button', { name: 'Deploy' })).toBeDisabled();
	}}
	args={baseArgs()}
/>

<Story
	name="UploadFlowReportsPayload"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.type(canvas.getByLabelText('Note (optional)'), 'hotfix 2');
		// Feed one file to the loose-files picker; the manifest lists its path.
		const file = new File(['<html></html>'], 'index.html', { type: 'text/html' });
		fireEvent.change(looseInput(canvasElement), { target: { files: [file] } });
		await waitFor(() => expect(canvas.getByText('index.html')).toBeVisible());
		await expect(canvas.getByText('1 file')).toBeVisible();
		// The upload action unblocks, then reports the full payload.
		await userEvent.click(canvas.getByRole('button', { name: 'Deploy and activate' }));
		await waitFor(() => expect(cbMock(args, 'onDeploy').mock.calls.length).toBe(1));
		const input = cbMock(args, 'onDeploy').mock.calls[0][0] as {
			files: { path: string; file: File }[];
			note: string;
			spa: boolean;
			activate: boolean;
		};
		await expect(input.files.length).toBe(1);
		await expect(input.files[0].path).toBe('index.html');
		await expect(input.files[0].file.name).toBe('index.html');
		await expect(input.note).toBe('hotfix 2');
		await expect(input.spa).toBe(true);
		await expect(input.activate).toBe(true);
	}}
	args={baseArgs()}
/>

<Story
	name="UnsafePathBlocksDeploy"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A traversal path fails the safe-path rule; the error names it and
		// the deploy action stays blocked.
		const file = new File(['evil'], '../evil.js', { type: 'text/javascript' });
		fireEvent.change(looseInput(canvasElement), { target: { files: [file] } });
		await waitFor(() => expect(canvas.getByText(/Must not contain/)).toBeVisible());
		await expect(canvas.getByRole('button', { name: 'Deploy and activate' })).toBeDisabled();
	}}
	args={baseArgs()}
/>

<Story
	name="CancelReportsToHost"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(cbMock(args, 'onCancel').mock.calls.length).toBe(1));
	}}
	args={baseArgs()}
/>
