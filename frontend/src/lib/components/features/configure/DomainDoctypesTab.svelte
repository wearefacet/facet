<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { DoctypeRegistry } from '../../schematic/doctypeSchematic.js';
	import {
		createLayoutSaver,
		type SchematicLayoutSource,
		type SchematicPositions
	} from '../../schematic/layout.js';
	import { createHttpSchematicLayoutSource } from '../../schematic/layoutSource.js';
	import DomainSchematic from '../../schematic/DomainSchematic.svelte';
	import DoctypeIcon from '../../primitives/data/DoctypeIcon.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		domain,
		doctypes,
		registry,
		selectedDoctype = $bindable(undefined),
		ondoctypeclick,
		layoutSource = createHttpSchematicLayoutSource()
	}: {
		/** Domain name (e.g. "production") — qualifies row ids and scopes the schematic. */
		domain: string;
		/** The domain's doctype definitions, sorted by name. */
		doctypes: DoctypeDef[];
		/** Schematic registry (the doctype-definition registry, cast for the schematic). */
		registry: DoctypeRegistry;
		/** Qualified id of the selected doctype. Two-way bound: the parent owns
		 *  the state, both the list and the schematic write it back. */
		selectedDoctype?: string | undefined;
		/** Called when a doctype node is picked, with the qualified id
		 *  (e.g. "production.Project"). */
		ondoctypeclick?: (qualified: string) => void;
		/** Where the saved layout lives. Defaults to `core.SchematicLayout`
		 *  over HTTP; stories inject an in-memory source. */
		layoutSource?: SchematicLayoutSource;
	} = $props();

	// ── Layout persistence (schematic.md → Persistence) ───────────────────
	// Load once per domain on mount; save (debounced) after each drag. No
	// live subscription — a reload or re-mount restores the saved layout.
	let storedPositions = $state<SchematicPositions | null>(null);
	/** True when the saved-layout read failed — the computed layout is the
	 *  fallback, and the note chip labels it instead of degrading silently
	 *  (B-383). */
	let layoutReadFailed = $state(false);
	let loadSeq = 0;

	const layoutSaver = createLayoutSaver((d, positions) => layoutSource.save(d, positions));

	$effect(() => {
		const source = layoutSource;
		const d = domain;
		const seq = ++loadSeq;
		layoutSaver.cancel(); // a pending save belongs to the previous domain
		storedPositions = null;
		layoutReadFailed = false;
		source
			.load(d)
			.then((p) => {
				if (seq === loadSeq) storedPositions = p;
			})
			.catch(() => {
				// An unreadable layout is not an error surface — the computed
				// layout is the fallback. The note chip labels the fallback.
				if (seq === loadSeq) {
					storedPositions = null;
					layoutReadFailed = true;
				}
			});
	});
</script>

<div class="arch-layout">
	<div class="dt-list">
		<div class="sh">{m.configure_domains_doctypes_count({ count: doctypes.length })}</div>
		{#each doctypes as dt (dt.doctype)}
			<button
				class="dt-row"
				class:sel={selectedDoctype === `${domain}.${dt.doctype}`}
				onclick={() => {
					selectedDoctype = `${domain}.${dt.doctype}`;
					ondoctypeclick?.(`${domain}.${dt.doctype}`);
				}}
			>
				<DoctypeIcon icon={dt.icon} color={dt.color} active />
				<span class="nm">{dt.doctype}</span>
				{#if dt.aggregate_root}<span class="badge root">{m.configure_domains_root_badge()}</span
					>{/if}
				{#if dt.member_of}<span class="badge child">{m.configure_domains_child_badge()}</span>{/if}
				<span class="sp"></span>
				{#if dt.children.length}
					<span class="cx"
						>{dt.children.length > 1
							? m.configure_domains_children_label({ count: dt.children.length })
							: m.configure_domains_child_label({ count: dt.children.length })}</span
					>
				{/if}
			</button>
		{:else}
			<div class="empty">{m.configure_domains_doctypes_empty()}</div>
		{/each}
	</div>
	<div class="schematic-wrap">
		{#if layoutReadFailed}
			<div class="layout-note">{m.configure_domains_layout_fallback()}</div>
		{/if}
		<DomainSchematic
			{registry}
			{domain}
			{storedPositions}
			onlayoutsave={(p) => layoutSaver.schedule(domain, p)}
			selected={selectedDoctype}
			onnodeclick={(q) => {
				selectedDoctype = q;
				ondoctypeclick?.(q);
			}}
		/>
	</div>
</div>

<style>
	/* ── Doctypes tab ─────────────────────────────────────────────────── */
	.arch-layout {
		display: grid;
		grid-template-columns: 280px 1fr;
		gap: 0;
		height: 100%;
		min-height: 0;
	}
	.dt-list {
		overflow: auto;
		padding: 14px;
		border-right: 1px solid var(--border);
		background: var(--surface);
	}
	.dt-list .sh {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--text-3);
		padding: 4px 6px 10px;
	}
	.dt-row {
		display: flex;
		align-items: center;
		gap: 9px;
		width: 100%;
		text-align: left;
		font: inherit;
		font-size: 13px;
		color: var(--text-2);
		background: none;
		border: 1px solid transparent;
		border-radius: var(--r);
		padding: 8px 10px;
		cursor: pointer;
		transition:
			background 0.1s,
			border-color 0.1s;
	}
	.dt-row:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.dt-row.sel {
		background: var(--accent-weak);
		color: var(--text);
		border-color: var(--accent);
	}
	.dt-row .nm {
		font-weight: 600;
		font-family: var(--font-mono);
		font-size: 12.5px;
	}
	.dt-row .badge {
		font-size: 9.5px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		border-radius: 3px;
		padding: 1px 5px;
	}
	.dt-row .badge.root {
		color: var(--accent-ink);
		background: var(--accent-weak);
	}
	.dt-row .badge.child {
		color: var(--text-3);
		background: var(--sunken);
	}
	.dt-row .sp {
		flex: 1;
	}
	.dt-row .cx {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}
	.dt-list .empty {
		padding: 16px 8px;
		font-size: 12.5px;
		color: var(--text-3);
	}

	.schematic-wrap {
		min-height: 0;
		overflow: hidden;
		position: relative;
		background: radial-gradient(circle at 1px 1px, var(--border) 1px, transparent 0) 0 0 / 20px 20px;
	}

	/* Overlay chip that labels the computed-layout fallback — it never
	   blocks node clicks or shifts the schematic. */
	.layout-note {
		position: absolute;
		top: 12px;
		left: 50%;
		transform: translateX(-50%);
		z-index: 1;
		max-width: calc(100% - 24px);
		font-size: 11.5px;
		color: var(--text-3);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 4px 10px;
		pointer-events: none;
	}

	@media (max-width: 720px) {
		.arch-layout {
			grid-template-columns: 1fr;
		}
		.dt-list {
			border-right: none;
			border-bottom: 1px solid var(--border);
			max-height: 220px;
		}
	}
</style>
