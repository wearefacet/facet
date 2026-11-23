// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Builder draft state bridge.
 *
 * The current draft domain state lives inside the Builder `[draftDomain]`
 * subtree — specifically in `(editor)/+layout.svelte`, which owns the
 * `DomainEditor` instance and the asynchronous domain-doc / check results.
 *
 * The user-facing top bar (`BuilderModeBar`, rendered by the root
 * `+layout.svelte` via `AppShell`) sits OUTSIDE that subtree, on the root
 * layout, because it must persist across Builder/Configure/Live shell
 * switches.
 *
 * These two layers communicate via this store — the same pattern as
 * `navState.svelte.ts` (which bridges live vs draft nav model between the
 * same two layers).
 *
 * The `(editor)/+layout.svelte` writes here whenever the editor's draft
 * state changes (domain doc loaded, issue count updated). The top bar reads
 * here to render its state. The publish dialog's open state is locally
 * owned by the root layout (it must two-way bind with PublishDialog);
 * publish/discard actions on the store are called from there directly.
 */

import {
	publishDraftDomain,
	DomainCheckError,
	type DomainCheckResult,
	type PublishDomainResult,
	type PublishDocumentsSelection
} from '$lib/datasource/domainCheck.js';
import type { PublishReport } from '$lib/components/features/configure/domainGrants.js';
import * as m from '$lib/paraglide/messages';
import { invalidateAll, goto } from '$app/navigation';
import { resolve } from '$app/paths';
import { buildNavModel, domainProjectionToNavDomain } from '$lib/navModel';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { prependDraft, rebuildDraftNav, setDraftNav } from '$lib/navState.svelte';
import {
	domainListCache,
	doctypeRegistryCache,
	documentShowCache
} from '$lib/datasource/clientCache.js';
import { getPermissions } from '$lib/permissions.svelte';
import {
	setPreviewSession,
	clearPreviewSession,
	getPreviewSession
} from '$lib/previewSession.svelte';
import { errorMessage } from '$lib/datasource/bannerError.js';

/**
 * Maps a draft-creation failure to display copy. A 403 means the active
 * role lacks the `create` permission on `core.Domain` — the raw server
 * body is just "Forbidden", so replace it with an actionable message.
 * Other statuses keep the server string, falling back to the status code.
 */
function draftError(res: Response, body: { error?: unknown }, forbidden: string): string {
	if (res.status === 403) return forbidden;
	return (body.error as string) ?? m.builder_draft_failed_status({ status: res.status });
}

/** Snapshot of draft state consumed by BuilderModeBar and PublishDialog. */
interface DraftSnapshot {
	/** Draft domain id (e.g. "_01J…"). Empty string when no draft is active. */
	id: string;
	/** Human-readable name for the chip in the top bar. */
	name: string;
	/** True only when the active domain doc has `draft: true`. */
	isDraft: boolean;
	/** Open issue count from the draft's most recent check. */
	checkIssueCount: number;
	/** Suggested publish-target name for the dialog prefill: the author's
	 *  intended `name` first, then the `source_domain` the draft branched
	 *  from. Empty string for empty drafts (no prefill). */
	publishName: string;
	/** Latest domain check result, shown in the dialog's warnings panel.
	 *  `undefined` for live domains and while the first check is in flight. */
	check?: DomainCheckResult;
}

let snapshot = $state<DraftSnapshot>({
	id: '',
	name: '',
	isDraft: false,
	checkIssueCount: 0,
	publishName: '',
	check: undefined
});

export function getBuilderDraft(): DraftSnapshot {
	return snapshot;
}

/** Reset state when leaving the builder subtree (called from root layout). */
export function clearBuilderDraft(): void {
	snapshot = {
		id: '',
		name: '',
		isDraft: false,
		checkIssueCount: 0,
		publishName: '',
		check: undefined
	};
}

/**
 * Update a subset of the draft snapshot. Called by the `(editor)`
 * layout's reactive bindings.
 */
export function setBuilderDraft(patch: Partial<DraftSnapshot>): void {
	snapshot = { ...snapshot, ...patch };
}

// ── Draft creation ──────────────────────────────────────────────────────────

/** Monotonic count of recorded WS invalidations. `waitForPublishBurst`
 *  compares the count across a settle window to tell a fresh burst event
 *  from a quiet window. */
let wsGeneration = 0;

/** The most recent WS-driven `invalidateAll`. SvelteKit aborts an in-flight
 * navigation when a newer invalidation starts (its router re-commits the
 * current page instead), so draft creation must let the copy's invalidation
 * burst settle before it navigates to the new draft's editor. */
let lastWsInvalidation: Promise<void> | null = null;

/**
 * Records the layout's most recent WS-driven `invalidateAll()` promise, so
 * `createDraft` / `createDraftFromSource` can wait it out before the caller
 * navigates. The invalidation itself stays in the layout — the store keeps
 * no SvelteKit imports on this path. `null` clears the recorded promise.
 */
export function noteWsInvalidation(promise: Promise<void> | null): void {
	if (!promise) {
		lastWsInvalidation = null;
		return;
	}
	wsGeneration += 1;
	lastWsInvalidation = promise;
}

/** Outcome of a draft-creation call. */
export interface CreateDraftResult {
	/** Error message for inline display in the dialog, or `null` on success. */
	error: string | null;
	/** The new draft domain id (e.g. `_01J…`). Set only on success. */
	draftId?: string;
}

/**
 * Lets the copy's WS-driven invalidation burst settle before the caller
 * navigates (see {@link noteWsInvalidation}). A rejected invalidation is
 * swallowed — the settle is an ordering courtesy, not a gate on success.
 */
async function waitForWsInvalidation(): Promise<void> {
	await lastWsInvalidation?.catch(() => {});
}

/** Settle window (ms) between burst events. The publish's WS burst lands
 *  asynchronously — one invalidation per published object — so a short quiet
 *  window, not a single await, tells when the burst has settled. */
const PUBLISH_BURST_SETTLE_MS = 250;

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Waits out the publish's WS invalidation burst before the caller navigates.
 *
 * Each WS event re-records the invalidation with a newer generation, so the
 * burst is a run of newer records that lands asynchronously. The wait watches
 * short windows: await the latest record, then give the next event a window
 * to land. A window that records nothing newer ends the wait — the burst has
 * settled, or never started within the window (the latest record was awaited
 * either way).
 */
async function waitForPublishBurst(): Promise<void> {
	for (;;) {
		const generation = wsGeneration;
		await lastWsInvalidation?.catch(() => {});
		await sleep(PUBLISH_BURST_SETTLE_MS);
		if (wsGeneration === generation) return;
	}
}

/**
 * Create an empty draft domain (`POST /Api/core/Domain/draft`), prepend it
 * to the sidebar, and rebuild the draft nav model.
 *
 * The rebuild drops the cached pre-creation snapshots first (inside
 * `rebuildDraftNav`) so the sidebar sees the new draft and its copied
 * doctypes instead of stale 60s-TTL entries, then fetches without waiting —
 * the same fire-and-forget the layout used before the extraction. The
 * caller navigates to `/Builder/{draftId}/overview` after this resolves.
 */
export async function createDraft(input: {
	name: string;
	label?: string;
}): Promise<CreateDraftResult> {
	try {
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch('/Api/core/Domain/draft', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ name: input.name, label: input.label || undefined })
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return { error: draftError(res, body, m.builder_create_domain_forbidden()) };
		}
		const newDraft = await res.json();
		const draftDomainNav = domainProjectionToNavDomain(newDraft);
		prependDraft(draftDomainNav);
		rebuildDraftNav();
		await waitForWsInvalidation();
		return { error: null, draftId: draftDomainNav.id };
	} catch {
		return { error: m.builder_draft_network_error() };
	}
}

/**
 * Create a draft by copying an existing published domain
 * (`POST /Api/core/Domain/{sourceId}/draft`). Same install flow as
 * {@link createDraft}: prepend + fire-and-forget rebuild + WS-invalidation
 * settle. The caller navigates to the new draft's editor.
 */
export async function createDraftFromSource(sourceId: string): Promise<CreateDraftResult> {
	try {
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/Domain/${sourceId}/draft`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: '{}'
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return { error: draftError(res, body, m.builder_edit_domain_forbidden()) };
		}
		const newDraft = await res.json();
		const draftDomainNav = domainProjectionToNavDomain(newDraft);
		prependDraft(draftDomainNav);
		rebuildDraftNav();
		// The copy fires a `registered` event per doctype; each event runs the
		// layout's WS handler, which calls `invalidateAll()`. Those invalidations
		// must settle before the goto, or they abort it (the URL would stay
		// on the landing page with the draft created). Same order as
		// `createDoctype` below.
		await waitForWsInvalidation();
		return { error: null, draftId: draftDomainNav.id };
	} catch {
		return { error: m.builder_draft_network_error() };
	}
}

/**
 * Discard the active draft. Calls the drop endpoint — the generic document
 * `DELETE /Api/core/Domain/:id` is refused server-side (a lone Domain
 * tombstone would orphan the draft's definitions and data). On success,
 * returns to the builder landing. The store owns navigation so the action
 * is the same from any caller.
 *
 * Returns a string error message on failure (matching the
 * `onnewdomain`-style error contract on AppShell).
 */
export async function discardDraft(): Promise<string | null> {
	if (!snapshot.id) return m.builder_no_active_draft();
	const draftId = encodeURIComponent(snapshot.id);
	try {
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/Domain/${draftId}/drop`, { method: 'POST' });
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return body.error ?? m.builder_draft_failed_status({ status: res.status });
		}
		// The domain list, the nav model, and the cached `show()` all still
		// hold the discarded draft — drop them before navigating so neither
		// the sidebar nor the landing pages resurrect it within the TTL.
		domainListCache.invalidate();
		documentShowCache.invalidate(`/Api/core/Domain/${draftId}`);
		await goto(resolve('/Builder'));
		await invalidateAll();
		return null;
	} catch (err) {
		return errorMessage(err);
	}
}

/**
 * Outcome of a publish attempt.
 *
 * - `published`: the publish landed. `report` carries the grant-ticket
 *   report when tickets were filed or merged (the caller keeps the dialog
 *   open on it), or `null` when the store already routed back to `/Builder`.
 * - `conflict`: HTTP 409 — the target name is already in use. The caller may
 *   confirm with the user and retry with `overwrite: true`; the store never
 *   retries on its own.
 * - `error`: any other failure (network, version gate, …).
 */
export type PublishOutcome =
	| { status: 'published'; report: PublishReport | null }
	| { status: 'conflict'; message: string }
	| { status: 'error'; message: string };

/**
 * Publish the active draft under a chosen name. Mirrors the editor's
 * legacy `handlePublish` so the top bar can drive the same flow.
 *
 * When `overwrite` is true and the target domain already exists, the
 * backend runs the version gate (structure changes require
 * `schema_version = live + 1` and a migration entry).
 *
 * `documents` carries the draft's selected doctype rows into the target.
 * The caller owns the selection; the backend refuses a doctype the target
 * already defines.
 */
export async function publishDraft(
	targetName: string,
	overwrite = false,
	documents?: PublishDocumentsSelection
): Promise<PublishOutcome> {
	if (!snapshot.id) return { status: 'error', message: m.builder_no_active_draft() };
	try {
		const result: PublishDomainResult = await publishDraftDomain(
			snapshot.id,
			targetName,
			overwrite,
			undefined,
			documents
		);
		// The publish turned the draft into a live domain. The domain list and
		// the doctype registry caches still hold the pre-publish state — drop
		// them here, on both return paths, so the drafts list, the sidebar,
		// and the published list re-fetch. WS delivery can lose events, so
		// local freshness must not wait for the burst.
		domainListCache.invalidate();
		doctypeRegistryCache.invalidate();
		if (result.grant_tickets.length > 0) {
			return {
				status: 'published',
				report: { domain: result.domain, grant_tickets: result.grant_tickets }
			};
		}
		// Publish fires a burst of WS events (the domain document, every
		// re-registered doctype, filed grants). Each event runs the layout's
		// WS handler, which records a fresh invalidation here. The burst lands
		// after the POST resolves, so the record taken earlier does not cover
		// it — a newer invalidation would abort the goto and strand the
		// editor on the dead draft URL. Wait the burst out, then navigate.
		await waitForPublishBurst();
		// The draft URL is dead now. The live domain view cannot render yet —
		// its load resolves the name from the parent nav model, which catches
		// up only when the burst's invalidations re-run the layout load. Land
		// on the builder overview instead.
		await goto(resolve('/Builder'));
		// Re-run the load functions so the builder landing shows the
		// post-publish state — the same local catch-up as `discardDraft`.
		await invalidateAll();
		return { status: 'published', report: null };
	} catch (err) {
		// A 409 means the target name is already in use. The store never
		// retries on its own: the conflict is a distinct outcome, and the
		// caller decides whether to publish again with `overwrite`.
		if (err instanceof DomainCheckError && err.status === 409) {
			return { status: 'conflict', message: errorMessage(err) };
		}
		return { status: 'error', message: errorMessage(err) };
	}
}

/**
 * Start a preview session for the active draft.
 *
 * Issues a `typ: "preview"` capability token via
 * `POST /Api/core/Domain/:id/preview-session` (gated on the caller's real
 * role's `create core.DocType` permission), stages the token in the
 * `previewSession` store so `apiFetch` injects it into every subsequent
 * request, mirrors it into the `facet.preview-session` cookie so a full
 * reload of `/_abc` survives F5, and navigates the browser to the draft's
 * **live URL** (`/_abc`).
 *
 * The root `+layout.ts` deliberately reads no `url`/`params` (so tab
 * switches stay flicker-free), so it does **not** re-run on the client-side
 * `goto`. Instead, the draft surfaces in the live UI through three seams,
 * all gated on `isPreviewActive()`:
 *
 *   1. `buildNavModel` keeps the bound draft visible via its preview carve-out
 *      even when called with `drafts: false` (the live default).
 *   2. The sidebar rebuild effect in `routes/+layout.svelte` re-runs (because
 *      it reads `isPreviewActive()`) and rebuilds the live nav model without
 *      the real-user permission manifest, so draft doctypes stay visible.
 *   3. `routes/[domain=notApi]/+page.ts` falls back to a direct
 *      `core.Domain` fetch for `_`-prefixed params when the parent nav model
 *      has not yet caught up, so the dashboard renders against draft data.
 *
 * On a full reload (F5), the preview token is restored from the cookie by
 * `hooks.server.ts`, which attaches it to `event.locals.previewSession`;
 * `+layout.server.ts` forwards it to `+layout.ts`, which re-injects it via
 * `setPreviewSession` before any SSR `apiFetch` call.
 *
 * Returns a string error message on failure (for inline display in the
 * BuilderModeBar / a dialog), or `null` on success.
 */
export async function startPreview(draftIdOverride?: string): Promise<string | null> {
	const draftId = draftIdOverride ?? snapshot.id;
	if (!draftId) return m.builder_no_active_draft();
	try {
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/Domain/${draftId}/preview-session`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: '{}'
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return body.error ?? m.builder_draft_failed_status({ status: res.status });
		}
		const body = (await res.json()) as {
			data: { token: string; preview_domain: string; expires_at: number };
		};
		setPreviewSession({
			draftId: body.data.preview_domain,
			token: body.data.token,
			expiresAt: body.data.expires_at
		});
		// Navigate to the draft's live URL. The root `+layout.ts` deliberately
		// reads no `url`/`params` so it does NOT re-run on this client-side
		// navigation; the draft surfaces through the preview carve-out (see the
		// function doc) instead of a layout re-load.
		await goto(resolve('/[domain=notApi]', { domain: draftId }));
		return null;
	} catch (err) {
		return errorMessage(err);
	}
}

/**
 * End the active preview session and return to the Builder editor for the
 * draft. Drops the in-memory and `sessionStorage` preview state so subsequent
 * `apiFetch` calls revert to the cookie-based access token.
 */
export async function endPreview(): Promise<void> {
	const draftId = getPreviewSession()?.draftId;
	clearPreviewSession();
	if (draftId) {
		await goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: draftId }));
	} else {
		await goto(resolve('/Builder'));
	}
}

/**
 * Create a doctype inside the active draft.
 *
 * Posts a minimal `core.DocType` definition (`{domain, doctype, fields: {}}`)
 * to the parent's nested child-create route:
 * `POST /Api/core/Domain/{draftId}/doctypes`. `core.DocType` declares
 * `member_of: Domain` and the `doctypes` relation on `core.Domain`, so the
 * top-level `POST /Api/core/DocType` is rejected by the backend with
 * "create it through the parent's nested route". The nested route also
 * sets `meta.parent_id` to the draft domain id automatically.
 *
 * The draft-mode validator on the backend accepts an empty field set; the
 * field editor (where the user adds fields) is opened afterwards via
 * `/Builder/{draft}/{doctype}/fields`.
 *
 * The Draft's sidebar doctype list is rebuilt from a fresh nav model so
 * the new doctype appears without a manual refresh. The root layout's
 * WebSocket handler doesn't cover this path: it subscribes only to the
 * doctypes that existed at builder-mount time, so a freshly-created
 * doctype wouldn't trigger its own refresh.
 *
 * Returns a string error message on failure (for inline display in the
 * dialog), or `null` on success.
 */
export async function createDoctype(doctypeName: string): Promise<string | null> {
	if (!snapshot.id) return m.builder_no_active_draft();
	try {
		const { apiFetch } = await import('$lib/session.svelte');
		// New doctypes start as aggregate roots — the backend Check warns on a
		// standalone doctype that declares neither `aggregate_root` nor
		// `member_of` (the struct default is `false`). A child doctype is
		// created through the parent's children map, which sets `member_of`.
		const definition = {
			domain: snapshot.id,
			doctype: doctypeName,
			aggregate_root: true,
			fields: {} as Record<string, unknown>
		};
		const res = await apiFetch(`/Api/core/Domain/${snapshot.id}/doctypes`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(definition)
		});
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return body.error ?? m.builder_draft_failed_status({ status: res.status });
		}
		// Refresh the draft nav model so the sidebar list includes the new
		// doctype. Done before navigation so the list is correct by the time
		// the editor mounts under the new URL.
		await invalidateAll();
		const driver = new DocumentDataDriver('');
		const model = await buildNavModel(driver, getPermissions() ?? undefined, { drafts: true });
		setDraftNav(model);
		await goto(
			resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
				draftDomain: snapshot.id,
				doctype: doctypeName,
				tab: 'fields'
			})
		);
		return null;
	} catch (err) {
		return errorMessage(err);
	}
}
