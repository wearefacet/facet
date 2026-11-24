<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import { isSortableField } from '$lib/doctype/types.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import type { KanbanViewConfig, KanbanLane as KanbanLaneDef } from '$lib/collectionView/types.js';
	import { loadDoctypeViewByKind } from '$lib/doctype/loadDocumentView.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { can } from '$lib/permissions.svelte';
	import { toast } from '$lib/toast.svelte.js';
	import {
		applyLaneOverrides,
		lanesFromGroupBy,
		laneWriteTarget,
		mergeLaneFilters
	} from './lanes.js';
	import KanbanLane from './KanbanLane.svelte';

	type DocItem = DocumentResponse<Record<string, unknown>>;

	/**
	 * Per-lane fetch state. Each lane owns its loading/error state
	 * independently — one denied or failing lane does not blank the board.
	 */
	interface LaneState {
		items: DocItem[];
		loading: boolean;
		error: string | null;
		/** Capped count from the response `meta.count` ("at least N"). */
		count: number | null;
		/** Current per-lane fetch cap; grows by one page on Show more. */
		cap: number;
	}

	/**
	 * Kanban listing surface — horizontal lanes of cards, one `list()` call
	 * per lane (a lane is a thin wrapper over that call).
	 *
	 * Lane resolution: `values` mode derives one lane per value of the
	 * `group_by` enum field; `custom` mode reads the stored lane list. A
	 * missing `group_by` field or an empty lane list renders an explanatory
	 * empty state. The `card` template loads once per mount (60 s TTL cache
	 * shared with the peek drawer and chat cards); without it the cards
	 * render the identity body alone.
	 *
	 * Drag & drop: when the view sets `allow_move` and the viewer holds
	 * `update` on the doctype, cards drag between lanes and the drop PATCHes
	 * the target lane's value through a document update (the write target
	 * `laneWriteTarget` computes from the lane filter). Lanes without one
	 * writable `field__eq` filter accept no drops. The move is optimistic and
	 * reverts with a toast on failure; both lanes refetch quietly on success
	 * to restore the canonical sort and counts.
	 */
	let {
		driver,
		doctype,
		config,
		onCardClick
	}: {
		driver: DataDriver;
		doctype: DoctypeDef;
		config: KanbanViewConfig;
		/** Fired when a card is clicked — ListView opens the peek drawer. */
		onCardClick?: (docId: string) => void;
	} = $props();

	// ── Lane resolution ────────────────────────────────────────────────────
	const groupByField = $derived(
		config.mode === 'values' ? doctype.fields.find((f) => f.key === config.group_by) : undefined
	);

	// System columns the backend list sort always accepts (see
	// `Document::List#build_order_clause` in `src/document/list.cr`).
	const SYSTEM_SORT_COLUMNS: ReadonlySet<string> = new Set([
		'id',
		'created_at',
		'updated_at',
		'deleted_at'
	]);

	/**
	 * The sort the lane fetches send: the saved view's sort with the entries
	 * the backend would refuse dropped (`422 unknown_sort_field` /
	 * `unsortable_field`). A stale saved view — a removed field, or a type
	 * that cannot sort — falls back to the surface default instead of
	 * failing every lane. `undefined` keeps the no-sort default below.
	 */
	const laneSort = $derived.by<string[] | undefined>(() => {
		const entries = config.sort;
		if (!entries) return undefined;
		const ok = entries.filter((entry) => {
			const key = entry.startsWith('-') ? entry.slice(1) : entry;
			if (SYSTEM_SORT_COLUMNS.has(key)) return true;
			const def = doctype.fields.find((f) => f.key === key);
			return def !== undefined && isSortableField(def);
		});
		return ok.length > 0 ? ok : undefined;
	});
	const lanes = $derived.by<KanbanLaneDef[]>(() => {
		if (config.mode === 'values') {
			return groupByField
				? applyLaneOverrides(lanesFromGroupBy(groupByField), config.lane_order, config.hidden_lanes)
				: [];
		}
		return config.lanes ?? [];
	});

	// ── Drag & drop moves ─────────────────────────────────
	/** Moves enabled — the view opts in and the viewer may update the
	 *  doctype. UI affordance only; the WriteEnforcer re-checks the PATCH. */
	const canMove = $derived(
		config.allow_move === true && can(`${doctype.domain}.${doctype.doctype}`, 'update')
	);
	/** Per-lane write target — null lanes accept no drops. */
	const moveTargets = $derived.by(() =>
		lanes.map((lane) => (canMove ? laneWriteTarget(lane, doctype.fields) : null))
	);
	/** The card currently dragged — null when no drag is active. */
	let dragging = $state<{ docId: string; sourceIndex: number } | null>(null);
	/** One move at a time — concurrent optimistic moves would fight over the
	 *  lane state. Drops while a move is pending are ignored. */
	let movePending = $state(false);

	function onCardDragStart(index: number, docId: string): void {
		dragging = { docId, sourceIndex: index };
	}

	function onDragEnd(): void {
		dragging = null;
	}

	/**
	 * Drop a card on lane `index`: PATCH the target lane's value, with an
	 * optimistic move and a revert + toast on failure. A quiet refetch of
	 * both lanes follows success — the canonical sort position and the
	 * capped counts come back from the server.
	 */
	async function onLaneDrop(index: number, docId: string): Promise<void> {
		const target = moveTargets[index];
		const drag = dragging;
		if (!target || movePending || !drag || drag.docId !== docId) return;
		dragging = null;
		if (drag.sourceIndex === index) return;
		const sourceState = laneStates[drag.sourceIndex];
		const targetState = laneStates[index];
		const doc = sourceState?.items.find((it) => it.meta.id === docId);
		if (!sourceState || !targetState || !doc) return;
		const previous = { source: sourceState, target: targetState };
		// Optimistic move — the card lands at the target's tail; the refetch
		// after the PATCH restores the canonical order.
		laneStates[drag.sourceIndex] = {
			...sourceState,
			items: sourceState.items.filter((it) => it.meta.id !== docId),
			count: sourceState.count === null ? null : Math.max(0, sourceState.count - 1)
		};
		laneStates[index] = {
			...targetState,
			items: [...targetState.items, doc],
			count: targetState.count === null ? null : targetState.count + 1
		};
		movePending = true;
		try {
			await datasource.doc(docId).update({ [target.field]: target.value });
			const my = fetchSeq;
			refetchLane(drag.sourceIndex, my);
			refetchLane(index, my);
		} catch (err) {
			laneStates[drag.sourceIndex] = previous.source;
			laneStates[index] = previous.target;
			toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
		} finally {
			movePending = false;
		}
	}

	// ── Data source ────────────────────────────────────────────────────────
	const datasource = $derived(
		driver.domain(doctype.domain).doctype<Record<string, unknown>>(doctype.doctype) as DataSource<
			Record<string, unknown>
		>
	);

	// ── Lane fetch orchestration ───────────────────────────────────────────
	let laneStates = $state<LaneState[]>([]);
	// Cancellation counter — only the latest config's fetches may settle.
	let fetchSeq = 0;

	$effect(() => {
		const current = lanes;
		const cfg = config;
		const ds = datasource;
		const my = ++fetchSeq;
		if (current.length === 0) {
			laneStates = [];
			return;
		}
		laneStates = current.map(() => ({
			items: [],
			loading: true,
			error: null,
			count: null,
			cap: cfg.page_size ?? 25
		}));
		current.forEach((lane, index) => {
			fetchLane(ds, cfg, lane, index, cfg.page_size ?? 25, my);
		});
	});

	function fetchLane(
		ds: DataSource<Record<string, unknown>>,
		cfg: KanbanViewConfig,
		lane: KanbanLaneDef,
		index: number,
		cap: number,
		my: number
	): void {
		ds.list({
			filters: mergeLaneFilters(cfg.filters ?? {}, lane.filter),
			sort: laneSort ?? ['-updated_at'],
			items: cap
		})
			.then((res) => {
				if (my !== fetchSeq) return;
				laneStates[index] = {
					items: res.data,
					loading: false,
					error: null,
					count: res.meta.count,
					cap
				};
			})
			.catch((e: unknown) => {
				if (my !== fetchSeq) return;
				laneStates[index] = {
					items: [],
					loading: false,
					error: errorMessage(e, m.kanban_lane_error()),
					count: null,
					cap
				};
			});
	}

	/** Bump this lane's fetch cap by one page and re-fetch only it. */
	function showMore(index: number): void {
		const lane = lanes[index];
		const st = laneStates[index];
		if (!lane || !st) return;
		const cap = st.cap + (config.page_size ?? 25);
		const my = fetchSeq;
		laneStates[index] = { ...st, cap, loading: true, error: null };
		fetchLane(datasource, config, lane, index, cap, my);
	}

	/** Re-fetch one lane at its current cap, keeping its items visible while
	 *  the fetch runs (the loading marker joins the stack's tail). */
	function refetchLane(index: number, my: number): void {
		const lane = lanes[index];
		const st = laneStates[index];
		if (!lane || !st) return;
		laneStates[index] = { ...st, loading: true, error: null };
		fetchLane(datasource, config, lane, index, st.cap, my);
	}

	// ── Card template (loaded once per mount; card kind only) ─────────────
	let cardTemplate = $state<TemplateNode | null>(null);
	let templateSeq = 0;

	$effect(() => {
		const d = driver;
		const qualified = `${doctype.domain}.${doctype.doctype}`;
		const my = ++templateSeq;
		void loadDoctypeViewByKind(d, qualified, 'card').then((view) => {
			if (my !== templateSeq) return;
			cardTemplate = view.template;
		});
	});
</script>

{#if lanes.length === 0}
	<div class="kb-empty">{m.kanban_board_empty()}</div>
{:else}
	<div class="kb">
		{#each lanes as lane, i (i)}
			{#if laneStates[i]}
				<KanbanLane
					{lane}
					items={laneStates[i].items}
					loading={laneStates[i].loading}
					error={laneStates[i].error}
					count={laneStates[i].count}
					cap={laneStates[i].cap}
					{doctype}
					{driver}
					{cardTemplate}
					onShowMore={() => showMore(i)}
					{onCardClick}
					cardDraggable={canMove}
					droppable={canMove &&
						moveTargets[i] !== null &&
						dragging !== null &&
						dragging.sourceIndex !== i}
					onCardDragStart={(docId) => onCardDragStart(i, docId)}
					{onDragEnd}
					onDrop={(docId) => onLaneDrop(i, docId)}
				/>
			{/if}
		{/each}
	</div>
{/if}

<style>
	.kb {
		display: grid;
		grid-auto-flow: column;
		grid-auto-columns: 288px;
		/* One lane row. The row fills the board height when the board has
		   a height. Tall card stacks then scroll inside their lane. */
		grid-auto-rows: minmax(0, 1fr);
		gap: 14px;
		overflow-x: auto;
		/* The board mounts inside the bordered listview container — inset it
		   so lanes never fuse with the container edges (14px matches the
		   lane gap and the calendar's horizontal rhythm). */
		padding: 14px;
		/* Fill chain: the kanban list-view host gives this board its height. */
		flex: 1;
		min-height: 0;
	}

	.kb-empty {
		margin: 14px;
		padding: 32px 14px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
	}
</style>
