<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	Table renderer for `view: 'table'` relation nodes, with the hydration pass
	for dotted column keys. Extracted from `DvtRelation.svelte`, which owns the
	row list and the row fetch; this component owns the hydrated maps and
	fetches each referenced document once per (qualified, id) pair — two rows
	sharing a reference cost one fetch.

	A column key is either a plain field on the row (`role`), a dotted path
	crossing one or more `reference` fields (`contact.email`), or a leaf
	`reference` field itself (`contact`) — that cell renders the target
	document as a hydrated `Capsule`, the same component `DvtField` uses for
	`$field` references. The node's `columns` list normalizes once at the
	boundary (`normalizeRelationColumns`), so a malformed stored template
	degrades to a working table. Cell resolution is the pure matrix in
	`lib/doctype/relationColumns.ts`; unresolved cells render the DVT em-dash
	blank via `DvtValue`.
-->

<script lang="ts">
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { RelationNode, ReferenceClickHandler } from '$lib/template-types.js';
	import {
		fieldDefFor,
		leafReferenceColumn,
		normalizeRelationColumns
	} from '$lib/template-resolve.js';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
	import { untrack } from 'svelte';
	import { SvelteMap, SvelteSet } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';
	import DvtValue from './DvtValue.svelte';
	import {
		columnRefTargets,
		parseColumnKey,
		parseReferenceId,
		refKey,
		resolveColumnCell,
		rowCapsuleReference,
		splitRefKey,
		tableNeedsHydration,
		toggleTarget,
		type RelationRow
	} from '$lib/doctype/relationColumns.js';

	let {
		rows,
		template,
		viewMode,
		parentId,
		driver,
		relationDef,
		onreferenceclick,
		ontoggle,
		togglePending
	}: {
		/** The loaded relation rows. */
		rows: RelationRow[];
		/** The relation template node — owns the column list. */
		template: RelationNode;
		/** Render mode — the table renders only for `view: 'table'`. */
		viewMode: string;
		/** The bound parent document's qualified id — resets the hydration
		 *  caches when it changes. */
		parentId: string;
		/** Driver used to fetch the referenced documents and doctype definitions. */
		driver?: DataDriver;
		/** The relation doctype's definition — types local-column cells and
		 *  names the first-hop reference fields. */
		relationDef: DoctypeDef | undefined;
		/** Click handler forwarded to clickable rows. */
		onreferenceclick?: ReferenceClickHandler;
		/** Inline boolean toggle for a row. Supplied only when the viewer holds
		 *  `update` on the relation doctype and the surface is read-only — the
		 *  parent owns the optimistic rows patch and the mutation. */
		ontoggle?: (row: RelationRow, key: string, next: boolean) => void;
		/** `rowId:colKey` stamps with an in-flight toggle — disables the button. */
		togglePending?: Set<string>;
	} = $props();

	// ── Hydration ────────────────────────────────────────────────────────────
	//
	// Each non-leaf segment of a column key resolves to a reference id on the
	// doctype reached so far; the target document is fetched on demand and
	// cached below. Bounded total by the relation's `limit`.

	/** Resolved reference documents keyed by `<qualifiedTarget>` + REF_KEY_SEP + `<refId>`. Filled
	 *  by `loadTableRefs` once the rows land. The leaf value is rendered
	 *  against the target doctype's `FieldDef` so typed cells (enum/phone/etc.)
	 *  match the show-page rendering. */
	let tableDocs = $state<Map<string, DocumentResponse>>(new Map());
	let tableDefs = $state<Map<string, DoctypeDef>>(new Map());
	let tableSeq = 0;

	/** Normalized column list — the single render boundary for the node's
	 *  `columns`. A malformed stored template (bare string columns, missing
	 *  keys) coerces or drops here, so headers, cells, hydration targets and
	 *  the toggle check all read well-formed columns with unique each-keys
	 *  instead of crashing (see `normalizeRelationColumns`). */
	const columns = $derived(normalizeRelationColumns(template.columns));

	/** Reference doctypes reached by any column key (e.g. `['crm.Contact']`). */
	const tableTargets = $derived(columnRefTargets({ columns }, relationDef));

	/** Whether the table view crosses any reference field (triggers hydration). */
	const needsHydration = $derived(tableNeedsHydration({ columns }, viewMode));

	async function loadTableDefs() {
		if (!driver) return;
		const md = driver as unknown as {
			doctypeDefinitions?: Map<string, Record<string, unknown>>;
		};
		for (const target of tableTargets) {
			if (tableDefs.has(target)) continue;
			let raw: Record<string, unknown> | undefined;
			if (md.doctypeDefinitions instanceof Map) {
				raw = md.doctypeDefinitions.get(target);
			} else {
				const reg = await DoctypeRegistry.cached(driver);
				raw = reg.doctypeDefinitions.get(target);
			}
			if (raw) tableDefs.set(target, parseDoctypeDef(raw));
		}
	}

	async function loadTableRefs(rowsList: RelationRow[]) {
		if (!driver || !needsHydration) return;
		const my = ++tableSeq;
		await loadTableDefs();
		if (my !== tableSeq) return;
		// Collect unique (qualified, id) pairs to resolve — dedup across rows,
		// so two memberships pointing at the same contact cost one fetch.
		// untrack: this runs inside the hydration `$effect` — a tracked read on
		// `toFetch` followed by its own `add` writes, or on `next` before the
		// awaited `set` writes land, would re-run the effect and orphan the
		// fetches (workflow.md → "The equality-guard trap in writeback effects").
		const toFetch = untrack(() => {
			const set = new SvelteSet<string>();
			for (const row of rowsList) {
				for (const col of columns) {
					const parts = parseColumnKey(col.key);
					if (parts.length < 2) continue;
					const seg = parts[0];
					const refField = relationDef ? fieldDefFor(relationDef, seg) : null;
					if (!refField || refField.type !== 'reference' || !refField.doctype) continue;
					const refId = row.data?.[seg];
					if (typeof refId !== 'string' || refId === '') continue;
					set.add(refKey(refField.doctype, refId));
				}
			}
			return set;
		});
		const next = untrack(() => new SvelteMap(tableDocs));
		for (const key of toFetch) {
			if (untrack(() => next.has(key))) continue;
			const split = splitRefKey(key);
			if (!split) continue;
			const dot = split.qualified.indexOf('.');
			if (dot < 1) continue;
			const domain = split.qualified.slice(0, dot);
			const doctype = split.qualified.slice(dot + 1);
			if (!doctype) continue;
			try {
				const doc = await driver.domain(domain).doctype(doctype).doc(split.id).show();
				if (my !== tableSeq) return;
				untrack(() => next.set(key, doc));
			} catch {
				// Best-effort — a missing/inaccessible reference renders as blank.
			}
		}
		if (my !== tableSeq) return;
		tableDocs = next;
	}

	let prevParentId: string | undefined;

	// Hydrate reference-documents once the rows land; skip entirely when no
	// column key crosses a reference field.
	$effect(() => {
		const currentRows = rows;
		// Drop the hydration caches so a different parent's rows do not show
		// stale resolved-reference documents.
		if (prevParentId !== parentId) {
			prevParentId = parentId;
			tableDocs = new Map();
			tableDefs = new SvelteMap();
		}
		if (!currentRows || !needsHydration) return;
		void loadTableRefs(currentRows);
	});

	/**
	 * Convert a reference id (`"<domain>.<Doctype>.<id>"` or bare) into a
	 * `ReferenceClickEvent` and forward it to the host. Used by the table-row
	 * click affordance, mirroring what `Capsule` does for capsule mode.
	 */
	function fireReferenceClick(refId: string): void {
		if (!onreferenceclick) return;
		const parsed = parseReferenceId(refId);
		if (!parsed) return;
		onreferenceclick(parsed);
	}
</script>

{#if viewMode === 'table'}
	<!-- The wrapper owns horizontal overflow: nowrap cells make an auto
	     table-layout table wider than its container once the sum of
	     column minimums exceeds the pane. Scrolling here keeps the
	     show page's document column free of a horizontal scrollbar. -->
	<div class="dvt-relation-table-wrap">
		<table class="dvt-relation-table">
			<thead>
				<tr>
					{#each columns as col (col.key)}
						<!-- A stored column can carry no label (the validator
						     requires only the key) — fall back to the key, as
						     the schema-aware table does for its toggle label. -->
						<th class="dvt-relation-th" style:width={col.width}>{col.label ?? col.key}</th>
					{/each}
				</tr>
			</thead>
			<tbody>
				{#each rows as row (row.meta.id)}
					{@const ref = template.referenceField
						? rowCapsuleReference(row, template.referenceField)
						: undefined}
					<tr
						class="dvt-relation-tr"
						role={ref ? 'button' : undefined}
						tabindex={ref ? 0 : undefined}
						onclick={ref && onreferenceclick ? () => fireReferenceClick(ref) : undefined}
						onkeydown={ref && onreferenceclick
							? (e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										fireReferenceClick(ref);
									}
								}
							: undefined}
					>
						{#each columns as col (col.key)}
							{@const cell = resolveColumnCell(row, col.key, tableDocs, tableDefs, relationDef)}
							{@const leafRef = leafReferenceColumn(col.key, relationDef)}
							{@const tgl = ontoggle ? toggleTarget(col, relationDef) : null}
							<td class="dvt-relation-td">
								{#if leafRef && driver}
									<!-- Leaf reference column: the cell renders the target
									     document as a hydrated Capsule — the same component
									     `DvtField` uses for `$field` references. The Capsule
									     owns the label fetch; a click fires the reference
									     handler with the target's parts. -->
									{@const refId = row.data?.[col.key]}
									{#if typeof refId === 'string' && refId !== ''}
										<Capsule
											{driver}
											reference={refId}
											qualifiedDoctype={leafRef.doctype}
											{onreferenceclick}
										/>
									{:else}
										<DvtValue value={undefined} fieldType={null} />
									{/if}
								{:else if tgl}
									{@const stamp = `${row.meta.id}:${col.key}`}
									{@const toggleField = col.label ?? col.key}
									<button
										type="button"
										class="dvt-relation-bool"
										class:on={cell.value === true}
										aria-pressed={cell.value === true}
										aria-label={m.table_bool_toggle_aria({ field: toggleField })}
										title={m.table_bool_toggle_aria({ field: toggleField })}
										disabled={togglePending?.has(stamp) ?? false}
										onclick={(e) => {
											// Never open the row's reference click from a cell toggle.
											e.stopPropagation();
											ontoggle?.(row, col.key, cell.value !== true);
										}}
										onkeydown={(e) => {
											// Enter/Space on the toggle must not bubble into the row's
											// reference-open keydown handler.
											e.stopPropagation();
										}}
									>
										{cell.value === true ? '✓' : '✕'}
									</button>
								{:else}

									<DvtValue

										value={cell.value}

										fieldType={cell.fieldType as never}

										fieldDef={cell.fieldDef}

										{driver}
										{onreferenceclick}
									/>
								{/if}
							</td>
						{/each}
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}

<style>
	/* Wide tables scroll inside this wrapper — never widen the document
	   container. `min-width: 0` lets the wrapper shrink inside flex/grid
	   ancestors. */
	.dvt-relation-table-wrap {
		overflow-x: auto;
		min-width: 0;
	}

	.dvt-relation-table {
		width: 100%;
		border-collapse: collapse;
		font-size: 13px;
	}

	.dvt-relation-th {
		padding: 6px 10px;
		text-align: left;
		font-weight: 600;
		font-size: 11.5px;
		color: var(--text-2);
		border-bottom: 1px solid var(--border-strong);
		background: var(--sunken);
		white-space: nowrap;
	}

	.dvt-relation-tr {
		cursor: pointer;
		border-bottom: 1px solid var(--border);
		transition: background 0.1s;
	}

	.dvt-relation-tr:hover {
		background: var(--accent-weak);
	}

	.dvt-relation-tr:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}

	.dvt-relation-td {
		padding: 7px 10px;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		max-width: 320px;
	}

	/* Inline boolean toggle — same marks as the schema-aware table's cells:
	   green on, red off. Read-only cells keep the DvtValue rendering. */
	.dvt-relation-bool {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		border-radius: var(--r-sm);
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 600;
		line-height: 1;
		color: var(--danger);
		background: var(--danger-weak);
		border: none;
		padding: 0;
		cursor: pointer;
	}

	.dvt-relation-bool.on {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.dvt-relation-bool:hover:not(:disabled) {
		box-shadow: 0 0 0 2px var(--border-strong);
	}

	.dvt-relation-bool:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.dvt-relation-bool:disabled {
		opacity: 0.55;
		cursor: default;
	}
</style>
