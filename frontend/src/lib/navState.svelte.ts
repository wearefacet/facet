// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Shared sidebar navigation state.
 *
 * The root layout owns the `AppShell`, which renders `NavPanel`. When the user
 * enters the `/Builder` subtree, the sidebar must switch from live domains to
 * draft domains. Because `NavPanel` lives in the root layout and the draft
 * data is fetched client-side, a module-level store bridges the two.
 *
 * The module owns HOW the nav model is built: the rebuild helpers below fetch
 * through `buildNavModel` and install the result. The root layout keeps only
 * WHEN they run (auth, settings readiness, route mode, preview carve-out).
 *
 * Mirrors the pattern of `permissions.svelte.ts`, `theme.svelte.ts`:
 * module-level `$state`, getter/setter functions, no `setContext`.
 */

import type { NavDomain } from '$lib/navTypes';
import { buildNavModel, type PermissionManifest } from '$lib/navModel';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { domainListCache, doctypeRegistryCache } from '$lib/datasource/clientCache.js';
import { getPermissions } from '$lib/permissions.svelte';

let domains = $state<NavDomain[]>([]);
let isDraft = $state(false);
/** Live domains cached for the EditDomainDialog (draft-from-live flow). */
let liveDomains = $state<NavDomain[]>([]);

export function getNavDomains(): NavDomain[] {
	return domains;
}

/** Resolve a domain id to its display label, falling back to the id itself. */
export function getDomainLabel(id: string): string {
	return domains.find((d) => d.id === id)?.label ?? id;
}

export function getNavIsDraft(): boolean {
	return isDraft;
}

export function getNavLiveDomains(): NavDomain[] {
	return liveDomains;
}

export function setLiveNav(model: NavDomain[]): void {
	isDraft = false;
	domains = model;
}

export function setDraftNav(model: NavDomain[]): void {
	isDraft = true;
	domains = model;
}

export function setNavLiveDomains(model: NavDomain[]): void {
	liveDomains = model;
}

/** Prepend a freshly-created draft domain and switch the sidebar to drafts. */
export function prependDraft(draft: NavDomain): void {
	isDraft = true;
	// The draft creation races its own server-side events: the copy fires a
	// `registered` event per doctype over the WebSocket, and every event
	// rebuilds this nav. One of those rebuilds can land the draft before the
	// POST response does — prepending over it must not keep two rows with the
	// same id, or the keyed `{#each}` in the sidebar throws
	// `each_key_duplicate` and kills the navigation in flight.
	domains = [draft, ...domains.filter((d) => d.id !== draft.id)];
}

// ── Nav model rebuilds ──────────────────────────────────────────────────────

/** Options for {@link rebuildLiveNav}. */
export interface RebuildLiveNavOptions {
	/** Permission manifest passed straight to `buildNavModel`. `undefined`
	 *  mirrors the universal manifest — every visible doctype shows. */
	permissions?: PermissionManifest;
	/** Qualified doctype names the user pinned; marked in the Pinned section. */
	pinnedDoctypes?: string[];
}

/**
 * Rebuilds and installs the live-domain nav model. Used by the layout's
 * settings-gated build effect and the pin toggle.
 *
 * Fails soft: when the fetch rejects, the current model stays installed.
 */
export async function rebuildLiveNav(opts: RebuildLiveNavOptions): Promise<void> {
	try {
		const driver = new DocumentDataDriver('');
		const model = await buildNavModel(driver, opts.permissions, {
			pinnedDoctypes: opts.pinnedDoctypes
		});
		setLiveNav(model);
	} catch {
		/* nav rebuild failed — keep current model */
	}
}

/**
 * Installs the live-domain model straight from the layout load's data — the
 * SSR build result, with no client-side fetch.
 */
export function setLiveFromLoad(domains: NavDomain[]): void {
	setLiveNav(domains);
}

/**
 * Rebuilds and installs the draft-domain nav model after a model mutation
 * (a WS collection event, a draft creation).
 *
 * Collection messages are hints, not source of truth: the model is rebuilt
 * from the server, never from the event payload. The registry and domain
 * caches drop first — a rebuild served from a stale 60s-TTL entry returns
 * the pre-mutation model and the navbar never changes.
 *
 * Fails soft: when the fetch rejects, the current model stays installed.
 */
export async function rebuildDraftNav(): Promise<void> {
	// Drop the cached pre-mutation snapshots so the rebuild below re-fetches
	// the domain list and the doctype registry instead of serving stale
	// 60s-TTL entries taken before the change landed.
	doctypeRegistryCache.invalidate();
	domainListCache.invalidate();
	try {
		const driver = new DocumentDataDriver('');
		const model = await buildNavModel(driver, getPermissions() ?? undefined, { drafts: true });
		setDraftNav(model);
	} catch {
		/* draft fetch failed — keep current model */
	}
}

/**
 * Rebuilds and installs the live-domain nav model during an active preview
 * session, after a model mutation (a WS collection event from the builder
 * assistant or a second tab editing the same draft).
 *
 * Mirrors {@link rebuildDraftNav}: both caches drop first, then the model is
 * rebuilt from the server. The permission manifest is deliberately omitted —
 * the real-user manifest would filter the draft's doctypes out of the sidebar
 * (the same carve-out the layout's preview rebuild applies); the backend's
 * `PreviewEnforcer` is the authority on what the preview principal may read.
 *
 * The rebuild reads the preview carve-out in `buildNavModel`
 * (`getPreviewSession()`), so it must run while the session is still active —
 * callers guard on `isPreviewActive()`.
 *
 * Fails soft: when the fetch rejects, the current model stays installed.
 */
export async function rebuildPreviewNav(pinnedDoctypes?: string[]): Promise<void> {
	doctypeRegistryCache.invalidate();
	domainListCache.invalidate();
	try {
		const driver = new DocumentDataDriver('');
		const model = await buildNavModel(driver, undefined, { pinnedDoctypes });
		setLiveNav(model);
	} catch {
		/* preview rebuild failed — keep current model */
	}
}

/**
 * Fetches the builder-entry pair and installs both: the draft model for the
 * sidebar and the live-domain model for the EditDomainDialog. The two
 * fetches run concurrently and serve from the client caches like any route
 * load — no invalidation (that is {@link rebuildDraftNav}'s job).
 *
 * Each fetch fails soft and independently: a failed draft fetch keeps the
 * current draft model, a failed live fetch keeps the current dialog list.
 */
export function loadBuilderEntryNav(): void {
	const driver = new DocumentDataDriver('');
	buildNavModel(driver, getPermissions() ?? undefined, { drafts: true })
		.then((model) => {
			setDraftNav(model);
		})
		.catch(() => {
			/* draft fetch failed — keep current model */
		});

	// Also fetch live domains for the EditDomainDialog.
	buildNavModel(driver, getPermissions() ?? undefined, { drafts: false })
		.then((model) => {
			setNavLiveDomains(model);
		})
		.catch(() => {
			/* live fetch failed — keep empty */
		});
}
