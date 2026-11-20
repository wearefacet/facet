<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	// Registers the built-in sidecar surfaces (comment, attachment). The
	// panel pulls in the sidecar feature module at load so definitions
	// carrying a registered `surface` id always resolve when the panel mounts.
	import '$lib/components/features/sidecar/surfaces.js';
	import { untrack } from 'svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import {
		humanize,
		parseDoctypeDef,
		type DoctypeDef,
		type SidecarDef
	} from '$lib/doctype/types.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { resolveSidecarSurface } from '$lib/surfaces/registry.js';
	import type { ReferenceClickHandler } from '$lib/template-types';
	import Tabs from '$lib/components/primitives/navigation/Tabs.svelte';
	import { SvelteSet } from 'svelte/reactivity';

	/**
	 * SidecarPanel — the inner sidecar rail content for the document show
	 * page. Renders the active sidecar surface (tab strip when two or more
	 * sidecars are wired, surface directly with a single entry, nothing
	 * without any). The show route owns the two-column layout and rail
	 * chrome (width, border, scroll); this component stays chrome-free
	 * apart from the top divider.
	 */
	let {
		driver,
		def,
		doc,
		onReferenceClick
	}: {
		driver: DataDriver;
		def: DoctypeDef;
		doc: DocumentResponse;
		/** Reference-chip click handler passed through to the surfaces
		 *  (comment bodies open the QuickView drawer when wired). */
		onReferenceClick?: ReferenceClickHandler;
	} = $props();

	// Parsed `sidecars` arrays are pre-sorted by `{order, key}` — that is the
	// tab order; no client-side re-sort.
	const entries = $derived(def.sidecars ?? []);

	let active = $state(0);
	// Sidecar doctype definitions keyed by segment. `undefined` = not yet
	// resolved, `null` = resolution failed (surfaces must degrade).
	let sidecarDefs = $state<Record<string, DoctypeDef | null>>({});
	// Count badges keyed by segment; `undefined` = not fetched, `null` = failed.
	let counts = $state<Record<string, number | null>>({});
	// Start guards for the mount effects below. Reads and writes stay inside
	// `untrack`: a tracked read followed by the `add` write would re-run this
	// very effect and cancel the in-flight work (see workflow.md →
	// "The equality-guard trap in writeback effects"; verified with a runtime
	// probe against Svelte 5.56).
	const defsStarted = new SvelteSet<string>();
	const countsStarted = new SvelteSet<string>();

	async function resolveDef(entry: SidecarDef): Promise<void> {
		let parsed: DoctypeDef | null = null;
		try {
			const md = driver as unknown as {
				doctypeDefinitions?: Map<string, Record<string, unknown>>;
			};
			if (md.doctypeDefinitions instanceof Map) {
				const raw = md.doctypeDefinitions.get(entry.doctype);
				if (raw) parsed = parseDoctypeDef(raw);
			} else {
				const reg = await DoctypeRegistry.cached(driver);
				const raw = reg.doctypeDefinitions.get(entry.doctype);
				if (raw) parsed = parseDoctypeDef(raw);
			}
		} catch {
			parsed = null;
		}
		sidecarDefs[entry.key] = parsed;
	}

	async function refreshCount(entry: SidecarDef): Promise<void> {
		try {
			const res = await driver
				.domain(def.domain)
				.doctype(def.doctype)
				.doc(doc.meta.id)
				.sidecars(entry.key)
				.list({ aggregate: 'count' });
			counts[entry.key] = res.meta.count;
		} catch {
			counts[entry.key] = null;
		}
	}

	function handleChanged(entry: SidecarDef): void {
		// A single entry has no tab strip → no badge to refresh.
		if (entries.length >= 2) void refreshCount(entry);
	}

	$effect(() => {
		void entries;
		for (const entry of entries) {
			if (untrack(() => defsStarted.has(entry.key))) continue;
			untrack(() => defsStarted.add(entry.key));
			void resolveDef(entry);
		}
	});

	$effect(() => {
		if (entries.length < 2) return;
		for (const entry of entries) {
			if (untrack(() => countsStarted.has(entry.key))) continue;
			untrack(() => countsStarted.add(entry.key));
			void refreshCount(entry);
		}
	});

	const tabs = $derived(
		entries.map((entry) => ({
			label: entry.label ?? humanize(entry.key),
			count: counts[entry.key] ?? undefined
		}))
	);
</script>

{#if entries.length > 0}
	<div class="sidecar-panel" data-sidecar-panel>
		{#if entries.length > 1}
			<Tabs {tabs} bind:active />
		{/if}
		{#each entries as entry, i (entry.key)}
			{#if entries.length === 1 || i === active}
				{@const sidecarDef = sidecarDefs[entry.key]}
				{@const Surface = resolveSidecarSurface(sidecarDef?.surface ?? null)}
				<div class="sidecar-surface">
					<Surface
						{driver}
						hostDef={def}
						hostDoc={doc}
						segment={entry.key}
						{sidecarDef}
						onchanged={() => handleChanged(entry)}
						{onReferenceClick}
					/>
				</div>
			{/if}
		{/each}
	</div>
{/if}

<style>
	/* Chrome-free inner content — the show route draws the rail box. The top
	 * divider is the only surface this component contributes. */
	.sidecar-panel {
		border-top: 1px solid var(--border);
		padding: 8px 0 4px;
	}

	.sidecar-surface {
		padding: 0 4px;
	}
</style>
