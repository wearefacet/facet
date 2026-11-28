// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type {
	BackrefItem,
	BackrefsParams,
	BackrefsResponse,
	DocumentResponse,
	DocumentMeta,
	HistoryParams,
	HistoryResponse,
	ListParams,
	ListResponse,
	MutationRecord,
	RollbackResponse
} from './types.js';
import type { DataSource, DocumentRef } from './interface.js';
import { DataSourceError } from './types.js';
import { parseSidecarEntries } from '../doctype/types.js';

// ── Internal storage type ───────────────────────────────────────────────

interface DocRecord {
	id: string;
	domain: string;
	doc_type: string;
	content: Record<string, unknown>;
	version: number;
	schema_version: number;
	created_at: string;
	updated_at: string;
	/** Mutations recorded for this document (oldest first). */
	mutations: MutationRecord[];
	/** Set when a `delete` mutation has been applied; cleared by `snapshot`. */
	deleted_at: string | null;
	/** Optional display label set explicitly on the record. When absent, `docToMeta` derives one from common display fields (`name`, `title`, …) falling back to id. */
	display_name?: string | null;
	/** Parent document id for child doctypes — mirrored into the response
	 *  meta exactly as the backend's `meta->>'parent_id'` is. */
	parent_id?: string;
}

// ── Internal helpers ─────────────────────────────────────────────────────

// Mirrors the backend's `Helpers.capped_count`: the count query is bounded
// at MAX_COUNT rows starting from `offset`, so `count` is the inclusive
// upper bound of what we know exists (`offset + min(rawCount, MAX_COUNT)`)
// and `more` is true only when that cap was hit — signaling "at least this
// many, possibly more", never "there is a next page". The caller derives
// next-page presence from `data.length === itemsPerPage`.
const COUNT_CAP = 1000;
function cappedCount(rawCount: number, offset: number): { count: number; more: boolean } {
	if (rawCount > COUNT_CAP) {
		return { count: offset + COUNT_CAP, more: true };
	}
	return { count: offset + rawCount, more: false };
}

function now(): string {
	return new Date().toISOString();
}

function clone<T>(v: T): T {
	return JSON.parse(JSON.stringify(v)) as T;
}

/**
 * Deep-merge `patch` over `base` the way the backend `Document::Update`
 * service does. Top-level patch keys replace base keys; nested objects merge
 * recursively; arrays and primitives in the patch replace base values.
 *
 * Returns a fresh object so the stored `DocRecord.content` identity changes
 * (matching the projection rewrite the backend performs).
 */
function deepMergeContent(
	base: Record<string, unknown>,
	patch: Record<string, unknown>
): Record<string, unknown> {
	const merged: Record<string, unknown> = { ...base };
	for (const [key, value] of Object.entries(patch)) {
		const existing = merged[key];
		if (
			existing &&
			typeof existing === 'object' &&
			!Array.isArray(existing) &&
			value &&
			typeof value === 'object' &&
			!Array.isArray(value)
		) {
			merged[key] = deepMergeContent(
				existing as Record<string, unknown>,
				value as Record<string, unknown>
			);
		} else {
			merged[key] = value;
		}
	}
	return merged;
}

/**
 * Compute a JsonDiff-style `{set, unset}` between two shallow objects.
 * Mirrors the backend `Mutation::JsonDiff` shape used by `update` mutations
 * (paths as arrays, `set` entries as `{path, value}`, `unset` as path arrays).
 * Shallow — nested object diffs are not computed; the whole value is replaced.
 */
function computeDiff(
	oldObj: Record<string, unknown>,
	newObj: Record<string, unknown>
): { set: { path: string[]; value: unknown }[]; unset: string[][] } {
	const set: { path: string[]; value: unknown }[] = [];
	const unset: string[][] = [];
	const seen = new Set<string>();
	for (const [k, v] of Object.entries(newObj)) {
		seen.add(k);
		const old = oldObj[k];
		if (!(k in oldObj) || JSON.stringify(old) !== JSON.stringify(v)) {
			set.push({ path: [k], value: v });
		}
	}
	for (const k of Object.keys(oldObj)) {
		if (!seen.has(k)) unset.push([k]);
	}
	return { set, unset };
}

/**
 * Best-effort past-tense inflection for an action name, mirroring the backend
 * `Facet::Util::PastTenseInflector`. Covers the common regular cases
 * (and a few irregulars) so mock-driven stories surface a believable
 * `meta.origin` (e.g. `promote` → `promoted`, `convert` → `converted`).
 */
function pastTense(verb: string): string {
	const irregular: Record<string, string> = {
		be: 'been',
		get: 'gotten',
		write: 'written',
		take: 'taken',
		send: 'sent',
		build: 'built',
		have: 'had',
		find: 'found'
	};
	if (irregular[verb]) return irregular[verb];

	const v = verb.toLowerCase();
	if (/[^aeiou]y$/.test(v)) return v.slice(0, -1) + 'ied';
	if (v.endsWith('e')) return v + 'd';
	// Monosyllabic CVC (consonant-vowel-consonant) → double final consonant
	if (v.length >= 3 && /^[^aeiou][aeiou][^aeiouwxy]$/.test(v)) return v + v.slice(-1) + 'ed';
	return v + 'ed';
}

// Monotonic counter + random suffix — good enough for mock ULIDs (sortable).
let _mutationCounter = 0;
function mockUlid(): string {
	_mutationCounter += 1;
	const ts = Date.now().toString(36).toUpperCase().padStart(10, '0');
	const rnd = Math.random().toString(36).slice(2, 14).toUpperCase().padStart(12, '0');
	return `${ts}${rnd}${_mutationCounter.toString(36).toUpperCase().padStart(4, '0')}`;
}

function makeDoc(
	domain: string,
	doc_type: string,
	id: string,
	content: Record<string, unknown>,
	created_at: string = now()
): DocRecord {
	return {
		id,
		domain,
		doc_type,
		content: clone(content),
		version: 1,
		schema_version: 1,
		created_at,
		updated_at: created_at,
		mutations: [],
		deleted_at: null
	};
}

/** Build a mutation record for a doc. */
function makeMutation(
	doc: DocRecord,
	action: MutationRecord['action'],
	actionerId: string,
	arguments_: Record<string, unknown>,
	cause: { kind: MutationRecord['cause_kind']; event?: string | null } | null = null,
	emittedAt: string = now()
): MutationRecord {
	const idx = doc.mutations.length + 1;
	const id = mockUlid();
	return {
		id,
		domain: doc.domain,
		doc_type: doc.doc_type,
		doc_id: doc.id,
		idx,
		action,
		actioner_id: actionerId,
		arguments: clone(arguments_),
		channel: 'session',
		cause_kind: cause?.kind ?? 'request',
		cause_event: cause?.event ?? null,
		cause_trace: id,
		emitted_at: emittedAt
	};
}

function compareValues(a: unknown, b: unknown): number {
	if (a == null && b == null) return 0;
	if (a == null) return -1;
	if (b == null) return 1;
	if (typeof a === 'string' && typeof b === 'string') return a.localeCompare(b);
	if (typeof a === 'number' && typeof b === 'number') return a - b;
	return String(a).localeCompare(String(b));
}

function compareScalar(a: unknown, b: unknown): number | undefined {
	if (a == null || b == null) return undefined;
	if (typeof a === 'number' && typeof b === 'number') return a - b;
	// Datetime / date strings (ISO-8601) sort lexicographically; fall back to
	// numeric coercion for money stored as numeric strings, then string compare.
	const asNumA = typeof a === 'string' ? Number(a) : NaN;
	const asNumB = typeof b === 'string' ? Number(b) : NaN;
	if (!Number.isNaN(asNumA) && !Number.isNaN(asNumB) && asNumA !== 0 && asNumB !== 0) {
		return asNumA - asNumB;
	}
	const sa = String(a);
	const sb = String(b);
	return sa < sb ? -1 : sa > sb ? 1 : 0;
}

function matchesFilter(value: unknown, filterValue: unknown, operator: string): boolean {
	// Money-aware comparisons: a stored `{ value, currency }` object compares
	// on its numeric `value` member; a `"<CCY> <amount>"` filter value adds a
	// currency predicate, and the bare `currency` operator matches the stored
	// ticker — mirroring the backend `Util::MoneyFilterValue` /
	// `Util::FilterClauses.money_clauses` (eq/ne-free family, gt/gte/lt/lte/
	// between, currency; other operators fall through to the scalar path,
	// which the backend skips for money).
	const moneyVerdict = matchMoney(value, filterValue, operator);
	if (moneyVerdict !== null) return moneyVerdict;
	if (operator === 'currency') return false; // non-money stored value never matches a ticker
	switch (operator) {
		case 'eq':
		case '':
			return matchesEquality(value, filterValue);
		case 'ne':
			return !matchesEquality(value, filterValue);
		case 'gt':
		case 'gte':
		case 'lt':
		case 'lte': {
			const cmp = compareScalar(value, filterValue);
			if (cmp === undefined) return false;
			return operator === 'gt'
				? cmp > 0
				: operator === 'gte'
					? cmp >= 0
					: operator === 'lt'
						? cmp < 0
						: cmp <= 0;
		}
		case 'between': {
			if (!Array.isArray(filterValue) || filterValue.length !== 2) return true;
			const lo = compareScalar(value, filterValue[0]);
			const hi = compareScalar(value, filterValue[1]);
			if (lo === undefined || hi === undefined) return false;
			return lo >= 0 && hi <= 0;
		}
		case 'in': {
			// Array membership — mirrors `Util::FilterSet#build_in_clause`: a
			// non-array or empty array degrades to an always-false clause, and
			// entries compare against the stored scalar (enum keys are text).
			if (!Array.isArray(filterValue) || filterValue.length === 0) return false;
			return filterValue.includes(value);
		}
		case 'match':
			return (
				value != null &&
				filterValue != null &&
				String(value).toLowerCase().includes(String(filterValue).toLowerCase())
			);
		default:
			return true;
	}
}

/**
 * Equality with the boolean wire form: the filter chips and the kanban
 * boolean lanes emit the strings `'true'` / `'false'` (the same form the
 * backend text path parses against `content->>'field'`), so a stored
 * boolean compares against the coerced value instead of failing the strict
 * identity check.
 */
function matchesEquality(value: unknown, filterValue: unknown): boolean {
	if (typeof value === 'boolean' && (filterValue === 'true' || filterValue === 'false')) {
		return value === (filterValue === 'true');
	}
	return value === filterValue;
}

// ── Money filter evaluation (mock counterpart of Util::MoneyFilterValue) ──

/** Stored money shape: `{ value, currency }` with a decimal value. */
function asMoney(v: unknown): { amount: number; currency: string } | null {
	if (v == null || typeof v !== 'object' || Array.isArray(v)) return null;
	const rec = v as Record<string, unknown>;
	if (typeof rec['currency'] !== 'string' || rec['currency'].length === 0) return null;
	const raw = rec['value'];
	const amount = typeof raw === 'number' ? raw : typeof raw === 'string' ? Number(raw) : NaN;
	if (!Number.isFinite(amount)) return null;
	return { amount, currency: rec['currency'] };
}

/**
 * Parsed money filter value: `"<CCY> <amount>"` (currency predicate) or a
 * bare amount (any currency). Returns null for non-parseable input so the
 * caller falls back to the scalar comparison path.
 */
function asMoneyFilter(raw: unknown): { amount: number; currency: string | null } | null {
	if (typeof raw === 'number') {
		return Number.isFinite(raw) ? { amount: raw, currency: null } : null;
	}
	if (typeof raw !== 'string') return null;
	const trimmed = raw.trim();
	if (trimmed.length === 0) return null;
	// Optional "<CCY> " prefix: three uppercase letters, whitespace, amount.
	const m = trimmed.match(/^([A-Z]{3})\s+(.+)$/);
	if (m) {
		const amount = Number(m[2]);
		return Number.isFinite(amount) ? { amount, currency: m[1] } : null;
	}
	// A bare amount only — a non-numeric string is not a money filter (it
	// would otherwise compare as `NaN` and reject every stored row).
	if (!/^-?\d+(\.\d+)?$/.test(trimmed)) return null;
	const amount = Number(trimmed);
	return Number.isFinite(amount) ? { amount, currency: null } : null;
}

/**
 * Money-aware filter evaluation. Returns null when the pair is not a money
 * comparison (stored value not money-shaped, operator not numeric, or the
 * filter value unparseable) — the caller then falls back to the scalar
 * path. A currency-prefix mismatch is a verdict of false, not a fallback.
 */
function matchMoney(stored: unknown, filterValue: unknown, operator: string): boolean | null {
	const doc = asMoney(stored);
	if (!doc) return null;
	const parse = (raw: unknown) => asMoneyFilter(raw);
	const currencyOk = (f: { currency: string | null }): boolean =>
		f.currency === null || f.currency === doc.currency;
	switch (operator) {
		case 'eq': {
			const f = parse(filterValue);
			if (!f) return null;
			return currencyOk(f) && doc.amount === f.amount;
		}
		case 'gt':
		case 'gte':
		case 'lt':
		case 'lte': {
			const f = parse(filterValue);
			if (!f) return null;
			if (!currencyOk(f)) return false;
			const cmp = doc.amount - f.amount;
			return operator === 'gt'
				? cmp > 0
				: operator === 'gte'
					? cmp >= 0
					: operator === 'lt'
						? cmp < 0
						: cmp <= 0;
		}
		case 'between': {
			if (!Array.isArray(filterValue) || filterValue.length !== 2) return null;
			const lo = parse(filterValue[0]);
			const hi = parse(filterValue[1]);
			if (!lo || !hi) return null;
			if (!currencyOk(lo) || !currencyOk(hi)) return false;
			return doc.amount >= lo.amount && doc.amount <= hi.amount;
		}
		case 'currency': {
			// The `__currency` operator filters on the stored ticker alone —
			// the same text equality the backend money clause compiles
			// (`content#>>'{field,currency}' = $n`). A blank value seeds the
			// chip and matches nothing, like the backend's `= ''`.
			const ticker = String(filterValue ?? '').trim();
			return ticker.length > 0 ? doc.currency === ticker : false;
		}
		default:
			return null;
	}
}

function parseFilterKey(key: string): [string, string] {
	const parts = key.split('__');
	if (
		parts.length >= 2 &&
		['eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'match', 'between', 'in', 'currency'].includes(
			parts[parts.length - 1]
		)
	) {
		const operator = parts.pop()!;
		return [parts.join('__'), operator];
	}
	return [key, 'eq'];
}

const TOP_LEVEL_FIELDS = new Set(['id', 'created_at', 'updated_at']);

function getFieldValue(doc: DocRecord, field: string): unknown {
	if (TOP_LEVEL_FIELDS.has(field)) {
		return (doc as unknown as Record<string, unknown>)[field];
	}
	return doc.content[field];
}

// ── Transform helpers (from internal DocRecord to API shapes) ───────────

function docToMeta(doc: DocRecord): DocumentMeta {
	return {
		id: doc.id,
		mid: doc.id,
		domain: doc.domain,
		doc_type: doc.doc_type,
		version: doc.version,
		schema_version: doc.schema_version,
		display_name: doc.display_name ?? deriveDisplayName(doc),
		...(doc.parent_id ? { parent_id: doc.parent_id } : {}),
		created_at: doc.created_at,
		updated_at: doc.updated_at
	};
}

/** Pick a label from common display fields for mock-driven stories. */
function deriveDisplayName(doc: DocRecord): string {
	const keys = ['display_name', 'name', 'title', 'label'] as const;
	for (const k of keys) {
		const v = doc.content[k];
		if (typeof v === 'string' && v.length > 0) return v;
	}
	return doc.id;
}

function docToListItem<T = Record<string, unknown>>(
	doc: DocRecord
): { data: T; meta: DocumentMeta } {
	return {
		data: clone(doc.content) as T,
		meta: docToMeta(doc)
	};
}

function docToResponse<T = Record<string, unknown>>(doc: DocRecord): DocumentResponse<T> {
	return {
		data: clone(doc.content) as T,
		meta: docToMeta(doc)
	};
}

// ── Shared filtering / sorting / pagination ─────────────────────────────

function applyFilters(
	items: DocRecord[],
	filters?: Record<string, unknown>,
	searchTemplate?: string
): DocRecord[] {
	if (!filters || Object.keys(filters).length === 0) return items;

	return items.filter((doc) => {
		for (const [rawKey, filterVal] of Object.entries(filters)) {
			if (rawKey === 'search') {
				// The bare `search` key is the backend's search operator. Under the
				// D3 ruling the `search` template is the searchability flag: the
				// mock approximates the corpus by substituting the template's
				// `{{ field }}` tokens with the doc's stored values. A doctype with
				// no template matches nothing — the same rule as `search__*` keys.
				const q = String(filterVal ?? '').toLowerCase();
				if (!q) continue;
				if (!searchTemplate) return false;
				if (!templateCorpus(doc, searchTemplate).includes(q)) return false;
			} else if (rawKey.startsWith('search__')) {
				// Suffixed `search__*` keys are not productions of the filter
				// grammar (`search` is an operator-keyword, not a column). The
				// mock mirrors the backend: the filter matches nothing.
				return false;
			} else if (rawKey === 'parent_id__eq') {
				// Reserved parent-scope key — the backend drives the same
				// `meta->>'parent_id'` clause the nested child route uses.
				// The mock compares the record's mirrored `parent_id` verbatim,
				// so fixtures must use consistent id forms.
				if (doc.parent_id !== String(filterVal ?? '')) return false;
			} else {
				const [field, operator] = parseFilterKey(rawKey);
				const value = getFieldValue(doc, field);
				if (!matchesFilter(value, filterVal, operator)) return false;
			}
		}
		return true;
	});
}

/**
 * Approximates the backend's search corpus: the template's `{{ field }}`
 * tokens in order, each replaced with the doc's stored value, joined with
 * spaces. Case handling matches the rest of the mock filter path.
 */
function templateCorpus(doc: DocRecord, template: string): string {
	const fields = [...template.matchAll(/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/g)].map((mtch) => mtch[1]);
	return fields
		.map((field) => String(doc.content[field] ?? ''))
		.join(' ')
		.toLowerCase();
}

/**
 * The doctype's `search` template, or `undefined` when the definition
 * declares none (or an empty one) — the D3 rule that makes the doctype
 * unsearchable.
 */
function searchTemplateFor(store: {
	domain: string;
	docType: string;
	definitions?: Map<string, Record<string, unknown>>;
}): string | undefined {
	const raw = store.definitions?.get(`${store.domain}.${store.docType}`);
	const template = raw?.['search'];
	return typeof template === 'string' && template.trim().length > 0 ? template : undefined;
}

function applySort(items: DocRecord[], sort?: string[]): DocRecord[] {
	if (!sort || sort.length === 0) return items;

	const result = [...items];
	result.sort((a, b) => {
		for (const field of sort) {
			const desc = field.startsWith('-');
			const key = desc ? field.slice(1) : field;
			const aVal = getFieldValue(a, key);
			const bVal = getFieldValue(b, key);
			const cmp = compareValues(aVal, bVal);
			if (cmp !== 0) return desc ? -cmp : cmp;
		}
		return 0;
	});
	return result;
}

function getMutationField(m: MutationRecord, field: string): unknown {
	if (field === 'id') return m.id;
	if (field === 'idx') return m.idx;
	if (field === 'action') return m.action;
	if (field === 'actioner_id') return m.actioner_id;
	if (field === 'emitted_at') return m.emitted_at;
	if (field === 'doc_id') return m.doc_id;
	return (m as unknown as Record<string, unknown>)[field];
}

function applySortToMutations(items: MutationRecord[], sort?: string[]): MutationRecord[] {
	if (!sort || sort.length === 0) return items;
	const result = [...items];
	result.sort((a, b) => {
		for (const field of sort) {
			const desc = field.startsWith('-');
			const key = desc ? field.slice(1) : field;
			const aVal = getMutationField(a, key);
			const bVal = getMutationField(b, key);
			const cmp = compareValues(aVal, bVal);
			if (cmp !== 0) return desc ? -cmp : cmp;
		}
		return 0;
	});
	return result;
}

function paginate<T = Record<string, unknown>>(
	items: DocRecord[],
	page: number = 1,
	itemsPerPage: number = 100,
	_aggregate?: 'count'
): ListResponse<T> {
	const offset = (page - 1) * itemsPerPage;
	const paged = items.slice(offset, offset + itemsPerPage);
	// Count from the offset up to the 1000-row cap, mirroring the backend.
	const tail = items.slice(offset);
	const { count, more } = cappedCount(tail.length, offset);
	return {
		data: paged.map((d) => docToListItem<T>(d)),
		meta: { count, more }
	};
}

// Count mode: reports the full filtered total capped at 1000 from offset 0
// (the backend ignores page/items when `aggregate=count`). Used by sidebar
// nav badges and other count-only consumers — no row content is read.
function countOnly<T = Record<string, unknown>>(items: DocRecord[]): ListResponse<T> {
	const { count, more } = cappedCount(items.length, 0);
	return { data: [], meta: { count, more } };
}

/** Aggregates that operate on a declared field — mirrors the backend's
 *  `List::Aggregate.FIELD_AGGREGATES` (`count` runs field-free). */
const FIELD_AGGREGATES = new Set(['sum', 'avg', 'min', 'max']);

/**
 * Field-aggregate mode — mirrors the backend contract
 * (`src/document/routes.cr` → `AggregateResult`): the body is
 * `{ data: { value }, meta: { count, more: false } }`, where `value` is a
 * JSON number for plain numerics, `null` for `avg`/`min`/`max` over an empty
 * set, and a `{ ticker => amount }` bag of decimal strings for `money`
 * fields (grouped per stored currency). The mock infers the kind from the
 * stored values — numbers aggregate plainly, `{ value, currency }` objects
 * aggregate as money — since it keeps no field-type registry.
 *
 * Returns `null` when the params are not a field-aggregate call, so the
 * caller falls through to the normal pagination path.
 */
function fieldAggregate<T = Record<string, unknown>>(
	items: DocRecord[],
	params: ListParams
): ListResponse<T> | null {
	const aggregate = params.aggregate;
	const field = params.field;
	if (!aggregate || !FIELD_AGGREGATES.has(aggregate) || !field) return null;

	const plain: number[] = [];
	const money = new Map<string, number[]>();
	for (const doc of items) {
		const v = doc.content[field];
		if (v == null) continue;
		if (typeof v === 'number' && Number.isFinite(v)) {
			plain.push(v);
		} else if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))) {
			plain.push(Number(v));
		} else if (typeof v === 'object' && 'value' in (v as Record<string, unknown>)) {
			const amount = Number((v as Record<string, unknown>).value);
			if (!Number.isFinite(amount)) continue;
			const ticker = String((v as Record<string, unknown>).currency ?? 'USD');
			const bucket = money.get(ticker) ?? [];
			bucket.push(amount);
			money.set(ticker, bucket);
		}
	}

	const combine = (values: number[]): number | null => {
		if (values.length === 0) return null;
		switch (aggregate) {
			case 'sum':
				return values.reduce((a, b) => a + b, 0);
			case 'avg':
				return values.reduce((a, b) => a + b, 0) / values.length;
			case 'min':
				return Math.min(...values);
			case 'max':
				return Math.max(...values);
			default:
				return null;
		}
	};

	// Money objects win when both shapes appear — one field cannot honestly
	// hold both, and the bag keeps every currency's aggregate separate.
	let value: unknown;
	let count: number;
	if (money.size > 0) {
		const bag: Record<string, string> = {};
		for (const [ticker, amounts] of money) {
			const result = combine(amounts);
			if (result != null) bag[ticker] = String(result);
		}
		value = bag;
		count = [...money.values()].reduce((a, b) => a + b.length, 0);
	} else {
		value = combine(plain);
		count = plain.length;
	}
	return {
		data: { value },
		meta: { count, more: false }
	} as unknown as ListResponse<T>;
}

// ── Mock DocumentRef ────────────────────────────────────────────────────

class MockDocumentRef<T = Record<string, unknown>> implements DocumentRef<T> {
	constructor(
		private readonly store: MockDataSource<T>,
		private readonly docId: string
	) {}

	show(): Promise<DocumentResponse<T>> {
		const doc = this.store.resolveDoc(this.docId);
		if (!doc) {
			return Promise.reject(new Error(`Document "${this.docId}" not found`));
		}
		if (doc.deleted_at) {
			// Mirrors the backend's `Document::Read` tombstone contract: a `410`
			// Gone whose body carries the surviving label + deletion timestamp,
			// never the content. Lets the QuickView render its deleted state.
			return Promise.reject(
				new DataSourceError(410, `Document "${this.docId}" was deleted`, undefined, {
					deleted: true,
					deleted_at: doc.deleted_at,
					display_name: doc.display_name ?? deriveDisplayName(doc)
				})
			);
		}
		return Promise.resolve(docToResponse<T>(doc));
	}

	update(diff: unknown): Promise<DocumentResponse<T>> {
		return this.store.performUpdate<T>(this.docId, diff);
	}

	delete(): Promise<void> {
		return this.store.performDelete(this.docId);
	}

	action(actionName: string, args?: Record<string, unknown>): Promise<DocumentResponse<T>> {
		return this.store.performAction<T>(this.docId, actionName, args);
	}

	invalidate(): void {
		// The mock reads straight from the store — no cache to drop. The method
		// exists so hosts can invalidate unconditionally after out-of-band
		// mutations without knowing which driver they hold.
	}

	history(params?: HistoryParams): Promise<HistoryResponse> {
		return this.store.performHistoryForDoc(this.docId, params);
	}

	backrefs(params?: BackrefsParams): Promise<BackrefsResponse> {
		return this.store.performBackrefsForDoc(this.docId, params);
	}

	rollback(mutationId: string): Promise<RollbackResponse> {
		return this.store.performRollback(this.docId, mutationId);
	}

	restore(): Promise<RollbackResponse> {
		return this.store.performRestore(this.docId);
	}

	children<C = Record<string, unknown>>(relName: string): DataSource<C> {
		return new MockChildDataSource<C>(
			this.store as unknown as MockDataSource<C>,
			this.docId,
			relName
		);
	}

	sidecars<C = Record<string, unknown>>(segment: string): DataSource<C> {
		const store = this.store as unknown as MockDataSource<Record<string, unknown>>;
		const hostQualified = `${store.domain}.${store.docType}`;
		const raw = store.definitions?.get(hostQualified);
		const entry = raw
			? parseSidecarEntries(raw['sidecars'] as Record<string, unknown> | undefined).find(
					(s) => s.key === segment
				)
			: undefined;
		return new MockSidecarDataSource<C>(
			store.docs,
			entry?.doctype ?? null,
			entry?.column ?? null,
			`${hostQualified}.${this.docId}`,
			this.docId,
			store.definitions,
			entry ? undefined : new DataSourceError(404, `Unknown sidecar '${segment}'`)
		);
	}
}

// ── Mock child DataSource ───────────────────────────────────────────────

class MockChildDataSource<T = Record<string, unknown>> implements DataSource<T> {
	private readonly prefix: string;

	constructor(
		private readonly store: MockDataSource<T>,
		parentId: string,
		private readonly relName: string
	) {
		this.prefix = `${parentId}.${relName}`;
	}

	private childId(id: string): string {
		return `${this.prefix}.${id}`;
	}

	list(params?: ListParams): Promise<ListResponse<T>> {
		const all = Array.from(this.store.docs.values()).filter((d) =>
			d.id.startsWith(this.prefix + '.')
		);
		const filtered = applyFilters(all, params?.filters, searchTemplateFor(this.store));
		const sorted = applySort(filtered, params?.sort);
		const aggregated = fieldAggregate<T>(sorted, params ?? {});
		if (aggregated) return Promise.resolve(aggregated);
		if (params?.aggregate === 'count') return Promise.resolve(countOnly<T>(sorted));
		return Promise.resolve(paginate<T>(sorted, params?.page, params?.items));
	}

	create(content: T): Promise<DocumentResponse<T>> {
		const id = crypto.randomUUID();
		const fullId = this.childId(id);
		const now_ = now();
		const doc = makeDoc(
			this.store.domain,
			this.store.docType,
			fullId,
			content as unknown as Record<string, unknown>,
			now_
		);
		doc.mutations.push(
			makeMutation(
				doc,
				'create',
				'system',
				{
					content: clone(content as unknown as Record<string, unknown>)
				},
				null,
				now_
			)
		);
		this.store.docs.set(fullId, doc);
		return Promise.resolve(docToResponse<T>(doc));
	}

	// `list()` returns full child ids (e.g. `crm.Deal.collection_view.timeline`),
	// so `doc()` must accept them as-is — mirroring the real backend's
	// `ChildScopedDataSource.doc`, which does not re-prefix. Re-prefixing here
	// would double the prefix and target a non-existent document.
	doc(id: string): DocumentRef<T> {
		return new MockDocumentRef<T>(this.store, id);
	}
}

// ── Mock sidecar DataSource ───────────────────────────────────────────

/**
 * Collection of sidecar records scoped to one host document.
 *
 * Unlike {@link MockChildDataSource} — which filters children by the
 * `{parent}.{rel}.` id prefix — sidecar records are independent documents of
 * the sidecar doctype whose {@link SidecarDef.column} reference column points
 * back at the host. The host match forgives both reference forms: the fully
 * qualified ref (`crm.Deal.crm.Deal.1`) and the bare host id (`crm.Deal.1`),
 * because fixtures and seeds use both.
 *
 * Document-level operations (`doc(id)` → show/update/delete) delegate to an
 * internal `MockDataSource` for the sidecar doctype sharing the same docs
 * map, so sidecar ids resolve like any other document id.
 */
class MockSidecarDataSource<T = Record<string, unknown>> implements DataSource<T> {
	private readonly inner: MockDataSource<Record<string, unknown>> | null;
	private readonly error?: DataSourceError;

	constructor(
		docs: Map<string, unknown>,
		sidecarQualified: string | null,
		private readonly column: string | null,
		private readonly hostQualifiedRef: string,
		private readonly hostDocId: string,
		definitions?: Map<string, Record<string, unknown>>,
		error?: DataSourceError
	) {
		if (error || !sidecarQualified) {
			this.error = error ?? new DataSourceError(500, 'Unknown sidecar');
			this.inner = null;
			return;
		}
		const dot = sidecarQualified.indexOf('.');
		const domain = sidecarQualified.slice(0, dot);
		const docType = sidecarQualified.slice(dot + 1);
		// One store per sidecar doctype sharing the driver's docs map — `doc(id)`
		// and mutations resolve like any other document (ids are bare UUIDs).
		// The definitions ride along so the search-template rule (D3) applies
		// to sidecar lists exactly like main ones.
		this.inner = new MockDataSource<Record<string, unknown>>(
			domain,
			docType,
			[],
			docs,
			definitions
		);
	}

	list(params?: ListParams): Promise<ListResponse<T>> {
		const store = this.inner;
		const column = this.column;
		if (this.error || !store || column == null) return Promise.reject(this.error);
		// The dual reference match is done inline (not via a `__eq` filter) so a
		// row matches either reference form; remaining filters, sorting, and
		// pagination reuse the same helpers as the main list path.
		const includeDeleted = params?.includeDeleted === true;
		const scoped = Array.from(store.docs.values()).filter(
			(d) =>
				d.domain === store.domain &&
				d.doc_type === store.docType &&
				(includeDeleted ? d.deleted_at != null : d.deleted_at == null)
		);
		const hostScoped = scoped.filter((d) => {
			const v = d.content[column];
			return v === this.hostQualifiedRef || v === this.hostDocId;
		});
		const filtered = applyFilters(hostScoped, params?.filters, searchTemplateFor(store));
		const sorted = applySort(filtered, params?.sort);
		const aggregated = fieldAggregate<T>(sorted, params ?? {});
		if (aggregated) return Promise.resolve(aggregated);
		if (params?.aggregate === 'count') return Promise.resolve(countOnly<T>(sorted));
		return Promise.resolve(paginate<T>(sorted, params?.page, params?.items));
	}

	create(content: T): Promise<DocumentResponse<T>> {
		const store = this.inner;
		const column = this.column;
		if (this.error || !store || column == null) return Promise.reject(this.error);
		const body = content as unknown as Record<string, unknown>;
		if (body[column] !== undefined) {
			return Promise.reject(
				new DataSourceError(
					400,
					`The '${column}' field is set by the route and must not be supplied in the body`
				)
			);
		}
		return store.create({ ...body, [column]: this.hostQualifiedRef } as Record<
			string,
			unknown
		>) as Promise<DocumentResponse<T>>;
	}

	doc(id: string): DocumentRef<T> {
		const store = this.inner;
		if (this.error || !store) throw this.error;
		return store.doc(id) as unknown as DocumentRef<T>;
	}
}

// ── Main export ──────────────────────────────────────────────────────────

/**
 * In-memory DataSource that produces the same `{ data, meta }` response
 * shapes as the real Facet API.
 *
 * Perfect for Storybook stories and unit tests — no network calls,
 * returns Promises for interface compliance.
 *
 * Supports filtering (`__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`),
 * sorting, pagination (`count`/`more`), child navigation, basic CRUD,
 * and custom action registration via {@link MockDataSource.onAction}.
 * No schema validation or Lua scripts.
 *
 * @example
 * ```ts
 * const ds = new MockDataSource("hr", "Employee", [
 *   { id: "e1", name: "Alice", status: "active" },
 *   { id: "e2", name: "Bob",   status: "inactive" },
 * ]);
 *
 * const list = await ds.list({ filters: { status__eq: "active" } });
 * // => { data: [{ data: { name: "Alice", status: "active" }, meta: { id: "e1", mid: "e1", domain: "hr", doc_type: "Employee", version: 1, schema_version: 1, created_at: "...", updated_at: "..." } }], meta: { count: 1, more: false } }
 *
 * const doc = await ds.doc("e1").show();
 * // => { data: { name: "Alice", status: "active" }, meta: { id: "e1", mid: "e1", domain: "hr", doc_type: "Employee", version: 1, schema_version: 1, ... } }
 * // doc => { data: { name: "Alice", status: "active" }, meta: { id: "e1", ... } }
 * ```
 */
export class MockDataSource<T = Record<string, unknown>> implements DataSource<T> {
	/** @internal */
	readonly docs: Map<string, DocRecord>;
	private actionHandlers: Map<
		string,
		(doc: DocRecord, args: Record<string, unknown>) => Record<string, unknown>
	> = new Map();
	private backrefRows: Map<string, BackrefItem[]> = new Map();

	/**
	 * Spy hook: records every `list()` invocation's params (shallow-cloned).
	 * Tests and stories can read or reset this array to assert that a
	 * ReferencePicker (or other consumer) delegates search to the backend
	 * `?search=` filter rather than fetching all docs client-side.
	 *
	 * Reset between assertions with `listCalls.length = 0`.
	 */
	readonly listCalls: ListParams[] = [];

	/**
	 * @param domain   The domain name (e.g. "hr")
	 * @param docType  The doctype name (e.g. "Employee")
	 * @param initialData  Seed documents. Each item must have at least `id`;
	 *                     all other keys are treated as content fields.
	 * @param sharedDocs  Optional shared document store. When provided (e.g.
	 *                    from {@link MockDataDriver}), all doctypes across all
	 *                    domains share the same underlying map — enabling
	 *                    cross-doctype relationships in tests.
	 * @param definitions  Optional doctype definition registry keyed by
	 *                    `"{domain}.{doctype}"` (shared from
	 *                    {@link MockDataDriver.doctypeDefinitions}). Used by
	 *                    `sidecars()` to resolve the sidecar declaration for
	 *                    this doctype.
	 */
	constructor(
		public readonly domain: string,
		public readonly docType: string,
		initialData: T[] = [],
		sharedDocs?: Map<string, unknown>,
		public readonly definitions?: Map<string, Record<string, unknown>>
	) {
		this.docs = (sharedDocs as Map<string, DocRecord>) ?? new Map<string, DocRecord>();
		const now_ = now();
		for (const item of initialData) {
			const itemRecord = item as unknown as Record<string, unknown>;
			const id = String(itemRecord.id ?? crypto.randomUUID());
			const { id: _id, ...content } = itemRecord;
			const created_at = now_; // seeded docs share a base timestamp
			const rec = makeDoc(domain, docType, id, content, created_at);
			rec.mutations.push(
				makeMutation(rec, 'create', 'system:seed', { content: clone(content) }, null, created_at)
			);
			this.docs.set(id, rec);
		}
	}

	/**
	 * Register a custom action handler for testing.
	 * The function receives the current document record and args, returns
	 * the new content (which is merged back into the document).
	 */
	onAction(
		actionName: string,
		handler: (doc: DocRecord, args: Record<string, unknown>) => Record<string, unknown>
	): void {
		this.actionHandlers.set(actionName, handler);
	}

	/**
	 * Register stub backlink rows for one document id (testing/stories).
	 *
	 * The backend derives backrefs from the `links` column; the mock keeps no
	 * link extraction, so stories seed the rows a document should report.
	 */
	onBackrefs(docId: string, items: BackrefItem[]): void {
		this.backrefRows.set(docId, items);
	}

	// ── Collection-level ────────────────────────────────────────────────

	list(params?: ListParams): Promise<ListResponse<T>> {
		// Record a spy snapshot of the call so test code can assert backend
		// delegation (e.g. `?search=` trigram filter, `items: 25` cap).
		this.listCalls.push(params ? { ...params, filters: { ...params.filters } } : {});
		// When using a shared store (via MockDataDriver), scope results to
		// this domain and doctype. Standalone MockDataSource has no other
		// doctypes' data to worry about, so the filter is always correct.
		// `includeDeleted` swaps the tombstone predicate — trash listing
		// returns deleted_at IS NOT NULL rows instead of live rows.
		const includeDeleted = params?.includeDeleted === true;
		const scoped = Array.from(this.docs.values()).filter(
			(d) =>
				d.domain === this.domain &&
				d.doc_type === this.docType &&
				(includeDeleted ? d.deleted_at != null : d.deleted_at == null)
		);
		const filtered = applyFilters(scoped, params?.filters, searchTemplateFor(this));
		const sorted = applySort(filtered, params?.sort);
		const aggregated = fieldAggregate<T>(sorted, params ?? {});
		if (aggregated) return Promise.resolve(aggregated);
		if (params?.aggregate === 'count') return Promise.resolve(countOnly<T>(sorted));
		return Promise.resolve(paginate<T>(sorted, params?.page, params?.items));
	}

	create(content: T): Promise<DocumentResponse<T>> {
		const id = crypto.randomUUID();
		const now_ = now();
		const doc = makeDoc(
			this.domain,
			this.docType,
			id,
			content as unknown as Record<string, unknown>,
			now_
		);
		doc.mutations.push(
			makeMutation(
				doc,
				'create',
				'system',
				{
					content: clone(content as unknown as Record<string, unknown>)
				},
				null,
				now_
			)
		);
		this.docs.set(id, doc);
		return Promise.resolve(docToResponse<T>(doc));
	}

	// ── Document-level (via ref) ────────────────────────────────────────

	doc(id: string): DocumentRef<T> {
		return new MockDocumentRef<T>(this, id);
	}

	/**
	 * Resolve a document record by id — the mock counterpart of the backend
	 * route-layer resolution (`HTTP::Helpers.canonical_doc_id`, which mirrors
	 * `Document::DisplayName::DatabaseReferenceResolver`).
	 *
	 * A reference value is stored fully qualified (`iam.Account.account_recruiter_kim`),
	 * but the referenced projection's id may be either the qualified form (seed
	 * fixtures like `crm.Company.1`) or the bare opaque id (`account_recruiter_kim`
	 * for `iam.Account`). Try the exact id first, then fall back to the id with
	 * the `{domain}.{doctype}.` prefix stripped.
	 */
	/** @internal */
	resolveDoc(id: string): DocRecord | undefined {
		const exact = this.docs.get(id);
		if (exact) return exact;
		const prefix = `${this.domain}.${this.docType}.`;
		if (id.startsWith(prefix)) {
			return this.docs.get(id.slice(prefix.length));
		}
		return undefined;
	}

	// ── Internal mutation methods (called by MockDocumentRef) ───────────

	/** @internal */
	performUpdate<TU = Record<string, unknown>>(
		id: string,
		diff: unknown
	): Promise<DocumentResponse<TU>> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}

		// The `Document::Update` backend service parses the PATCH body as the
		// partial content directly and deep-merges top-level keys over the
		// existing projection. The mock mirrors that one semantic so that an
		// envelope-shaped body (e.g. `{ set: [{ op, path, value }] }`) fails
		// against the mock the same way it would fail against the real API.
		const patch = deepMergeContent(doc.content, diff as Record<string, unknown>);
		doc.content = patch;

		doc.version += 1;
		doc.updated_at = now();
		doc.mutations.push(makeMutation(doc, 'update', 'system', { diff: clone(diff) }));

		return Promise.resolve(docToResponse<TU>(doc));
	}

	/** @internal */
	performDelete(id: string): Promise<void> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}
		const ts = now();
		doc.deleted_at = ts;
		doc.updated_at = ts;
		doc.mutations.push(makeMutation(doc, 'delete', 'system', {}, null));
		return Promise.resolve();
	}

	/** @internal */
	performAction<TU = Record<string, unknown>>(
		id: string,
		actionName: string,
		args?: Record<string, unknown>
	): Promise<DocumentResponse<TU>> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}

		const handler = this.actionHandlers.get(actionName);
		if (!handler) {
			return Promise.reject(
				new Error(`Unknown action "${actionName}" on ${this.domain}.${this.docType}`)
			);
		}

		const previous = clone(doc.content);
		const newContent = handler(doc, args ?? {});
		doc.content = newContent;
		doc.version += 1;
		doc.updated_at = now();

		// Mirror the backend: an action produces an `update` mutation whose
		// `arguments.diff` is the JsonDiff of the document content before vs.
		// after the action, and whose cause (kind=action, event=origin) is the
		// action's resolved event name (a best-effort past-tense form for the mock).
		const diff = computeDiff(previous, newContent);
		const origin = pastTense(actionName);
		doc.mutations.push(
			makeMutation(doc, 'update', 'system', { diff }, { kind: 'action', event: origin })
		);

		return Promise.resolve(docToResponse<TU>(doc));
	}

	/** @internal */
	performHistoryForDoc(id: string, params?: HistoryParams): Promise<HistoryResponse> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}
		let items = [...doc.mutations];
		// Default newest-first, like the backend.
		if (params?.sort && params.sort.length > 0) {
			items = applySortToMutations(items, params.sort);
		} else {
			items.sort((a, b) => b.idx - a.idx);
		}
		const page = params?.page ?? 1;
		const itemsPerPage = params?.items ?? 100;
		const offset = (page - 1) * itemsPerPage;
		const paged = items.slice(offset, offset + itemsPerPage);
		// Count from the offset up to the 1000-row cap, mirroring the backend.
		const tail = items.slice(offset);
		const { count, more } = cappedCount(tail.length, offset);
		return Promise.resolve({
			data: clone(paged),
			meta: { count, more }
		});
	}

	/** @internal */
	performBackrefsForDoc(id: string, params?: BackrefsParams): Promise<BackrefsResponse> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}
		const registered = this.backrefRows.get(id) ?? [];
		const cap = params?.items ?? 100;
		const items = registered.slice(0, cap);
		return Promise.resolve({
			data: clone(items),
			meta: {
				target: `urn:facet:${this.domain}:${this.docType}:${id}`,
				total: items.length,
				capped: registered.length > items.length
			}
		});
	}

	/** @internal */
	performRollback(id: string, mutationId: string): Promise<RollbackResponse> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}
		const targetIdx = doc.mutations.findIndex((m) => m.id === mutationId);
		if (targetIdx === -1) {
			return Promise.reject(new Error(`Mutation "${mutationId}" not found on "${id}"`));
		}
		const target = doc.mutations[targetIdx];

		// Replay forward from the most recent snapshot (or create) up to target.idx.
		let snapshotIdx = -1;
		for (let i = targetIdx; i >= 0; i--) {
			if (doc.mutations[i].action === 'snapshot' || doc.mutations[i].action === 'create') {
				snapshotIdx = i;
				break;
			}
		}
		const startIdx = snapshotIdx === -1 ? 0 : snapshotIdx;

		let content: Record<string, unknown> = {};
		for (let i = startIdx; i <= targetIdx; i++) {
			const m = doc.mutations[i];
			if (m.action === 'create' || m.action === 'snapshot') {
				content = clone(m.arguments.content as Record<string, unknown>);
			} else if (m.action === 'update') {
				const diff = m.arguments.diff as
					| { set?: { path?: string; value?: unknown }[]; unset?: unknown[] }
					| undefined;
				if (diff?.set) {
					for (const op of diff.set) {
						const path = op.path as string | undefined;
						if (path && path.startsWith('/')) {
							content[path.slice(1)] = op.value;
						}
					}
				}
			}
			// delete — preserve current content; projection just marks it deleted.
		}

		doc.content = clone(content);
		doc.deleted_at = null; // snapshot resurrects deleted documents
		const ts = now();
		doc.updated_at = ts;
		doc.version = Math.max(doc.version, target.idx);

		const snapshotMut = makeMutation(
			doc,
			'snapshot',
			'system:rollback',
			{
				content: clone(content),
				version: doc.version,
				meta: {},
				created_at: doc.created_at
			},
			// The real backend stamps cause_kind = "rollback" with event
			// "rolled_back" (see `Audit::Rollback`). It does NOT persist
			// `rolled_back_to` on the mutation row.
			{ kind: 'rollback', event: 'rolled_back' },
			ts
		);
		doc.mutations.push(snapshotMut);

		return Promise.resolve({
			id: doc.id,
			domain: doc.domain,
			doc_type: doc.doc_type,
			mut_id: snapshotMut.id,
			content: clone(content),
			created_at: doc.created_at
		});
	}

	/** @internal */
	performRestore(id: string): Promise<RollbackResponse> {
		const doc = this.resolveDoc(id);
		if (!doc) {
			return Promise.reject(new Error(`Document "${id}" not found`));
		}
		const last = doc.mutations[doc.mutations.length - 1];
		if (!last || last.action !== 'delete') {
			// Mirrors the backend's idempotency contract: restoring a live
			// document is a no-op-by-rejection (409), not a silent rollback.
			return Promise.reject(new DataSourceError(409, 'Document is not deleted'));
		}
		// Restore = roll back to the mutation immediately before the delete
		// (the create itself when the delete directly follows it). Reuses the
		// rollback replay, which skips the delete and writes a snapshot.
		const prev = doc.mutations.find((m) => m.idx === last.idx - 1);
		if (!prev) {
			return Promise.reject(
				new DataSourceError(422, 'Delete mutation has no preceding mutation; nothing to restore')
			);
		}
		return this.performRollback(id, prev.id);
	}
}
