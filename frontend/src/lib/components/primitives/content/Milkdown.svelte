<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	/**
	 * Milkdown — Svelte 5 wrapper around `@milkdown/crepe` (WYSIWYG markdown
	 * editor on ProseMirror). The `Markdown` primitive mounts it for every
	 * mode — readonly preview and editable write alike — and
	 * `DvtInputLongtext.svelte` composes that primitive. One engine renders
	 * all markdown surfaces; do not mount this wrapper elsewhere.
	 *
	 * The editor is created in `onMount` against an anchor element and
	 * destroyed on unmount. Edits surface through `onchange` as markdown
	 * source. When `value` is provided the component is controlled: external
	 * value changes are pushed into the editor with `replaceAll` (guarded by
	 * an equality check, see workflow.md → equality-guard trap). Without
	 * `value`, the editor keeps its own document seeded from `defaultValue`.
	 *
	 * Files dropped or pasted upload to the artifact service and are
	 * referenced by `urn:facet:artifact:<id>` — images as image blocks,
	 * anything else as a capsule link (see `doc/frontend/markdown-editor.md`
	 * → Artifacts in longtext). Files are never inlined as data/blob URLs.
	 *
	 * ```svelte
	 * <Milkdown value={src} onchange={(v) => (src = v)} />
	 * ```
	 */
	import { onMount } from 'svelte';
	import { Crepe, type CrepeConfig } from '@milkdown/crepe';
	import { replaceAll } from '@milkdown/kit/utils';
	import { editorViewCtx } from '@milkdown/kit/core';
	import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
	import { TextSelection } from '@milkdown/kit/prose/state';
	import type { EditorView } from '@milkdown/kit/prose/view';
	import type { EditorState } from '@milkdown/kit/prose/state';
	import { isSameMarkdownDocument, normalizeMarkdown } from './markdown-normalize.js';
	import { createRefChipPlugins, type RefChipStore } from './ref-chip.js';
	import { createMermaidPlugins } from './mermaid-fence.js';
	import type { ReferenceClickHandler } from '$lib/template-types';
	import {
		resolveArtifactUrl,
		artifactDownloadUrl,
		uploadArtifactAsUrn,
		ARTIFACT_URN_PREFIX
	} from '$lib/artifacts.js';
	import { accountUrn, type MentionCandidate } from '$lib/mentions.js';
	import {
		doctypeMatches,
		docUrn,
		parseShowUrl,
		showRoute,
		type DocCandidate,
		type DocTypeOption,
		type ChipResolution
	} from '$lib/docrefs.js';
	import {
		createDefaultSources,
		createQueryDispatcher,
		PICKER_DEBOUNCE_MS,
		SEARCH_MIN_QUERY_LENGTH,
		type PickerEntry,
		type PickerGroup,
		type PickerSources
	} from '$lib/referenceSearch.js';
	import type { RecentDocument } from '$lib/recentDocuments.svelte';
	import '@milkdown/crepe/theme/common/style.css';
	import '@milkdown/crepe/theme/frame.css';

	let {
		value = undefined,
		defaultValue = '',
		readonly = false,
		placeholder = m.doc_md_placeholder(),
		onchange,
		onupload,
		onReferenceClick,
		domain = '',
		sources,
		...rest
	}: {
		/** Controlled markdown source. When set, overrides the internal document. */
		value?: string;
		/** Initial value for uncontrolled usage (ignored if `value` is set). */
		defaultValue?: string;
		/** Read-only: disables editing commands and toolbar actions. */
		readonly?: boolean;
		/** Placeholder shown on the empty document. */
		placeholder?: string;
		/** Fired with the markdown source on every document update. */
		onchange?: (value: string) => void;
		/** Receives a dropped/pasted/uploaded file, returns the URL the editor
		 *  inserts. Defaults to the standalone artifact upload — files are
		 *  stored on `POST /Api/core/artifacts` and referenced as
		 *  `urn:facet:artifact:<id>`; they are never inlined (blob/data URL). */
		onupload?: (file: File) => Promise<string>;
		/** Reference-chip click handler for readonly surfaces (the QuickView
		 *  drawer). Edit mode never calls it — a chip click there selects the
		 *  node. Without a handler readonly chips stay static. */
		onReferenceClick?: ReferenceClickHandler;
		/** Current domain segment, or `''` on global pages. Scopes the
		 *  reference picker: with a domain the typed query searches that
		 *  domain first; without one the picker escalates app-wide. */
		domain?: string;
		/** Injectable data sources for the `@` reference picker and the chip
		 *  label resolver. Defaults to the real services; stories pass
		 *  synthetic bundles. When given, it must carry `resolveLabel` for
		 *  chips to resolve live labels. */
		sources?: PickerSources;
	} = $props();

	let rootEl: HTMLDivElement | null = $state(null);
	let popupEl: HTMLDivElement | null = $state(null);
	let crepe: Crepe | null = null;
	let ready = $state(false);
	// Set while pushing an external value into the editor so the resulting
	// `markdownUpdated` event does not echo back through `onchange`.
	let pushing = false;
	// Normalized markdown the editor last reported outward (updated on every
	// `markdownUpdated`, seeded at create). The external-sync effect compares
	// the incoming `value` against this — see the effect comment.
	let reportedMarkdown: string | null = null;
	// Raw markdown the editor document was last seeded from — the mount
	// value, then every value the external sync pushed. It is the baseline
	// the save diff compares against: when the parsed document is back on it
	// (a full undo, a reverted experiment), the values bag is realigned to
	// this exact string — see the `markdownUpdated` listener.
	let seededRaw: string | null = null;
	// The seeded raw value's normalized form, cached for the same-document
	// check in the listener.
	let seededNormalized: string | null = null;
	// The last string this component wrote to the values bag — an `onchange`
	// payload or a pushed value. A same-document re-serialization stays
	// silent while the bag already carries the seeded string.
	let lastBagValue: string | null = null;
	// Mirror of the `readonly` prop for event handlers registered in
	// `onMount` — the click delegate below must consult the live value.
	// svelte-ignore state_referenced_locally — seeded from the initial prop;
	// the effect below owns all subsequent updates.
	let isReadonly = readonly;

	/** Resolved uploader — the prop when given, the standalone artifact
	 *  upload otherwise. Both return the URL/URN the editor inserts. */
	const uploadToUrn = (file: File): Promise<string> =>
		onupload ? onupload(file) : uploadArtifactAsUrn(file);

	/** Resolved picker sources — the prop when given, the real services
	 *  otherwise (the `onupload` precedent: default = real service, prop
	 *  override = stories). */
	const pickerSources = $derived(sources ?? createDefaultSources(domain));
	const hasDomain = $derived(domain.length > 0);

	// ── Reference picker state ──────────────────────────────────────────────
	// The ProseMirror props (registered in onMount) own the trigger and the
	// query range; the picker UI state lives here so the popup renders
	// through Svelte. The handlers read and write this state through plain
	// function closures below.

	type PickerMode = 'empty' | 'domain' | 'all' | 'scoped';

	let pickerOpen = $state(false);
	// Replacement range start — the trigger glyph (`@`, `[[`, or the `/`
	// command's cleared text). Everything from here to the caret is replaced
	// on pick.
	let pickerTriggerFrom = $state(0);
	// Where the query text starts (after the trigger).
	let pickerQueryFrom = $state(0);
	let pickerQuery = $state('');
	let pickerMode = $state<PickerMode>('empty');
	let pickerScoped = $state<DocTypeOption | null>(null);
	let pickerTop = $state(0);
	let pickerLeft = $state(0);

	let accounts = $state<MentionCandidate[]>([]);
	let accountsLoading = $state(false);
	let docGroups = $state<PickerGroup[]>([]);
	let searchLoading = $state(false);
	let searchError = $state(false);
	let scopedCandidates = $state<DocCandidate[]>([]);
	let scopedLoading = $state(false);

	let doctypeOptions = $state<DocTypeOption[] | null>(null);
	let doctypeMetaMap = new Map<string, DocTypeOption>();
	let doctypesRequested = false;
	let recentEntries = $state<RecentDocument[]>([]);
	let recentLabels = $state<Record<string, string>>({});
	const recentStarted = new Set<string>();

	let selected = $state(0);

	let searchSeq = 0;
	let scopedSeq = 0;
	let destroyed = false;

	const searchDispatcher = createQueryDispatcher(PICKER_DEBOUNCE_MS, (q) => {
		void executeSearch(q, pickerMode === 'all' ? 'all' : 'domain');
	});
	const scopedDispatcher = createQueryDispatcher(PICKER_DEBOUNCE_MS, (q) => {
		void executeScopedSearch(q);
	});

	let cleanupPickerListeners: (() => void) | null = null;

	function initialsOf(name: string): string {
		const bare = name.replace(/^@/, '').trim();
		const parts = bare.split(/\s+/).filter(Boolean);
		if (parts.length === 0) return '?';
		return (parts[0][0] + (parts[1]?.[0] ?? '')).toUpperCase();
	}

	function doctypeMetaOf(qualified: string): DocTypeOption | undefined {
		return doctypeMetaMap.get(qualified);
	}

	async function loadPickerMeta(): Promise<void> {
		if (doctypesRequested) return;
		doctypesRequested = true;
		try {
			const options = (await pickerSources.listDoctypes?.()) ?? [];
			doctypeOptions = options;
			doctypeMetaMap = new Map(options.map((o) => [o.target, o]));
			notifyAllChips();
		} catch {
			doctypeOptions = [];
		}
	}

	async function resolveRecentLabel(entry: RecentDocument): Promise<void> {
		if (recentStarted.has(entry.id)) return;
		recentStarted.add(entry.id);
		try {
			const res = await pickerSources.resolveLabel?.(entry.domain, entry.doctype, entry.id);
			recentLabels[entry.id] = res?.status === 'ok' ? res.label : entry.id;
		} catch {
			recentLabels[entry.id] = entry.id;
		}
	}

	// ── Picker fetch orchestration ──────────────────────────────────────────

	async function executeSearch(q: string, mode: 'domain' | 'all'): Promise<void> {
		const my = ++searchSeq;
		const src = pickerSources;
		const wantsAccounts = q.length >= 1;
		const wantsGroups = q.length >= SEARCH_MIN_QUERY_LENGTH;
		if (!wantsAccounts && !wantsGroups) {
			accounts = [];
			docGroups = [];
			accountsLoading = false;
			searchLoading = false;
			searchError = false;
			return;
		}
		accountsLoading = wantsAccounts;
		searchLoading = wantsGroups;
		searchError = false;
		const [acc, groups] = await Promise.allSettled([
			wantsAccounts && src.searchAccounts ? src.searchAccounts(q) : Promise.resolve([]),
			wantsGroups
				? mode === 'all'
					? (src.searchAllDomains?.(q) ?? Promise.resolve([]))
					: (src.searchDomain?.(q) ?? Promise.resolve([]))
				: Promise.resolve([])
		]);
		if (my !== searchSeq || !pickerOpen) return;
		accounts = acc.status === 'fulfilled' ? acc.value : [];
		docGroups = groups.status === 'fulfilled' ? groups.value : [];
		searchError = groups.status === 'rejected';
		accountsLoading = false;
		searchLoading = false;
		selected = 0;
	}

	async function executeScopedSearch(q: string): Promise<void> {
		const target = pickerScoped;
		if (!target) return;
		const my = ++scopedSeq;
		scopedLoading = true;
		try {
			const rows = (await pickerSources.searchDoctype?.(target.target, q)) ?? [];
			if (my !== scopedSeq || !pickerOpen) return;
			scopedCandidates = rows;
			selected = 0;
		} catch {
			if (my !== scopedSeq || !pickerOpen) return;
			scopedCandidates = [];
			selected = 0;
		} finally {
			if (my === scopedSeq) scopedLoading = false;
		}
	}

	// ── Picker open / close / navigation ────────────────────────────────────

	function openPickerAt(triggerFrom: number, queryFrom: number): void {
		pickerTriggerFrom = triggerFrom;
		pickerQueryFrom = queryFrom;
		pickerQuery = '';
		pickerMode = 'empty';
		pickerScoped = null;
		pickerOpen = true;
		selected = 0;
		accounts = [];
		docGroups = [];
		scopedCandidates = [];
		accountsLoading = false;
		searchLoading = false;
		searchError = false;
		scopedLoading = false;
		searchDispatcher.cancel();
		scopedDispatcher.cancel();
		void loadPickerMeta();
		recentEntries = hasDomain ? (pickerSources.recentDocuments?.() ?? []) : [];
		for (const entry of recentEntries) void resolveRecentLabel(entry);
	}

	function closePicker(): void {
		if (!pickerOpen) return;
		pickerOpen = false;
		searchDispatcher.cancel();
		scopedDispatcher.cancel();
		searchSeq += 1;
		scopedSeq += 1;
	}

	function scopeTo(option: DocTypeOption): void {
		pickerScoped = option;
		pickerMode = 'scoped';
		scopedCandidates = [];
		selected = 0;
	}

	function escalate(): void {
		pickerMode = 'all';
		docGroups = [];
		searchError = false;
		selected = 0;
	}

	function retrySearch(): void {
		const q = pickerQuery.trim();
		if (pickerMode === 'scoped' && pickerScoped) {
			void executeScopedSearch(q);
			return;
		}
		void executeSearch(q, pickerMode === 'all' ? 'all' : 'domain');
	}

	// ── Insertion ───────────────────────────────────────────────────────────

	/** Inserts plain text at the selection (no marks) — the fallback for an
	 *  unresolvable pasted URL, which stays literal text. */
	function insertPlainAtSelection(text: string): void {
		if (!crepe) return;
		crepe.editor.action((ctx) => {
			const view = ctx.get(editorViewCtx);
			const { tr } = view.state;
			const { from, to } = tr.selection;
			tr.insertText(text, from, to);
			view.dispatch(tr);
		});
	}

	/** Replaces `[from, to)` with a `ref_chip` node and parks the caret
	 *  after it — the shared insert for a picker pick and a Facet-URL paste.
	 *  A leaf inline node is one position wide, so `from + 1` is right
	 *  after the chip — `near` keeps the caret on that side. */
	function insertRefChipAt(
		view: EditorView,
		from: number,
		to: number,
		href: string,
		label: string
	): void {
		const { state } = view;
		const chipType = state.schema.nodes.ref_chip;
		if (!chipType) return;
		const chip = chipType.create({ href, label });
		const tr = state.tr.replaceWith(from, to, chip);
		tr.setSelection(TextSelection.near(tr.doc.resolve(from + 1)));
		view.dispatch(tr);
	}

	function insertReference(label: string, href: string): void {
		if (!crepe) return;
		crepe.editor.action((ctx) => {
			const view = ctx.get(editorViewCtx);
			const head = view.state.selection.to;
			const from = pickerTriggerFrom;
			if (!Number.isFinite(from) || from < 0 || from > head) return;
			insertRefChipAt(view, from, head, href, label);
		});
		closePicker();
	}

	async function pasteDocRef(ref: { domain: string; doctype: string; id: string }): Promise<void> {
		closePicker();
		let label: string | null = null;
		try {
			const res = await pickerSources.resolveLabel?.(ref.domain, ref.doctype, ref.id);
			if (res?.status === 'ok') label = res.label;
		} catch {
			label = null;
		}
		if (!crepe) return;
		const urn = docUrn(ref.domain, ref.doctype, ref.id);
		if (!label) {
			// Unresolvable — keep the URL as literal text.
			insertPlainAtSelection(showRoute(ref.domain, ref.doctype, ref.id));
			return;
		}
		const chipLabel = label;
		// Seed the chip cache with the resolved label — the node view's own
		// `ensure` sees it and skips the duplicate lookup.
		chipLabels.set(urn, { status: 'ok', label: chipLabel });
		crepe.editor.action((ctx) => {
			const view = ctx.get(editorViewCtx);
			const { from, to } = view.state.selection;
			insertRefChipAt(view, from, to, urn, chipLabel);
		});
	}

	// ── Picker rows — the flat keyboard-navigation model ────────────────────

	type PickerRow =
		| { kind: 'account'; candidate: MentionCandidate }
		| { kind: 'doc'; entry: PickerEntry; color?: string }
		| { kind: 'scoped'; candidate: DocCandidate }
		| { kind: 'recent'; entry: RecentDocument }
		| { kind: 'doctype'; option: DocTypeOption }
		| { kind: 'escalate' }
		| { kind: 'more'; option: DocTypeOption }
		| { kind: 'retry' };

	type RenderItem =
		| { type: 'head'; text: string; sub?: string; color?: string }
		| { type: 'note'; text: string }
		| { type: 'row'; index: number; row: PickerRow };

	const pickerModel = $derived.by(() => {
		const items: RenderItem[] = [];
		const rows: PickerRow[] = [];
		const push = (row: PickerRow) => {
			items.push({ type: 'row', index: rows.length, row });
			rows.push(row);
		};

		if (!pickerOpen) return { items, rows };
		const q = pickerQuery.trim();

		if (pickerMode === 'empty') {
			if (recentEntries.length > 0) {
				items.push({ type: 'head', text: m.doc_md_ref_recent() });
				for (const entry of recentEntries) push({ kind: 'recent', entry });
			}
			items.push({ type: 'head', text: m.doc_md_ref_filter_by_type() });
			if (doctypeOptions === null) {
				items.push({ type: 'note', text: '…' });
			} else if (doctypeOptions.length === 0) {
				items.push({ type: 'note', text: m.doc_md_ref_no_types() });
			} else {
				for (const option of doctypeOptions) push({ kind: 'doctype', option });
			}
			return { items, rows };
		}

		if (pickerMode === 'scoped' && pickerScoped) {
			items.push({
				type: 'head',
				text: pickerScoped.pluralLabel,
				sub: pickerScoped.target,
				color: pickerScoped.color
			});
			if (scopedLoading) items.push({ type: 'note', text: '…' });
			for (const candidate of scopedCandidates) push({ kind: 'scoped', candidate });
			if (!scopedLoading && scopedCandidates.length === 0) {
				items.push({ type: 'note', text: m.doc_md_ref_no_results() });
			}
			return { items, rows };
		}

		if (accounts.length > 0) {
			items.push({ type: 'head', text: m.doc_md_ref_people() });
			for (const candidate of accounts) push({ kind: 'account', candidate });
		} else if (accountsLoading) {
			items.push({ type: 'head', text: m.doc_md_ref_people() });
			items.push({ type: 'note', text: '…' });
		}
		if (docGroups.length === 0) {
			// First query keystroke: the debounced search has not landed yet.
			// Keep the trigger row visible through the wait — the empty state
			// swaps out for results when the response arrives.
			items.push({ type: 'note', text: m.doc_md_ref_no_results() });
		}
		if (pickerMode === 'all') {
			// The escalation's scope chip — the header the back-out rule targets.
			items.push({ type: 'head', text: m.doc_md_ref_all_domains() });
		}
		for (const group of docGroups) {
			const meta = doctypeMetaOf(group.key);
			items.push({
				type: 'head',
				text: meta?.pluralLabel ?? group.doctype,
				sub: group.key,
				color: meta?.color
			});
			for (const entry of group.entries) push({ kind: 'doc', entry, color: meta?.color });
			const option = meta ?? doctypeOptions?.find((o) => o.target === group.key);
			if (group.atCap && option) push({ kind: 'more', option });
		}
		if (searchLoading) items.push({ type: 'note', text: '…' });
		if (
			!searchLoading &&
			!searchError &&
			accounts.length === 0 &&
			docGroups.length === 0 &&
			q.length >= SEARCH_MIN_QUERY_LENGTH
		) {
			items.push({ type: 'note', text: m.doc_md_ref_no_results() });
		}
		if (searchError) push({ kind: 'retry' });
		if (pickerMode === 'domain' && hasDomain) push({ kind: 'escalate' });
		return { items, rows };
	});

	function activateRow(row: PickerRow): void {
		switch (row.kind) {
			case 'account':
				insertReference(`@${row.candidate.name}`, accountUrn(row.candidate.id));
				return;
			case 'doc':
				insertReference(row.entry.label, docUrn(row.entry.domain, row.entry.doctype, row.entry.id));
				return;
			case 'scoped':
				insertReference(
					row.candidate.label,
					docUrn(row.candidate.domain, row.candidate.doctype, row.candidate.id)
				);
				return;
			case 'recent':
				insertReference(
					recentLabels[row.entry.id] ?? row.entry.id,
					docUrn(row.entry.domain, row.entry.doctype, row.entry.id)
				);
				return;
			case 'doctype':
			case 'more':
				scopeTo(row.option);
				return;
			case 'escalate':
				escalate();
				return;
			case 'retry':
				retrySearch();
				return;
		}
	}

	function moveSelection(delta: number): void {
		const size = pickerModel.rows.length;
		if (size === 0) return;
		selected = (selected + delta + size) % size;
	}

	function pickerKeyDown(event: KeyboardEvent): boolean {
		if (!pickerOpen) return false;
		switch (event.key) {
			case 'ArrowDown':
				event.preventDefault();
				moveSelection(1);
				return true;
			case 'ArrowUp':
				event.preventDefault();
				moveSelection(-1);
				return true;
			case 'Enter': {
				// Consumed while the picker is open — with no rows (all candidates
				// filtered out) Enter must not reach the editor and split the
				// block under the query.
				event.preventDefault();
				const row = pickerModel.rows[selected];
				if (row) activateRow(row);
				return true;
			}
			case 'Tab': {
				event.preventDefault();
				if (pickerMode === 'domain' || pickerMode === 'empty') {
					const q = pickerQuery.trim();
					const matches = (doctypeOptions ?? []).filter((o) => doctypeMatches(o, q));
					if (q && matches.length === 1) scopeTo(matches[0]);
					else escalate();
				}
				return true;
			}
			case 'Escape':
				event.preventDefault();
				closePicker();
				return true;
			case 'Backspace':
				// Backspace on an empty query backs out of the escalated or
				// scoped scope without deleting the trigger — the plugin never
				// deletes user input.
				if (pickerQuery === '' && (pickerMode === 'all' || pickerMode === 'scoped')) {
					event.preventDefault();
					pickerMode = 'empty';
					pickerScoped = null;
					docGroups = [];
					selected = 0;
					return true;
				}
				return false;
			default:
				return false;
		}
	}

	// ── Reference chips — the ref_chip inline atom node ─────────────────
	// Chips are inline atom nodes (`ref_chip`, see ./ref-chip.ts): one node,
	// one position boundary, no hidden text. The persisted markdown keeps
	// the URN as the link href; only the node view resolves it — node attrs
	// pass through unsanitized (Milkdown's SAFE_PROTOCOLS sanitizer touches
	// link marks only). The label is live: resolved through `show()` per
	// URN, cached per editor instance, four states — ok (live title),
	// deleted 404/410 (stored text, struck through), forbidden 403
	// ("Restricted document" — the stored title may leak information to a
	// viewer who lost access), unknown/unresolvable (stored text, neutral
	// style). A resolution (or a doctype-tint load) notifies the subscribed
	// node views through the store below.

	const chipLabels = new Map<string, ChipResolution>();
	const chipPending = new Set<string>();
	let chipDoctypesRequested = false;
	const chipSubscribers = new Map<string, Set<() => void>>();

	function notifyChip(urn: string): void {
		for (const cb of chipSubscribers.get(urn) ?? []) cb();
	}

	function notifyAllChips(): void {
		for (const subs of chipSubscribers.values()) {
			for (const cb of subs) cb();
		}
	}

	/** The resolution cache + pub-sub the chip node views render from. */
	const chipStore: RefChipStore = {
		resolution: (urn) => chipLabels.get(urn),
		ensure: (urn, ref) => {
			if (ref.domain !== 'iam' || ref.doctype !== 'Account') {
				// Docref chip colours come from the doctype catalogue — loaded
				// once, lazily, on the first docref chip render.
				if (!chipDoctypesRequested) {
					chipDoctypesRequested = true;
					void loadPickerMeta();
				}
			}
			scheduleChipResolution(urn, ref);
		},
		subscribe: (urn, cb) => {
			let subs = chipSubscribers.get(urn);
			if (!subs) {
				subs = new Set();
				chipSubscribers.set(urn, subs);
			}
			subs.add(cb);
			return () => {
				subs.delete(cb);
				if (subs.size === 0) chipSubscribers.delete(urn);
			};
		}
	};

	function scheduleChipResolution(
		urn: string,
		ref: { domain: string; doctype: string; id: string }
	): void {
		if (chipLabels.has(urn) || chipPending.has(urn)) return;
		chipPending.add(urn);
		pickerSources
			.resolveLabel?.(ref.domain, ref.doctype, ref.id)
			.then((res) => {
				chipPending.delete(urn);
				if (destroyed) return;
				chipLabels.set(urn, res ?? { status: 'unknown' });
				notifyChip(urn);
			})
			.catch(() => {
				chipPending.delete(urn);
				if (destroyed) return;
				chipLabels.set(urn, { status: 'unknown' });
				notifyChip(urn);
			});
	}

	/**
	 * The artifact-capsule decorations. Also drives the picker query sync —
	 * it runs on every editor update, which is exactly the "batched per
	 * document render" hook. (Reference chips are `ref_chip` nodes; they
	 * render through the ref-chip node view, not decorations.)
	 */
	function buildDecorations(state: EditorState): DecorationSet {
		syncPickerFromState(state);
		const decorations: ReturnType<typeof Decoration.inline>[] = [];
		state.doc.descendants((node, pos) => {
			for (const mark of node.marks) {
				const href = mark.attrs.href;
				if (mark.type.name !== 'link' || typeof href !== 'string') continue;
				if (!href.startsWith(ARTIFACT_URN_PREFIX)) continue;
				decorations.push(
					Decoration.inline(pos, pos + node.nodeSize, {
						class: 'md-artifact-capsule-link',
						'data-artifact-id': href.slice(ARTIFACT_URN_PREFIX.length)
					})
				);
			}
		});
		return DecorationSet.create(state.doc, decorations);
	}

	// ── Picker trigger + query sync ─────────────────────────────────────────

	/** Opening punctuation that may precede a trigger glyph. */
	const OPENER_RE = /[\s([{'"“‘<]$/u;

	function maybeOpenPicker(view: EditorView, from: number, _to: number, text: string): boolean {
		if (isReadonly || pickerOpen) return false;
		const doc = view.state.doc;
		if (text === '@') {
			const resolvedFrom = doc.resolve(from);
			if (resolvedFrom.parent.type.spec.code) return false;
			const atBlockStart = resolvedFrom.parentOffset === 0;
			const before = from > 0 ? doc.textBetween(from - 1, from, '\n', '\0') : '';
			if (atBlockStart || OPENER_RE.test(before)) {
				// `from` is the insertion point in the pre-input document; the
				// glyph's own transaction lands the caret right after it, at
				// `from + text.length` — where the query also starts.
				openPickerAt(from, from + text.length);
			}
			return false;
		}
		if (text === '[' && from > 0) {
			const before = doc.textBetween(from - 1, from, '\n', '\0');
			if (before === '[') {
				// `[[` — both brackets are the trigger; the query starts after
				// the second bracket. The plugin swallows both on pick.
				openPickerAt(from - 1, from + text.length);
			}
			return false;
		}
		return false;
	}

	function repositionPicker(view: EditorView): void {
		if (!pickerOpen || !rootEl) return;
		let coords: { left: number; top: number; bottom: number } | null;
		try {
			coords = view.coordsAtPos(pickerTriggerFrom);
		} catch {
			closePicker();
			return;
		}
		if (!coords) {
			closePicker();
			return;
		}
		const rect = rootEl.getBoundingClientRect();
		const POPUP_W = 340;
		const POPUP_H = 320;
		let left = coords.left - 6;
		left = Math.max(rect.left + 4, Math.min(left, rect.right - POPUP_W - 4));
		let top = coords.bottom + 6;
		if (top + POPUP_H > window.innerHeight - 8) {
			top = Math.max(8, coords.top - POPUP_H - 6);
		}
		pickerTop = Math.round(top);
		pickerLeft = Math.round(left);
	}

	/**
	 * Recomputes the query from the live document on every editor update.
	 * Also enforces the close rules: the caret must stay at or after the
	 * query start, the query stays single-block and bounded. The typed text
	 * is never deleted — a dismissal leaves it as literal text.
	 */
	function syncPickerFromState(state: EditorState): void {
		if (!pickerOpen) return;
		const head = state.selection.to;
		if (state.selection.to < pickerQueryFrom) {
			closePicker();
			return;
		}
		let text: string;
		try {
			text = state.doc.textBetween(pickerQueryFrom, head, '\n', '\0');
		} catch {
			closePicker();
			return;
		}
		if (text.includes('\n') || text.length > 64) {
			closePicker();
			return;
		}
		pickerQuery = text;
		const q = text.trim();
		if (pickerMode === 'empty' && q.length > 0) {
			pickerMode = hasDomain ? 'domain' : 'all';
			selected = 0;
		} else if (pickerMode === 'domain' && q.length === 0) {
			pickerMode = 'empty';
			docGroups = [];
			selected = 0;
		}
		if (crepe) {
			crepe.editor.action((ctx) => repositionPicker(ctx.get(editorViewCtx)));
		}
	}

	// ── Paste-to-chip ───────────────────────────────────────────────────────
	// Pasting a Facet show URL converts it into a reference chip. A
	// plain-text paste (Ctrl/Cmd+Shift+V) keeps the URL: the intent rides on
	// the modifier keys of the keydown that precedes the paste event, which
	// browsers do not surface on the event itself.

	let plainPasteIntentAt = 0;

	function handlePasteText(e: ClipboardEvent): void {
		if (isReadonly) return;
		if (Date.now() - plainPasteIntentAt < 500) return;
		const dt = e.clipboardData;
		if (!dt || dt.files.length > 0) return;
		const text = dt.getData('text/plain');
		if (!text) return;
		const trimmed = text.trim();
		if (trimmed !== text) return;
		const ref = parseShowUrl(trimmed);
		if (!ref) return;
		e.preventDefault();
		e.stopPropagation();
		void pasteDocRef(ref);
	}

	onMount(() => {
		if (!rootEl) return;
		// Captured synchronously: if the controlled value changes while the
		// async create() is in flight, the sync effect still sees the
		// difference and pushes the new value once ready.
		const initialMarkdown = value ?? defaultValue;
		// The editor is created from this exact value — it is the seeded
		// baseline, so the first (untyped) re-serialization the listener sees
		// cannot pass as a change.
		seededRaw = initialMarkdown;
		seededNormalized = normalizeMarkdown(initialMarkdown);
		lastBagValue = initialMarkdown;
		const featureConfigs: CrepeConfig['featureConfigs'] = {
			[Crepe.Feature.Placeholder]: { text: placeholder, mode: 'block' },
			[Crepe.Feature.ImageBlock]: {
				onUpload: uploadToUrn,
				// The editor DOM loads artifact URNs through the download
				// gateway; non-artifact srcs pass through.
				proxyDomURL: resolveArtifactUrl
			},
			[Crepe.Feature.BlockEdit]: {
				// The `/` menu is the launcher, not the host (block-start only,
				// hides on run): one command clears the `/…` text and opens the
				// same picker the `@` trigger opens.
				buildMenu: (builder) => {
					const group = builder.addGroup('references', m.doc_md_ref_slash_group());
					group.addItem('reference-document', {
						label: m.doc_md_ref_slash_item(),
						icon: REFERENCE_ICON_SVG,
						onRun: (ctx) => {
							const view = ctx.get(editorViewCtx);
							const { state } = view;
							const { to } = state.selection;
							const resolvedTo = state.doc.resolve(to);
							const blockStart = resolvedTo.before(resolvedTo.depth);
							view.dispatch(state.tr.delete(blockStart, to));
							openPickerAt(blockStart, blockStart);
						}
					});
				}
			}
		};
		const instance = new Crepe({
			root: rootEl,
			defaultValue: initialMarkdown,
			featureConfigs
		});
		instance.on((listener) => {
			listener.markdownUpdated((_ctx, markdown) => {
				// Milkdown serializes an empty paragraph (a blank line made with
				// Enter, or a pasted empty <p>) as a literal `<br />` line. Stored
				// longtext is markdown and must never carry HTML — collapse the
				// convention back to a plain paragraph break before it leaves.
				const normalized = normalizeMarkdown(markdown);
				reportedMarkdown = normalized;
				if (pushing) return;
				// The serializer is not a fixed point of parse∘serialize (`- a`
				// round-trips to `* a\n`), so every doc-changing transaction
				// re-serializes the whole field — type + undo, space + backspace,
				// a slash-menu insert somewhere else. The editor emits only when
				// the parsed document left the seeded baseline. When it is back
				// on it, the emission realigns the values bag to the exact seeded
				// string, so the save diff folds to a no-op instead of storing
				// the restyled markers.
				if (
					seededRaw !== null &&
					seededNormalized !== null &&
					isSameMarkdownDocument(seededNormalized, normalized)
				) {
					if (lastBagValue === seededRaw) return;
					lastBagValue = seededRaw;
					onchange?.(seededRaw);
					return;
				}
				lastBagValue = normalized;
				onchange?.(normalized);
			});
		});
		// The `ref_chip` node (mention + document-reference chips) must be
		// registered before the editor boots — custom plugins are .use()d
		// between construction and create().
		instance.editor.use(
			createRefChipPlugins({
				store: chipStore,
				isReadonly: () => isReadonly,
				onReferenceClick: () => onReferenceClick,
				initialsOf,
				docrefColor: (qualified) => doctypeMetaOf(qualified)?.color
			})
		);
		// Mermaid fences render as diagrams through their own `code_block`
		// node view. It is registered after the Crepe constructor (which
		// applies the CodeMirror feature) so its factory claims the
		// `code_block` slot; non-mermaid fences fall back to Crepe's view.
		instance.editor.use(createMermaidPlugins({ isReadonly: () => isReadonly }));
		crepe = instance;
		void instance.create().then(() => {
			// The editor was created from this exact value — seed the reported
			// form with it so the sync effect does not push the (differently
			// serialized) doc back over itself on mount.
			reportedMarkdown = normalizeMarkdown(initialMarkdown);
			ready = true;
			// Reference chips + artifact capsules ride on decorations; the
			// picker's trigger and keyboard handling ride on the same direct
			// props. Handlers return false when not consumed so Milkdown's own
			// plugins keep working (ProseMirror resolves props by priority,
			// first truthy wins).
			instance.editor.action((ctx) => {
				ctx.get(editorViewCtx).setProps({
					// Artifact capsules + the picker query sync — chips render
					// through their node view, not decorations.
					decorations: buildDecorations,
					handleTextInput: maybeOpenPicker,
					handleKeyDown: (_view, event) => pickerKeyDown(event)
				});
			});
			// Reposition while the page scrolls or the window resizes — the
			// popup is fixed and would drift from the anchor otherwise.
			const onScroll = () => {
				if (!crepe || !pickerOpen) return;
				crepe.editor.action((ctx) => repositionPicker(ctx.get(editorViewCtx)));
			};
			window.addEventListener('scroll', onScroll, true);
			window.addEventListener('resize', onScroll);
			const onDocMouseDown = (e: MouseEvent) => {
				if (!pickerOpen) return;
				const target = e.target as Element | null;
				if (!target) return;
				if (target.closest('.md-ref-picker')) return;
				if (rootEl?.contains(target)) return;
				closePicker();
			};
			document.addEventListener('mousedown', onDocMouseDown);
			cleanupPickerListeners = () => {
				window.removeEventListener('scroll', onScroll, true);
				window.removeEventListener('resize', onScroll);
				document.removeEventListener('mousedown', onDocMouseDown);
			};
		});
		// Capture phase — these fire before ProseMirror's own drop/paste
		// handlers, so a takeover (see `handleFileEvent`) fully replaces the
		// editor's handling of the event.
		const onDrop = (e: DragEvent) => {
			void handleFileEvent(e);
		};
		const onPaste = (e: ClipboardEvent) => {
			void handleFileEvent(e);
		};
		const onPasteText = (e: ClipboardEvent) => {
			handlePasteText(e);
		};
		const onKeyDownIntent = (e: KeyboardEvent) => {
			if ((e.ctrlKey || e.metaKey) && e.shiftKey && (e.key === 'v' || e.key === 'V')) {
				plainPasteIntentAt = Date.now();
			}
		};
		// Readonly surfaces have no editable link mark (Milkdown sanitizes the
		// URN scheme to `href=""`), so capsule clicks are delegated here and
		// routed to the download gateway.
		const onClick = (e: MouseEvent) => {
			if (!isReadonly) return;
			const target = (e.target as HTMLElement | null)?.closest('[data-artifact-id]');
			const id = target?.getAttribute('data-artifact-id');
			if (!id) return;
			e.preventDefault();
			window.open(artifactDownloadUrl(id), '_blank', 'noopener');
		};
		rootEl.addEventListener('drop', onDrop, true);
		rootEl.addEventListener('paste', onPaste, true);
		rootEl.addEventListener('paste', onPasteText, true);
		rootEl.addEventListener('keydown', onKeyDownIntent, true);
		rootEl.addEventListener('click', onClick);
		return () => {
			destroyed = true;
			ready = false;
			cleanupPickerListeners?.();
			rootEl?.removeEventListener('drop', onDrop, true);
			rootEl?.removeEventListener('paste', onPaste, true);
			rootEl?.removeEventListener('paste', onPasteText, true);
			rootEl?.removeEventListener('keydown', onKeyDownIntent, true);
			rootEl?.removeEventListener('click', onClick);
			void instance.destroy();
			crepe = null;
		};
	});

	/**
	 * Insert an uploaded file reference at the selection: images become an
	 * image-block node (`![](url)`), anything else a markdown link whose
	 * label is the original filename (a capsule on render).
	 */
	function insertFileReference(urn: string, isImage: boolean, filename: string): void {
		if (!crepe) return;
		crepe.editor.action((ctx) => {
			const view = ctx.get(editorViewCtx);
			const { tr, schema } = view.state;
			if (isImage) {
				const nodeType = schema.nodes['image-block'] ?? schema.nodes.image;
				if (!nodeType) return;
				const node = nodeType.createAndFill({ src: urn });
				if (!node) return;
				view.dispatch(tr.replaceSelectionWith(node));
			} else {
				// Insert the filename at the selection and apply the link mark
				// explicitly — `replaceSelectionWith` would let the inserted text
				// inherit the cursor's (mark-less) stored marks.
				const linkMark = schema.marks.link?.create({ href: urn });
				if (!linkMark) return;
				const { from, to } = tr.selection;
				tr.insertText(filename, from, to);
				tr.addMark(from, from + filename.length, linkMark);
				view.dispatch(tr);
			}
		});
	}

	/**
	 * File upload entry point. Pure-image drops/pastes pass through to
	 * Crepe's uploader (which carries the drop coordinate); any event with a
	 * non-image file is taken over here: files upload to the artifact
	 * service and insert as a link at the selection. Without this, Crepe's
	 * uploader silently ignores non-image files — and its default would
	 * inline images as ephemeral `blob:` URLs.
	 */
	async function handleFileEvent(e: DragEvent | ClipboardEvent): Promise<void> {
		if (readonly) return;
		const dt = e instanceof DragEvent ? e.dataTransfer : e.clipboardData;
		const files: File[] = Array.from(dt?.files ?? []);
		if (files.length === 0 || files.every((f) => f.type.startsWith('image/'))) return;
		e.preventDefault();
		e.stopPropagation();
		for (const file of files) {
			try {
				const urn = await uploadToUrn(file);
				if (!urn) throw new Error(m.common_upload_failed());
				insertFileReference(urn, file.type.startsWith('image/'), file.name);
			} catch (err) {
				// The uploader surfaces errors (status text) — skip insertion.
				console.error('[milkdown] file upload failed', err);
			}
		}
	}

	/** Slash-menu item icon — an at-sign, matching the mention trigger. */
	const REFERENCE_ICON_SVG = `
  <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="12" cy="12" r="4"></circle>
    <path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"></path>
  </svg>
`;

	// ── Effect wiring ───────────────────────────────────────────────────────

	// Drives the picker fetches, debounced through the dispatchers so one
	// burst of typing issues one round of requests.
	$effect(() => {
		if (!pickerOpen) return;
		const q = pickerQuery.trim();
		const mode = pickerMode;
		const scopedTarget = pickerScoped?.target ?? null;
		if (mode === 'empty') {
			void loadPickerMeta();
			return;
		}
		if (mode === 'scoped' && scopedTarget) {
			scopedDispatcher.query(q);
			return;
		}
		searchDispatcher.query(q);
	});

	// Keyboard selection follows the row model; keep the index in range and
	// the selected row scrolled into view.
	$effect(() => {
		const size = pickerModel.rows.length;
		if (selected >= size) selected = Math.max(0, size - 1);
		if (popupEl && pickerOpen) {
			popupEl.querySelector(`[data-row-index="${selected}"]`)?.scrollIntoView({ block: 'nearest' });
		}
	});

	// External value sync — pushes an externally changed value into the
	// editor. The comparison is against `reportedMarkdown` — the normalized
	// markdown the editor last reported outward, seeded with the value the
	// editor was created from — never against the live document. Reading
	// the live doc here would make every effect re-run a potential reset:
	// Milkdown's serialization is not a fixed point of parse∘serialize, so a
	// doc-based compare also fires on mount, and an emission is debounced
	// (200 ms), so in-flight typing always looks like drift. With the
	// reported-form compare, a re-run whose `value` is unchanged is a no-op.
	$effect(() => {
		if (!ready || !crepe || value === undefined) return;
		const target = normalizeMarkdown(value);
		if (reportedMarkdown === target) return;
		pushing = true;
		crepe.editor.action(replaceAll(value));
		pushing = false;
		reportedMarkdown = target;
		// The editor now holds this document — it is the new seeded baseline
		// the listener compares re-serializations against.
		seededRaw = value;
		seededNormalized = target;
		lastBagValue = value;
	});

	$effect(() => {
		if (!ready || !crepe) return;
		isReadonly = readonly;
		crepe.setReadonly(readonly);
	});
</script>

<div class="milkdown-host" {...rest}>
	<div bind:this={rootEl} class="milkdown-root"></div>
	{#if pickerOpen}
		<div
			class="md-ref-picker"
			bind:this={popupEl}
			style:top="{pickerTop}px"
			style:left="{pickerLeft}px"
		>
			{#each pickerModel.items as item, i (item.type === 'row' ? `row-${item.index}` : `${item.type}-${i}`)}
				{#if item.type === 'head'}
					<div class="md-ref-head">
						{#if item.color}<span class="md-ref-dot" style:background={item.color}></span>{/if}
						<span class="md-ref-head-label">{item.text}</span>
						{#if item.sub}<span class="md-ref-sub">{item.sub}</span>{/if}
					</div>
				{:else if item.type === 'note'}
					<div class="md-ref-note">{item.text}</div>
				{:else}
					<button
						type="button"
						class="md-ref-row"
						class:md-ref-row-on={selected === item.index}
						data-row-index={item.index}
						onpointerdown={(e) => e.preventDefault()}
						onclick={() => activateRow(item.row)}
					>
						{#if item.row.kind === 'account'}
							<span class="md-ref-avatar">{initialsOf(item.row.candidate.name)}</span>
							<span class="md-ref-label">@{item.row.candidate.name}</span>
						{:else if item.row.kind === 'doc'}
							<span class="md-ref-dot" style:background={item.row.color ?? 'var(--text-3)'}></span>
							<span class="md-ref-label">{item.row.entry.label}</span>
							{#if item.row.entry.subtitle}<span class="md-ref-sub">{item.row.entry.subtitle}</span
								>{/if}
						{:else if item.row.kind === 'scoped'}
							<span class="md-ref-dot" style:background={pickerScoped?.color ?? 'var(--text-3)'}
							></span>
							<span class="md-ref-label">{item.row.candidate.label}</span>
						{:else if item.row.kind === 'recent'}
							<span
								class="md-ref-dot"
								style:background={doctypeMetaOf(
									`${item.row.entry.domain}.${item.row.entry.doctype}`
								)?.color ?? 'var(--text-3)'}
							></span>
							<span class="md-ref-label"
								>{recentLabels[item.row.entry.id] ?? item.row.entry.id}</span
							>
							<span class="md-ref-sub">{item.row.entry.domain}.{item.row.entry.doctype}</span>
						{:else if item.row.kind === 'doctype'}
							<span class="md-ref-dot" style:background={item.row.option.color ?? 'var(--text-3)'}
							></span>
							<span class="md-ref-label">{item.row.option.pluralLabel}</span>
							<span class="md-ref-sub">{item.row.option.target}</span>
						{:else if item.row.kind === 'more'}
							<span class="md-ref-label md-ref-more"
								>{m.doc_md_ref_more_in({ label: item.row.option.pluralLabel })}</span
							>
						{:else if item.row.kind === 'escalate'}
							<span class="md-ref-label md-ref-more"
								>{m.doc_md_ref_search_all({ q: pickerQuery.trim() })}</span
							>
						{:else if item.row.kind === 'retry'}
							<span class="md-ref-label md-ref-more">{m.doc_md_ref_retry()}</span>
						{/if}
					</button>
				{/if}
			{/each}
		</div>
	{/if}
</div>

<style>
	.milkdown-host {
		display: flex;
		flex-direction: column;
		min-width: 0;
		background: var(--surface);
	}

	/* Popups (selection toolbar, block handle, slash menu, link tooltip,
	 * the reference picker) mount inside the editor root — Crepe's plugins
	 * append them to the ProseMirror view's parent, not to document.body.
	 * They must not be clipped by ancestor `overflow: hidden`, and they must
	 * layer above surrounding page content (app dropdowns live at 1100,
	 * overlays at ~100, so 500 is above content, below global chrome). */
	.milkdown-host :global(.milkdown-toolbar),
	.milkdown-host :global(.milkdown-block-handle),
	.milkdown-host :global(.milkdown-slash-menu),
	.milkdown-host :global(.milkdown-link-preview),
	.milkdown-host :global(.milkdown-link-edit) {
		z-index: 500;
	}

	.milkdown-root {
		flex: 1 1 auto;
		min-height: 0;
	}

	/* ── Reference picker popup ──────────────────────────────────────────
	 * Fixed to the viewport from the trigger's coords; escapes every
	 * ancestor box, so no overflow rule can clip it. */
	.md-ref-picker {
		position: fixed;
		z-index: 500;
		width: 340px;
		max-width: calc(100vw - 16px);
		max-height: 320px;
		overflow-y: auto;
		padding: 4px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
	}

	.md-ref-head {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 7px 8px 3px;
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.02em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.md-ref-sub {
		font-weight: 400;
		text-transform: none;
		letter-spacing: 0;
		color: var(--text-3);
		font-size: 10.5px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.md-ref-row {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		padding: 6px 8px;
		border: none;
		background: none;
		border-radius: var(--r-sm);
		font: inherit;
		font-size: 12.5px;
		color: var(--text);
		text-align: left;
		cursor: pointer;
	}

	.md-ref-row:hover,
	.md-ref-row-on {
		background: var(--sunken);
	}

	.md-ref-row:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}

	.md-ref-label {
		flex: 1 1 auto;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.md-ref-more {
		color: var(--accent-ink);
		font-weight: 500;
	}

	.md-ref-dot {
		flex: 0 0 auto;
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--text-3);
	}

	.md-ref-avatar {
		flex: 0 0 auto;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		border-radius: 50%;
		background: color-mix(in srgb, var(--accent) 22%, var(--surface));
		color: var(--accent-ink);
		font-size: 8.5px;
		font-weight: 700;
	}

	.md-ref-note {
		padding: 6px 8px;
		font-size: 12px;
		color: var(--text-3);
	}

	/* ── Reference chips — the ref_chip inline atom node ───────────
	 * The persisted markdown keeps the URN as the link href; the node
	 * view renders the resolved label. Chips carry no hidden text — one
	 * node, one position boundary. */
	.milkdown-host :global(.ProseMirror .md-mention-chip),
	.milkdown-host :global(.ProseMirror .md-docref-chip) {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 1px 8px 1px 5px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--accent) 34%, transparent);
		background: color-mix(in srgb, var(--accent) 9%, var(--surface));
		font-size: 11.5px;
		font-weight: 500;
		line-height: 18px;
		color: color-mix(in srgb, var(--accent-ink) 80%, var(--text));
		white-space: nowrap;
		cursor: default;
	}

	.milkdown-host :global(.ProseMirror .md-docref-chip) {
		border-color: var(--border);
		background: var(--sunken);
		color: var(--text);
	}

	.milkdown-host :global(.ProseMirror .md-mention-chip .md-chip-avatar) {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 15px;
		height: 15px;
		border-radius: 50%;
		background: color-mix(in srgb, var(--accent) 24%, var(--surface));
		color: var(--accent-ink);
		font-size: 7.5px;
		font-weight: 700;
	}

	.milkdown-host :global(.ProseMirror .md-docref-chip .md-chip-dot) {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--text-3);
	}

	/* Chip states — deleted (stored text, struck), forbidden (never render
	 * the stored title), unknown (stored text, neutral). */
	.milkdown-host :global(.ProseMirror .md-chip-deleted) {
		border-color: var(--border);
		background: var(--sunken);
		color: var(--text-3);
	}

	.milkdown-host :global(.ProseMirror .md-chip-deleted .md-chip-label) {
		text-decoration: line-through;
	}

	.milkdown-host :global(.ProseMirror .md-chip-forbidden) {
		border-color: color-mix(in srgb, var(--danger) 40%, transparent);
		background: color-mix(in srgb, var(--danger) 8%, var(--surface));
		color: var(--danger);
		font-style: italic;
	}

	.milkdown-host :global(.ProseMirror .md-chip-unknown) {
		border-color: var(--border);
		color: var(--text-2);
	}

	/* Selected chip (write mode) — the ProseMirror node-selection look.
	 * selectNode paints the class on the node view's own dom. */
	.milkdown-host :global(.ProseMirror .md-mention-chip.ProseMirror-selectednode),
	.milkdown-host :global(.ProseMirror .md-docref-chip.ProseMirror-selectednode) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* ── Mermaid fences — the `code_block` node view in mermaid-fence.ts ──
	 * Readonly: the diagram replaces the source. Edit: the source stays
	 * editable on top, the diagram renders in a preview area below. The
	 * diagram component draws its own card; these rules only lay the two
	 * halves out and give the source a code look. */
	.milkdown-host :global(.ProseMirror .md-mermaid) {
		margin: 8px 0;
	}

	.milkdown-host :global(.ProseMirror .md-mermaid-source) {
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 1.55;
		white-space: pre-wrap;
		padding: 10px 12px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.milkdown-host :global(.ProseMirror .md-mermaid-preview) {
		margin-top: 6px;
	}

	.milkdown-host :global(.ProseMirror .md-mermaid .mmd) {
		margin-bottom: 0;
	}

	/* Readonly chips open the QuickView — the pointer affordance (the
	 * editor root is contenteditable=false exactly when the Milkdown
	 * `readonly` prop is set; editable chips select instead). */
	.milkdown-host :global(.ProseMirror[contenteditable='false'] .md-mention-chip),
	.milkdown-host :global(.ProseMirror[contenteditable='false'] .md-docref-chip) {
		cursor: pointer;
	}

	/* ── Artifact capsules — links to urn:facet:artifact: URNs ─────────
	 * The persisted markdown keeps the URN as the link href; only display
	 * surfaces resolve it. In the editor DOM the URN never appears as an
	 * href (Milkdown sanitizes unknown schemes to `href=""`), so a
	 * decoration (set in onMount) styles the wrapping span and carries the
	 * artifact id. Clicking in edit mode places the caret; on readonly
	 * surfaces the click delegate opens the download gateway. */
	.milkdown-host :global(.ProseMirror .md-artifact-capsule-link) {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 1px 8px 1px 7px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--accent) 34%, transparent);
		background: color-mix(in srgb, var(--accent) 9%, var(--surface));
		font-size: 11.5px;
		font-weight: 500;
		line-height: 18px;
		color: color-mix(in srgb, var(--accent-ink) 80%, var(--text));
		white-space: nowrap;
	}

	/* Crepe's reset gives the document a page-like `60px 120px` padding.
	 * Embedded editors need field-like padding instead — this matches the
	 * CodeMirror source editor's `.cm-content` padding. */
	.milkdown-host .milkdown-root :global(.ProseMirror) {
		padding: 12px 14px;
	}

	/* ── Token mapping ──────────────────────────────────────────────────
	 * Milkdown wraps the editor in its own `div.milkdown` INSIDE our root
	 * (`createViewContainer` in @milkdown/core), and the themes define the
	 * `--crepe-*` variables on that wrapper. Custom properties inherit from
	 * the NEAREST definition, so the mapping must target the wrapper itself,
	 * not our root — otherwise the theme values (closer to the content)
	 * win. */
	.milkdown-host .milkdown-root :global(.milkdown) {
		--crepe-color-background: var(--surface);
		--crepe-color-on-background: var(--text);
		--crepe-color-surface: var(--surface-2);
		--crepe-color-surface-low: var(--surface-2);
		--crepe-color-on-surface: var(--text);
		--crepe-color-on-surface-variant: var(--text-2);
		--crepe-color-outline: var(--text-3);
		--crepe-color-primary: var(--accent);
		--crepe-color-secondary: var(--accent-weak);
		--crepe-color-on-secondary: var(--text);
		--crepe-color-inverse: var(--text);
		--crepe-color-on-inverse: var(--surface);
		--crepe-color-inline-code: var(--text-2);
		--crepe-color-error: var(--danger);
		--crepe-color-hover: var(--sunken);
		--crepe-color-selected: var(--accent-weak);
		--crepe-color-inline-area: var(--sunken);
		--crepe-base-font-size: 13.5px;
		--crepe-font-default: var(--font-sans);
		--crepe-font-title: var(--font-display);
		--crepe-font-code: var(--font-mono);
	}

	/* Dark variant (Storybook `.dark` class / app `[data-theme]`). The
	 * `.dark` ancestor lives outside this component — without the
	 * `:global()` wrap Svelte drops the selector as unreachable. */
	:global(.dark) .milkdown-host .milkdown-root :global(.milkdown),
	:global([data-theme='dark']) .milkdown-host .milkdown-root :global(.milkdown) {
		--crepe-shadow-1: var(--sh-1);
		--crepe-shadow-2: var(--sh-2);
	}

	/* ── Editor chrome — caret, placeholder, link ink ──────────────────
	 * The frame theme paints every floating-menu icon (block handle,
	 * selection toolbar, slash menu, table handles, link tooltips) and
	 * the caret from `--crepe-color-outline`, and the placeholder from
	 * the text colour at 40% opacity. The mapping above resolves outline
	 * to `--text-3` (hairline mixes — table borders, hr, dividers — use
	 * it at 20% alpha and stay visually stable) so icons and the caret
	 * read against the surface; the rules below align the rest with the
	 * app conventions. */

	/* Crepe's virtual cursor replaces the native caret (`caret-color:
	 * transparent` in the virtual-cursor stylesheet) — pin a readable
	 * ink in both themes. */
	.milkdown-host .milkdown-root :global(.milkdown .ProseMirror-focused) {
		--prosemirror-virtual-cursor-color: var(--text-2);
	}

	/* Same token as `.cm-placeholder` and every input placeholder. */
	.milkdown-host .milkdown-root :global(.milkdown .crepe-placeholder::before) {
		color: var(--text-3);
	}

	/* Gold fill ≠ gold text: link copy uses the AA ink. The fill accent
	 * (`--crepe-color-primary`) stays for outlines and drag handles. */
	.milkdown-host .milkdown-root :global(.milkdown .ProseMirror a) {
		color: var(--accent-ink);
	}

	/* ── Prose typography — the app's single markdown scale ───────────
	 * The frame theme sets serif display headings at ~2–2.6em with weight
	 * 400; the app's prose uses the display sans with 600 weight and clear
	 * size steps. Every markdown surface renders through this editor, so
	 * these rules are the one typography definition. */
	/* Long unbreakable tokens (pasted URLs, IDs, long inline strings) wrap
	 * instead of blowing the embedding box wide — a narrow rail column must
	 * never grow a horizontal scrollbar from prose content. Code blocks
	 * keep their own internal overflow-x. */
	.milkdown-host .milkdown-root :global(.ProseMirror) {
		overflow-wrap: anywhere;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h1),
	.milkdown-host .milkdown-root :global(.ProseMirror h2),
	.milkdown-host .milkdown-root :global(.ProseMirror h3),
	.milkdown-host .milkdown-root :global(.ProseMirror h4),
	.milkdown-host .milkdown-root :global(.ProseMirror h5),
	.milkdown-host .milkdown-root :global(.ProseMirror h6) {
		font-family: var(--font-display);
		font-weight: 600;
		letter-spacing: -0.015em;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h1) {
		font-size: 24px;
		line-height: 1.25;
		margin-top: 20px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h2) {
		font-size: 20px;
		line-height: 1.3;
		margin-top: 20px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h3) {
		font-size: 16px;
		line-height: 1.4;
		margin-top: 16px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h4) {
		font-size: 14px;
		margin-top: 14px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h5) {
		font-size: 13.5px;
		margin-top: 14px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror h6) {
		font-size: 12px;
		margin-top: 14px;
	}

	.milkdown-host .milkdown-root :global(.ProseMirror p) {
		line-height: 1.6;
	}
</style>
