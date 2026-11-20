<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Download } from '@lucide/svelte';
	import DropdownMenu from '$lib/components/primitives/actions/DropdownMenu.svelte';
	import { apiFetch } from '$lib/session.svelte.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import { toast } from '$lib/toast.svelte.js';
	import {
		enqueueExport,
		enqueueViewExport,
		pollJob,
		downloadUrl,
		ImportError,
		type FetchImpl,
		type ImportFormat,
		type ViewExportItem
	} from '$lib/importExport/importExportClient.js';

	/**
	 * ExportMenu — the table toolbar's export affordance. One trigger, a
	 * format choice (CSV / JSON) plus — when the caller carries a table
	 * view state — a "CSV — current view" item that exports the visible
	 * columns under the current filters and sort. Fire-and-forget
	 * execution: the job enqueues, the menu closes, and a completion toast
	 * carries the download link when the file is ready. The backend's
	 * notification is the durable human surface; the toast is the
	 * immediate one.
	 */
	let {
		/** The doctype being exported (e.g. `crm.Company`). */
		domain,
		doctype,
		/**
		 * The table's current view state. `null` — trash mode, or a surface
		 * that shows no view export — hides the view item.
		 */
		view = null,
		/** Injectable fetch — defaults to `apiFetch` (token refresh + 401 recovery). Stories stub it. */
		fetchImpl = apiFetch as unknown as FetchImpl
	}: {
		domain: string;
		doctype: string;
		view?: ViewExportItem | null;
		fetchImpl?: FetchImpl;
	} = $props();

	let running = $state(false);

	async function runExport(format: ImportFormat) {
		if (running) return;
		running = true;
		try {
			const enqueued = await enqueueExport(fetchImpl, domain, doctype, format);
			toast({
				message: m.impex_export_started()
			});

			// Fire-and-forget poll: the toast surfaces completion either way.
			void pollJob(fetchImpl, domain, doctype, enqueued.jobId).then((outcome) => {
				if (outcome.mode === 'timeout') return;
				if (outcome.status.status === 'succeeded') {
					toast({
						message: m.impex_export_ready(),
						variant: 'ok',
						action: {
							label: m.impex_download(),
							href: downloadUrl(domain, doctype, enqueued.jobId)
						}
					});
				} else {
					// The backend's rejection rides the failed outcome —
					// surface it verbatim, as the import dialog does.
					toast({
						message: outcome.status.error ?? m.impex_export_failed(),
						variant: 'error'
					});
				}
			});
		} catch (e) {
			toast({
				message: e instanceof ImportError ? e.message : m.impex_export_start_failed(),
				variant: 'error'
			});
		} finally {
			running = false;
		}
	}

	/** The view export — same flow, the view payload plus the display zone. */
	async function runViewExport(view: ViewExportItem) {
		if (running) return;
		running = true;
		try {
			const enqueued = await enqueueViewExport(fetchImpl, domain, doctype, {
				columns: view.columns,
				filters: view.filters,
				sort: view.sort,
				timezone: displayTimezone()
			});
			toast({
				message: m.impex_export_started()
			});

			void pollJob(fetchImpl, domain, doctype, enqueued.jobId).then((outcome) => {
				if (outcome.mode === 'timeout') return;
				if (outcome.status.status === 'succeeded') {
					toast({
						message: m.impex_export_view_ready(),
						variant: 'ok',
						action: {
							label: m.impex_download(),
							href: downloadUrl(domain, doctype, enqueued.jobId)
						}
					});
				} else {
					toast({
						message: outcome.status.error ?? m.impex_export_failed(),
						variant: 'error'
					});
				}
			});
		} catch (e) {
			toast({
				message: e instanceof ImportError ? e.message : m.impex_export_start_failed(),
				variant: 'error'
			});
		} finally {
			running = false;
		}
	}

	/** Hidden with no view state (trash mode) or no data columns to export. */
	const viewExportable = $derived(view !== null && view.columns.length > 0);

	const items = $derived.by(() => {
		const base = [
			{
				label: running ? m.impex_exporting_csv() : m.impex_export_csv(),
				disabled: running,
				onclick: () => runExport('csv')
			},
			{
				label: running ? m.impex_exporting_json() : m.impex_export_json(),
				disabled: running,
				onclick: () => runExport('json')
			}
		];
		if (viewExportable && view) {
			base.push({
				label: running ? m.impex_exporting_view() : m.impex_export_view_csv(),
				disabled: running,
				onclick: () => runViewExport(view)
			});
		}
		return base;
	});
</script>

<DropdownMenu label={m.impex_export()} {items}>
	<span class="exp-trigger">
		<Download size={13} strokeWidth={2} aria-hidden="true" />
		{m.impex_export()}
	</span>
</DropdownMenu>

<style>
	.exp-trigger {
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}
</style>
