<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack } from 'svelte';
	import { type DeployFile } from '$lib/app/deployments';
	import { validateDeployPath } from '$lib/app/appValidation';
	import { SvelteMap } from 'svelte/reactivity';
	import { Rocket, FolderOpen, FileUp } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * DeployPanel — the body of the app deploy flow: pick a build folder
	 * (or loose files), review the paths, and hand one upload to the host
	 * page. The page sends it as one multipart request to
	 * `POST /Api/app/:id/deploy` for the app it loaded; that request
	 * uploads, activates, and computes the revision atomically. Progress
	 * per file is out of scope — one spinner.
	 *
	 * The facet CLI is the intended deploy surface once it ships; this
	 * panel is the dashboard-operator fallback, and the notice says so.
	 */

	let {
		busy = false,
		onDeploy,
		onCancel
	}: {
		/** True while the host uploads. Shows the spinner and disables the controls. */
		busy?: boolean;
		/** Uploads the picked files as one deployment. Throws on failure (the page maps it). */
		onDeploy: (input: {
			files: DeployFile[];
			note: string;
			spa: boolean;
			activate: boolean;
		}) => void | Promise<void>;
		/** Closes the deploy flow. The page navigates back to the detail page. */
		onCancel: () => void;
	} = $props();

	// The upload contract: note, SPA fallback, and activate ride the same
	// request as the files, so they live in one draft bag.
	let upload = $state({ note: '', spa: true, activate: true });

	let folderFiles = $state<FileList | null>(null);
	let looseFiles = $state<FileList | null>(null);

	/** `webkitdirectory` is non-standard — set it imperatively. */
	function directory(node: HTMLInputElement): void {
		node.setAttribute('webkitdirectory', '');
	}

	/**
	 * Derive the deployment path for a picked file. A folder picker carries
	 * `webkitRelativePath` (`dist/assets/app.js`) — the leading folder name
	 * is stripped so paths are relative to the app root. A plain file
	 * selection has no relative path; the file name is used.
	 */
	function pathFor(file: File): string {
		const rel = (file as File & { webkitRelativePath?: string }).webkitRelativePath;
		if (rel && rel.includes('/')) return rel.slice(rel.indexOf('/') + 1);
		return file.name;
	}

	let entries = $derived.by(() => {
		const picked = [...(folderFiles ?? []), ...(looseFiles ?? [])].map((file) => ({
			file,
			path: pathFor(file)
		}));
		// De-duplicate by path: a loose re-pick of a file also inside the
		// folder selection wins (it comes later and is the newer intent).
		// untrack: interleaved set/get on a tracked map inside a derivation
		// self-dirties it and re-runs the derivation.
		return untrack(() => {
			const byPath = new SvelteMap<string, (typeof picked)[number]>();
			for (const entry of picked) byPath.set(entry.path, entry);
			return [...byPath.values()];
		});
	});

	let pathErrors = $derived(
		entries
			.map((entry) => ({ entry, error: validateDeployPath(entry.path) }))
			.filter((e): e is { entry: DeployFile; error: string } => e.error !== null)
	);

	let ready = $derived(entries.length > 0 && pathErrors.length === 0 && !busy);

	async function deploy(): Promise<void> {
		if (!ready) return;
		await onDeploy({
			files: entries,
			note: upload.note,
			spa: upload.spa,
			activate: upload.activate
		});
	}
</script>

<div class="cli-note">
	<div class="cli-note-text">
		{m.configure_apps_deploy_note()}
		<button type="button" class="cli-note-link">{m.configure_apps_cli_guide()}</button>
	</div>
</div>

<Can doctype="app.App" action="update">
	<div class="form">
		<div class="pickers">
			<label class="picker">
				<FolderOpen size={16} strokeWidth={1.9} aria-hidden="true" />
				<span class="picker-label">{m.configure_apps_build_folder()}</span>
				<span class="picker-sub">{m.configure_apps_build_folder_sub()}</span>
				<input
					type="file"
					multiple
					use:directory
					onchange={(e) => (folderFiles = e.currentTarget.files)}
				/>
			</label>

			<label class="picker">
				<FileUp size={16} strokeWidth={1.9} aria-hidden="true" />
				<span class="picker-label">{m.configure_apps_loose_files()}</span>
				<span class="picker-sub">{m.configure_apps_loose_files_sub()}</span>
				<input type="file" multiple onchange={(e) => (looseFiles = e.currentTarget.files)} />
			</label>
		</div>

		{#if entries.length > 0}
			<div class="manifest">
				<div class="manifest-title">
					{entries.length === 1
						? m.configure_apps_file_singular({ count: entries.length })
						: m.configure_apps_files_count({ count: entries.length })}
				</div>
				<ul>
					{#each entries as entry (entry.path)}
						<li>
							<span class="mono">{entry.path}</span>
							<span class="size">{(entry.file.size / 1024).toFixed(1)} kB</span>
						</li>
					{/each}
				</ul>
				{#if pathErrors.length > 0}
					<div class="path-errors">
						{#each pathErrors as { entry, error: err } (entry.path)}
							<div><span class="mono">{entry.path}</span> — {err}</div>
						{/each}
					</div>
				{/if}
			</div>
		{/if}

		<Input
			label={m.configure_apps_note_label()}
			placeholder="fix login bug"
			bind:value={upload.note}
		/>

		<div class="toggles">
			<Toggle label={m.configure_apps_spa_toggle()} bind:checked={upload.spa} />
			<Toggle label={m.configure_apps_activate_toggle()} bind:checked={upload.activate} />
		</div>

		<div class="actions">
			<Button variant="primary" disabled={!ready} onclick={deploy}>
				{#snippet iconLeft()}
					{#if busy}
						<span class="spinner" aria-hidden="true"></span>
					{:else}
						<Rocket size={13} strokeWidth={2} aria-hidden="true" />
					{/if}
				{/snippet}
				{busy
					? m.configure_apps_uploading()
					: upload.activate
						? m.configure_apps_deploy_activate()
						: m.configure_apps_deploy_short()}
			</Button>
			<Button variant="ghost" disabled={busy} onclick={onCancel}>
				{m.common_cancel()}
			</Button>
		</div>
	</div>
</Can>

<style>
	.cli-note {
		padding: 10px 12px;
		font-size: 13px;
		line-height: 1.55;
		color: var(--text-2);
		background: var(--info-weak, rgba(59, 130, 246, 0.1));
		border: 1px solid var(--info, #3b82f6);
		border-radius: var(--r);
	}

	.cli-note-link {
		font: inherit;
		color: var(--info);
		font-weight: 600;
		text-decoration: none;
		margin-left: 4px;
		background: none;
		border: none;
		padding: 0;
		cursor: pointer;
	}

	.cli-note-link:hover {
		text-decoration: underline;
	}

	.form {
		display: flex;
		flex-direction: column;
		gap: 16px;
		max-width: 560px;
	}

	.pickers {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px;
	}

	.picker {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 4px;
		padding: 14px;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		cursor: pointer;
		color: var(--accent);
		transition:
			border-color 0.12s,
			background 0.12s;
	}

	.picker:hover {
		border-color: var(--accent);
		background: var(--accent-weak);
	}

	.picker input {
		display: none;
	}

	.picker-label {
		font-size: 14px;
		font-weight: 500;
		color: var(--text);
		margin-top: 6px;
	}

	.picker-sub {
		font-size: 12px;
		color: var(--text-3);
	}

	.manifest {
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 10px 12px;
		max-height: 220px;
		overflow-y: auto;
	}

	.manifest-title {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--text-3);
		margin-bottom: 6px;
	}

	.manifest ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.manifest li {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 12px;
	}

	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-2);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.size {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		flex: none;
	}

	.path-errors {
		margin-top: 8px;
		padding-top: 8px;
		border-top: 1px solid var(--border);
		font-size: 12px;
		color: var(--danger, #dc2626);
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.toggles {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.actions {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.spinner {
		width: 12px;
		height: 12px;
		border: 2px solid color-mix(in srgb, var(--on-accent) 30%, transparent);
		border-top-color: var(--on-accent);
		border-radius: 50%;
		animation: spin 0.7s linear infinite;
	}

	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.spinner {
			animation-duration: 1.4s;
		}
	}
</style>
