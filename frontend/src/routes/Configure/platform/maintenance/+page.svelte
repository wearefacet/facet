<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import MaintenancePanel from '$lib/components/features/platform/MaintenancePanel.svelte';
	import {
		fetchMaintenanceStatus,
		listMaintenanceJobs,
		enqueueReproject,
		enqueueMigrateAhead,
		MaintenanceError,
		type MaintenanceJobRow,
		type MaintenanceStatus,
		type MaintenanceActionKind
	} from '$lib/components/features/platform/MaintenanceSource.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { DataSourceError } from '$lib/datasource/types.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Doctype-maintenance page (/Configure/platform/maintenance).
	 *
	 * The page owns all fetch state and delegates rendering to
	 * `MaintenancePanel`. Nothing loads on mount — the operator picks a
	 * doctype from the reference picker (a `core.DocType` document) and the
	 * pick loads status + jobs. A failed status load renders the page-level
	 * state blocks (403 without retry, other errors with one); job-list
	 * failures surface as a banner inside the panel.
	 */

	const JOBS_PAGE_SIZE = 50;
	/** Poll cadence while a visible job is pending or running. */
	const POLL_INTERVAL_MS = 4000;

	// Status side. `requestedDoctype` keeps the `core.DocType` document id of
	// the load in flight (or the last one) so the retry button re-runs the
	// same request; `doctype` commits the qualified id only after a
	// successful load and gates the jobs section.
	let requestedDoctype: string = $state('');
	let doctype: string | null = $state(null);
	let status = $state<MaintenanceStatus | null>(null);
	let statusLoading: boolean = $state(false);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);
	let statusLoadSeq = 0;
	let statusSilentSeq = 0;

	// Jobs side.
	let jobs = $state<MaintenanceJobRow[]>([]);
	let jobsMeta = $state<{ count: number; more: boolean; page: number } | null>(null);
	let jobsPage: number = $state(1);
	let jobsLoading: boolean = $state(false);
	let jobsRefreshing: boolean = $state(false);
	let jobsError: string | undefined = $state(undefined);
	let jobsSeq = 0;

	// Enqueue side. Per-kind flags: the backend dedupes per kind (409), so
	// one enqueue of each kind may run at once.
	let busyKinds: Record<MaintenanceActionKind, boolean> = $state({
		reproject: false,
		migrate: false
	});
	let actionError: string | undefined = $state(undefined);

	/**
	 * Per-doctype display overrides for the picker, keyed by the `core.DocType`
	 * document id: the qualified id as the label, plus the doctype's own icon
	 * and tint. Without it every row shows the bare display label and wears
	 * core.DocType's blue.
	 */
	let doctypeMeta:
		| Record<string, { label: string; icon: string | null; color: string | null }>
		| undefined = $state(undefined);

	$effect(() => {
		driver
			.domain('core')
			.doctype('DocType')
			.list({ items: 500 })
			.then((res) => {
				const next: Record<string, { label: string; icon: string | null; color: string | null }> =
					{};
				for (const item of res.data) {
					const domain = item.data['domain'];
					const doctype = item.data['doctype'];
					if (typeof domain !== 'string' || typeof doctype !== 'string') continue;
					next[item.meta.id] = {
						label: `${domain}.${doctype}`,
						icon: typeof item.data['icon'] === 'string' ? item.data['icon'] : null,
						color: typeof item.data['color'] === 'string' ? item.data['color'] : null
					};
				}
				doctypeMeta = next;
			})
			.catch(() => {
				// The picker degrades to driver labels and the declared tint.
			});
	});

	/** Data driver for the doctype picker and pick resolution. */
	const driver = new DocumentDataDriver('');

	/**
	 * Resolve a picked `core.DocType` document to its qualified doctype id
	 * (`crm.Company`) — the form the maintenance routes serve. Driver failures
	 * re-throw as `MaintenanceError` so one error path renders them all.
	 */
	async function resolveQualifiedDoctype(docId: string): Promise<string> {
		try {
			const res = await driver.domain('core').doctype('DocType').doc(docId).show();
			const domain = res.data['domain'];
			const doctype = res.data['doctype'];
			if (typeof domain !== 'string' || typeof doctype !== 'string') {
				throw new MaintenanceError(404, m.platform_maintenance_load_error());
			}
			return `${domain}.${doctype}`;
		} catch (e) {
			if (e instanceof MaintenanceError) throw e;
			if (e instanceof DataSourceError) throw new MaintenanceError(e.status, e.message);
			throw e;
		}
	}

	/** Map a thrown value to the page-level state blocks (indexes-page contract). */
	function toPageError(e: unknown): { message: string; status: number | undefined } {
		if (e instanceof MaintenanceError) {
			return {
				message: e.status === 403 ? m.platform_maintenance_forbidden() : e.message,
				status: e.status
			};
		}
		return { message: toMessage(e, m.platform_maintenance_load_error()), status: undefined };
	}

	/**
	 * Load the status for the doctype document `docId`; on success commit the
	 * qualified doctype id and fetch its first jobs page. A slow response
	 * never overwrites a newer one.
	 */
	async function loadFor(docId: string) {
		const my = ++statusLoadSeq;
		requestedDoctype = docId;
		statusLoading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			const qualified = await resolveQualifiedDoctype(docId);
			const res = await fetchMaintenanceStatus(qualified);
			if (my !== statusLoadSeq) return;
			status = res;
			doctype = qualified;
			jobs = [];
			jobsMeta = null;
			jobsError = undefined;
			jobsPage = 1;
			void loadJobs();
		} catch (e) {
			if (my !== statusLoadSeq) return;
			status = null;
			doctype = null;
			jobs = [];
			jobsMeta = null;
			const mapped = toPageError(e);
			errorMessage = mapped.message;
			errorStatus = mapped.status;
		} finally {
			if (my === statusLoadSeq) statusLoading = false;
		}
	}

	/** Fetch the job list for the committed doctype. */
	async function loadJobs(opts: { silent?: boolean } = {}) {
		if (!doctype) return;
		const target = doctype;
		const my = ++jobsSeq;
		if (!opts.silent) jobsLoading = true;
		jobsError = undefined;
		try {
			const res = await listMaintenanceJobs(target, { page: jobsPage, items: JOBS_PAGE_SIZE });
			if (my !== jobsSeq || doctype !== target) return;
			jobs = res.data;
			jobsMeta = res.meta;
		} catch (e) {
			if (my !== jobsSeq) return;
			if (e instanceof MaintenanceError) {
				jobsError = e.status === 403 ? m.platform_maintenance_forbidden() : e.message;
			} else {
				jobsError = toMessage(e, m.platform_maintenance_load_error());
			}
		} finally {
			if (my === jobsSeq && !opts.silent) jobsLoading = false;
		}
	}

	/**
	 * Refresh the status counts without touching the page-level error state.
	 * Runs on its own sequence so a poll tick cannot invalidate an in-flight
	 * user load, and writes only while the committed doctype is unchanged —
	 * a stale response for a previous doctype must not overwrite the counts.
	 */
	async function refreshStatusSilent() {
		if (!doctype) return;
		const target = doctype;
		const my = ++statusSilentSeq;
		try {
			const res = await fetchMaintenanceStatus(target);
			if (my !== statusSilentSeq || doctype !== target) return;
			status = res;
		} catch {
			// Keep the last good counts; the next tick or manual refresh retries.
		}
	}

	// Auto-poll while any visible job is pending or running; the interval is
	// cleared when the rows settle, the doctype changes, or the page unmounts.
	$effect(() => {
		const active =
			doctype !== null && jobs.some((row) => row.status === 'pending' || row.status === 'running');
		if (!active) return;
		const id = setInterval(() => {
			void loadJobs({ silent: true });
			void refreshStatusSilent();
		}, POLL_INTERVAL_MS);
		return () => clearInterval(id);
	});

	async function refreshJobs() {
		jobsRefreshing = true;
		try {
			await loadJobs();
			void refreshStatusSilent();
		} finally {
			jobsRefreshing = false;
		}
	}

	/** Enqueue after the panel's confirm dialog resolved true, then reload.
	 *  Concurrent enqueues of the other kind are allowed — the backend
	 *  dedupes per kind. */
	async function enqueue(kind: MaintenanceActionKind) {
		if (!doctype || busyKinds[kind]) return;
		busyKinds = { ...busyKinds, [kind]: true };
		actionError = undefined;
		try {
			if (kind === 'reproject') await enqueueReproject(doctype);
			else await enqueueMigrateAhead(doctype);
			jobsPage = 1;
			await Promise.all([loadJobs(), refreshStatusSilent()]);
		} catch (e) {
			if (e instanceof MaintenanceError) {
				// A 409 names the blocking job kind in the backend message — show it as is.
				actionError = e.message || m.platform_maintenance_enqueue_failed();
			} else {
				actionError = toMessage(e, m.platform_maintenance_enqueue_failed());
			}
		} finally {
			busyKinds = { ...busyKinds, [kind]: false };
		}
	}
</script>

<svelte:head>
	<title>{m.platform_maintenance_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.platform_maintenance_page_header()}
		subtitle={m.platform_maintenance_page_subtitle()}
	/>

	<MaintenancePanel
		{doctype}
		{status}
		{statusLoading}
		{driver}
		recordMeta={doctypeMeta}
		error={errorMessage}
		{errorStatus}
		{jobs}
		{jobsMeta}
		{jobsPage}
		{jobsLoading}
		{jobsRefreshing}
		{jobsError}
		{busyKinds}
		{actionError}
		onPickDoctype={(docId) => void loadFor(docId)}
		onRetry={() => void loadFor(requestedDoctype)}
		onEnqueue={(kind) => void enqueue(kind)}
		onJobsRefresh={() => void refreshJobs()}
		onJobsPageChange={(p) => {
			jobsPage = p;
			void loadJobs();
		}}
	/>
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1280px;
		margin: 0 auto;
	}
</style>
