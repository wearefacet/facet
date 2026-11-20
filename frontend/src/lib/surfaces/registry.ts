// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { Component } from 'svelte';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { DocumentResponse } from '$lib/datasource/types.js';
import type { DoctypeDef } from '$lib/doctype/types.js';
import type { ReferenceClickHandler } from '$lib/template-types';
import SidecarDvtSurface from '$lib/components/features/document-view/SidecarDvtSurface.svelte';

/**
 * General surface registry.
 *
 * Data references a surface **id** (e.g. a sidecar doctype definition's
 * `surface` field); the registry is the single resolve point with a fallback
 * per scope. Custom surfaces always ship with the app bundle (they are
 * code), so an id with no registration means version skew — the fallback
 * keeps older deployments honest without hard-gating imports of bundles
 * authored against a newer platform.
 *
 * The scope is a single prop contract: a sidecar surface renders a scoped
 * collection against a host document. Its consumer is the document show
 * page's sidecar panel.
 */

// ── Sidecar scope ────────────────────────────────────────────────────────────

/**
 * Prop contract for a sidecar surface: a collection of sidecar records
 * scoped to one host document.
 */
export interface SidecarSurfaceProps {
	/** Driver used for all sidecar reads/writes and doctype definition lookups. */
	driver: DataDriver;
	/** Doctype definition of the host document. */
	hostDef: DoctypeDef;
	/** The host document response (its `meta.id` seeds the scoped queries). */
	hostDoc: DocumentResponse;
	/** The host's segment name for this sidecar (e.g. `"comments"`). */
	segment: string;
	/**
	 * Doctype definition of the sidecar doctype, or `null` when the
	 * definition could not be loaded. Surfaces must degrade gracefully.
	 */
	sidecarDef: DoctypeDef | null;
	/**
	 * Called after a local mutation so the panel can refresh tab count
	 * badges. Optional.
	 */
	onchanged?: () => void;
	/**
	 * Reference-chip click handler for the markdown surfaces a sidecar
	 * renders (comment bodies). Wired by the show page to the QuickView
	 * host's `openReference`. Optional — without it readonly chips stay
	 * static.
	 */
	onReferenceClick?: ReferenceClickHandler;
}

const sidecarSurfaces = new Map<string, Component<SidecarSurfaceProps>>();

/**
 * Register a custom sidecar surface for a surface id (e.g. `"comment"`).
 * Ids come from the sidecar doctype definition's `surface` field.
 */
export function registerSidecarSurface(
	id: string,
	component: Component<SidecarSurfaceProps>
): void {
	sidecarSurfaces.set(id, component);
}

/**
 * Resolve a sidecar surface component by id. An absent or unknown id falls
 * back to the basic DVT surface — the "allow basic DVT surface too"
 * guarantee.
 */
export function resolveSidecarSurface(
	id: string | undefined | null
): Component<SidecarSurfaceProps> {
	if (id) {
		const resolved = sidecarSurfaces.get(id);
		if (resolved) return resolved;
		console.warn(
			`sidecar surface '${id}' is not registered — falling back to the basic DVT surface`
		);
	}
	return SidecarDvtSurface as unknown as Component<SidecarSurfaceProps>;
}
