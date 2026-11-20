// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Types for the DocType configuration editor.
 *
 * The raw doctype definition comes from a YAML-derived `Record<string, unknown>`
 * (loaded via fixture-loader and held in `MockDataDriver.doctypeDefinitions`).
 * The typed accessors below make that data safe to consume in components without
 * casting at every call site.
 *
 * The shape matches `core.DocType/definition.yml` — a self-referential schema
 * where the `fields` dictionary holds field definitions, each of which can
 * itself hold sub-fields (for object types) or item definitions (for arrays).
 */

// ── Field types ──────────────────────────────────────────────────────────────

/**
 * Known field data types in the Facet doctype system.
 */
export type FieldType =
	| 'string'
	| 'longtext'
	| 'integer'
	| 'boolean'
	| 'enum'
	| 'money'
	| 'datetime'
	| 'date'
	| 'dateperiod'
	| 'period'
	| 'object'
	| 'array'
	| 'dictionary'
	| 'reference'
	| 'child'
	| 'data'
	| 'any'
	| 'color'
	| 'duration'
	| 'phone'
	| 'url'
	| 'file'
	| 'secret';

const ALL_FIELD_TYPES: FieldType[] = [
	'string',
	'longtext',
	'integer',
	'boolean',
	'enum',
	'money',
	'datetime',
	'date',
	'dateperiod',
	'period',
	'object',
	'array',
	'dictionary',
	'reference',
	'child',
	'data',
	'any',
	'color',
	'duration',
	'phone',
	'url',
	'file',
	'secret'
];

// ── Typed accessors ──────────────────────────────────────────────────────────

function str(v: unknown, fallback?: string): string | undefined {
	return typeof v === 'string' ? v : fallback;
}

function bool(v: unknown, fallback?: boolean): boolean | undefined {
	return typeof v === 'boolean' ? v : fallback;
}

function num(v: unknown, fallback?: number): number | undefined {
	return typeof v === 'number' ? v : fallback;
}

function strArr(v: unknown): string[] | undefined {
	if (Array.isArray(v) && v.every((x) => typeof x === 'string')) return v as string[];
	return undefined;
}

/** A single enum value with optional display label and color. */
export interface EnumValue {
	key: string;
	label?: string;
	color?: string;
}

/** The three stage modes a `secret` field can run in. */
export type SecretMode = 'hash' | 'sealed' | 'token';

/** Humanize a snake_case or kebab-case identifier into display text. */
export function humanize(str: string): string {
	return str
		.replace(/[_-]/g, ' ')
		.replace(/\s+/g, ' ')
		.replace(/\b\w/g, (c) => c.toUpperCase())
		.trim();
}

/**
 * Parse raw enum values into typed {@link EnumValue} entries.
 *
 * Accepts both shorthand string arrays (`['active', 'closed']`) and
 * full object arrays (`[{key: 'active', label: 'Active', color: '#0f0'}]`).
 * Mixed arrays are also supported.
 */
function parseEnumValues(v: unknown): EnumValue[] | undefined {
	if (!Array.isArray(v)) return undefined;
	const out: EnumValue[] = [];
	for (const item of v) {
		if (typeof item === 'string') {
			out.push({ key: item });
		} else if (item && typeof item === 'object') {
			const obj = item as Record<string, unknown>;
			const key = str(obj['key']);
			if (key !== undefined) {
				const entry: EnumValue = { key };
				const label = str(obj['label']);
				if (label !== undefined) entry.label = label;
				const color = str(obj['color']);
				if (color !== undefined) entry.color = color;
				out.push(entry);
			}
		}
	}
	return out.length > 0 ? out : undefined;
}

/** Extract a field type string and validate it's a known type. */
export function readFieldType(v: unknown): FieldType {
	const raw = str(v);
	if (raw && (ALL_FIELD_TYPES as string[]).includes(raw)) return raw as FieldType;
	return 'string';
}

// ── Field values ────────────────────────────────────────────────────────────

/**
 * A `money`-typed field value as stored in document content.
 *
 * `value` is a canonical decimal *string* (e.g. `"9.99"`, `"-50.00"`,
 * `"0"`), parsed as `BigDecimal` by the backend for arithmetic and comparison
 * via the IMMUTABLE `facet_money_value_as_numeric` helper. `currency` is an
 * ISO-4217 ticker validated against the `Util::Currency` registry. Both
 * members are required at write time — `MoneyType#normalize` backfills the
 * field-level `currency` declaration when the submitted object omits it.
 */
export interface MoneyValue {
	value: string;
	currency: string;
}

/**
 * The value a `period` / `dateperiod` field stores in document content, and
 * the shape the range controls bind in a form values bag.
 *
 * Both members are required — the backend's `RangeType` rejects a bound with
 * either member missing, so a control commits either the complete pair or the
 * `''` sentinel (same convention as a cleared `MoneyInput`). The member shape
 * differs by field type: `period` bounds are UTC RFC-3339 datetimes,
 * `dateperiod` bounds are `YYYY-MM-DD` calendar dates.
 */
export type PeriodValue = '' | { start: string; end: string };

/**
 * The value a `secret` field stores in document content.
 *
 * The plaintext never reaches the projection — the backend hashes or seals
 * it at stage time and keeps only this marker. Documents carry the marker
 * through lists, search, and audit exactly like any scalar value; every
 * surface must render it as a badge, never as raw JSON.
 */
export interface SecretMarker {
	mode: SecretMode;
	version: number;
	set_at: string;
}

/**
 * Narrow an unknown field value to a {@link SecretMarker}.
 *
 * Returns `null` for anything that does not match the marker shape, so
 * renderers fall back to the unset dash instead of leaking a stray object.
 */
export function asSecretMarker(v: unknown): SecretMarker | null {
	if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
	const m = v as Record<string, unknown>;
	if (m['mode'] !== 'hash' && m['mode'] !== 'sealed' && m['mode'] !== 'token') return null;
	if (typeof m['version'] !== 'number' || typeof m['set_at'] !== 'string') return null;
	return { mode: m['mode'], version: m['version'], set_at: m['set_at'] };
}

// ── Field definition ─────────────────────────────────────────────────────────

/**
 * Capability → operator fan-out, mirroring the backend
 * `FilterCapability#operators`. The union is sorted by the backend
 * `Operator` enum declaration order so the derived set reads in the
 * natural sequence (`comparison` → `eq, ne, gt, gte, lt, lte, between`).
 */
const OPERATOR_DECLARATION_ORDER: readonly string[] = [
	'eq',
	'ne',
	'gt',
	'gte',
	'lt',
	'lte',
	'between',
	'in',
	'match',
	'starts_with',
	'contains',
	'overlaps',
	'within',
	'currency'
];

/** Capability families, in the backend `FilterCapability` order. */
const CAPABILITY_OPERATORS: Readonly<Record<string, readonly string[]>> = {
	equality: ['eq'],
	comparison: ['eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'between'],
	text_search: ['match', 'starts_with'],
	interval: ['eq', 'contains', 'overlaps', 'within'],
	membership: ['eq', 'contains', 'overlaps'],
	currency: ['currency']
};

/**
 * Per-type runtime operator ceilings — the mirror of the backend
 * `Doctype.supported_operators` (`src/doctype/filter_capability.cr`): the
 * operators the clause builders compile per field type. The derivation
 * never advertises an operator the backend would reject with
 * `unsupported_filter_operator` (`comparison` on a money field fans out to
 * `ne`, but the money builder does not serve it).
 */
const TYPE_OPERATOR_CEILINGS: Readonly<Record<string, readonly string[]>> = {
	period: ['eq', 'contains', 'overlaps', 'within'],
	dateperiod: ['eq', 'contains', 'overlaps', 'within'],
	money: ['eq', 'gt', 'gte', 'lt', 'lte', 'between', 'currency'],
	array: ['eq', 'contains', 'overlaps'],
	boolean: ['eq', 'ne'],
	reference: ['eq', 'ne']
};

/** Ceiling for every type without a dedicated builder routing. */
const DEFAULT_OPERATOR_CEILING: readonly string[] = [
	'eq',
	'ne',
	'match',
	'starts_with',
	'gt',
	'gte',
	'lt',
	'lte',
	'between',
	'in'
];

/**
 * Derive a field's runtime operator set from its authored `filters`
 * capabilities. Unknown capability names are ignored (the backend rejects
 * them at authoring time). Type supplements ride the same btree as `eq` and
 * mirror `FieldDefinition#operators`: `in` on enum fields, `ne` on boolean
 * and reference fields. The result is intersected with the type's runtime
 * ceiling, so a capability never offers an operator the backend does not
 * serve. Returns `undefined` when no capability derives an operator, so the
 * parsed `FieldDef` stays clean.
 */
function deriveOperators(
	caps: string[] | undefined,
	type: string | undefined
): string[] | undefined {
	if (!caps || caps.length === 0) return undefined;
	const set = new Set<string>();
	for (const cap of caps) {
		for (const op of CAPABILITY_OPERATORS[cap] ?? []) set.add(op);
	}
	if (set.size === 0) return undefined;
	if (set.has('eq')) {
		if (type === 'enum') set.add('in');
		if (type === 'boolean' || type === 'reference') set.add('ne');
	}
	const ceiling = (type && TYPE_OPERATOR_CEILINGS[type]) || DEFAULT_OPERATOR_CEILING;
	return [...set]
		.filter((op) => ceiling.includes(op))
		.sort((a, b) => OPERATOR_DECLARATION_ORDER.indexOf(a) - OPERATOR_DECLARATION_ORDER.indexOf(b));
}

export interface FieldDef {
	key: string;
	type: FieldType;
	required?: boolean;
	title?: string;
	description?: string;
	default?: unknown;
	pattern?: string;
	pattern_flags?: string;
	min?: number;
	max?: number;
	unique?: boolean;
	/** Enum values (only for type === 'enum'). */
	values?: EnumValue[];
	/** Array item definition (only for type === 'array'). */
	items?: FieldDef;
	/** Sub-fields (only for type === 'object' or array items of type 'object'). */
	properties?: FieldDef[];
	/**
	 * Entry-value definition of a `dictionary` field (keys are always strings).
	 * Mirrors the backend `FieldDefinition#dictionary_value`, declared under
	 * `values:` in the definition. Absent when the entries are free-form.
	 */
	dictionaryValue?: FieldDef;
	/** Target doctype for reference, child, or data types. */
	doctype?: string;
	/** Collection flag for references. */
	collection?: boolean;
	/** Owned flag for references. */
	owned?: boolean;
	/**
	 * Declarative filter for references — a `field__op: value` hash passed
	 * straight to the backend `Document::List` query so the picker only offers
	 * documents that match. Mirrors the backend `Hash(String, JSON::Any)?`.
	 */
	filter?: Record<string, unknown>;
	/** Lua compute function name (only for type === 'data'). */
	compute?: string;
	/** Fields whose changes trigger recomputation. */
	compute_when?: string[];
	/** Currency code for money fields. */
	currency?: string;
	/**
	 * Display precision (number of decimal digits) for money fields. When
	 * unset, the renderer defaults to 2. Set to `0` for firmographic estimates
	 * and other amounts where cent precision would imply a false accuracy.
	 * Pure display concern — the backend stores money in smallest-unit raw
	 * integers regardless of this value.
	 */
	precision?: number;
	/**
	 * Authored filter capabilities (the backend `FilterCapability` enum:
	 * `equality`, `comparison`, `text_search`, `interval`, `membership`,
	 * `currency`). This is the only authoring surface — the backend derives
	 * both the runtime operator set and the physical indexes from it.
	 */
	filters?: string[];
	/**
	 * Derived runtime filter operators (the URL `__op` suffix vocabulary).
	 * Backend-computed from `filters`; parsed read-only for the filter bar
	 * and introspection. Never serialized back — the backend recomputes it.
	 */
	operators?: string[];
	/** Sensitivity tags for field-level access masking. */
	tags?: string[];
	/** Read-only flag. */
	read_only?: boolean;
	/** Write-only flag. */
	write_only?: boolean;
	/** On-source-delete behaviour for replicated fields. */
	on_source_delete?: 'keep' | 'unset';
	/**
	 * Cross-domain replication config. When set, the field is read-only and
	 * populated by the replication system from a source document. Mirrors the
	 * backend `ReplicateConfig` (`{via, field}`).
	 */
	replicate?: { via: string; field: string };
	/**
	 * MIME allow-list for `file`-typed fields (e.g. `['image/*', 'application/pdf']`).
	 * Mirrors the backend `FieldDefinition#accept`; a `nil`/absent value means
	 * any MIME is accepted. Wildcards are allowed on the subtype only
	 * (`image/*`), matching `Facet::Util::MimeMatcher`.
	 */
	accept?: string[];
	/**
	 * Stage mode for `secret`-typed fields. `hash` verifies a submitted
	 * plaintext against a stored digest, `sealed` stores it encrypted and
	 * lets authorized reads reveal it, `token` generates a one-time token at
	 * stage time. Mirrors the backend `FieldDefinition#mode`; defaults to
	 * `hash` when absent.
	 */
	mode?: SecretMode;
	/**
	 * Handle lifetime in seconds for `secret`-typed fields. The backend
	 * rejects a staged handle older than this window with a validation error;
	 * the frontend asks the user to re-enter the value. Mirrors the backend
	 * `FieldDefinition#ttl_seconds`.
	 */
	ttl_seconds?: number;
}

/**
 * Field types the backend list sort accepts. Mirrors the case list in
 * `Document::List#sort_expression_for` (`src/document/list.cr`): a sort
 * entry naming any other type answers `422 unsortable_field`, so sort
 * pickers and table headers must never offer one. Keep the two lists in
 * sync — the allowlist fails closed for types added on either side later.
 */
const SORTABLE_FIELD_TYPES: ReadonlySet<FieldType> = new Set([
	'string',
	'longtext',
	'integer',
	'boolean',
	'enum',
	'money',
	'datetime',
	'date',
	'reference',
	'color',
	'duration',
	'phone',
	'url'
]);

/**
 * True when the backend list sort accepts the field's type. The system
 * columns (`id`, `created_at`, `updated_at`, `deleted_at`) sort outside
 * this check — they are not doctype fields (see
 * `Document::List#build_order_clause` in `src/document/list.cr`).
 */
export function isSortableField(fieldDef: FieldDef): boolean {
	return SORTABLE_FIELD_TYPES.has(fieldDef.type);
}

/**
 * Parse a single raw field definition record into a typed {@link FieldDef}.
 */
export function parseFieldDef(key: string, raw: Record<string, unknown>): FieldDef {
	const out: FieldDef = { key, type: readFieldType(raw['type']) };

	const req = bool(raw['required']);
	if (req !== undefined) out.required = req;

	const t = str(raw['title']);
	if (t !== undefined) out.title = t;

	const d = str(raw['description']);
	if (d !== undefined) out.description = d;

	if (raw['default'] !== undefined) out.default = raw['default'];

	const p = str(raw['pattern']);
	if (p !== undefined) out.pattern = p;

	const pf = str(raw['pattern_flags']);
	if (pf !== undefined) out.pattern_flags = pf;

	const min = num(raw['min']);
	if (min !== undefined) out.min = min;

	const max = num(raw['max']);
	if (max !== undefined) out.max = max;

	const uq = bool(raw['unique']);
	if (uq !== undefined) out.unique = uq;

	const vals = parseEnumValues(raw['values']);
	if (vals !== undefined) out.values = vals;

	// Items for array type
	const itemsRaw = raw['items'];
	if (itemsRaw && typeof itemsRaw === 'object') {
		const ir = itemsRaw as Record<string, unknown>;
		if (typeof ir['type'] === 'string') {
			out.items = parseFieldDef('(items)', ir);
		}
		// Properties embedded in items (array of objects)
		const propsRaw = ir['properties'] ?? ir['shape'];
		if (propsRaw && typeof propsRaw === 'object') {
			out.items = {
				...(out.items ?? { key: '(items)', type: 'object' }),
				properties: parseFieldEntries(propsRaw as Record<string, unknown>)
			};
		}
	}

	// Properties for object type — stored as either `properties` (dictionary)
	// or `shape` (array, from the example mockup). Both are supported so we
	// can use the example data as fixture extensions.
	const propsRaw = raw['properties'] ?? raw['shape'];
	if (propsRaw && typeof propsRaw === 'object') {
		out.properties = parseFieldEntries(propsRaw as Record<string, unknown>);
	}

	// Dictionary entry-value definition — declared under `values:` as a nested
	// field definition (the backend `FieldDefinition#dictionary_value`). Enum
	// values use the same key but only ever as an array, so the two never
	// collide.
	if (out.type === 'dictionary') {
		const dvRaw = raw['values'];
		if (
			dvRaw &&
			typeof dvRaw === 'object' &&
			!Array.isArray(dvRaw) &&
			typeof (dvRaw as Record<string, unknown>)['type'] === 'string'
		) {
			out.dictionaryValue = parseFieldDef('(value)', dvRaw as Record<string, unknown>);
		}
	}

	const dt = str(raw['doctype']);
	if (dt !== undefined) out.doctype = dt;

	const coll = bool(raw['collection']);
	if (coll !== undefined) out.collection = coll;

	const owned = bool(raw['owned']);
	if (owned !== undefined) out.owned = owned;

	const filterRaw = raw['filter'];
	if (filterRaw && typeof filterRaw === 'object' && !Array.isArray(filterRaw)) {
		out.filter = filterRaw as Record<string, unknown>;
	}

	const comp = str(raw['compute']);
	if (comp !== undefined) out.compute = comp;

	const cw = strArr(raw['compute_when']);
	if (cw !== undefined) out.compute_when = cw;

	const cur = str(raw['currency']);
	if (cur !== undefined) out.currency = cur;

	const prec = num(raw['precision']);
	if (prec !== undefined) out.precision = prec;

	const caps = strArr(raw['filters']);
	if (caps !== undefined) out.filters = caps;

	// Derived read-only operator surface (backend-computed from `filters`).
	// The backend introspection always carries the computed array; fixtures
	// declare only the capabilities, so the union is derived here with the
	// same fan-out (`FilterCapability#operators` plus the enum `in`
	// supplement), sorted by the backend operator declaration order.
	const ops = strArr(raw['operators']) ?? deriveOperators(caps, str(raw['type']));
	if (ops !== undefined) out.operators = ops;

	const tags = strArr(raw['tags'] ?? raw['sensitivity_tags']);
	if (tags !== undefined) out.tags = tags;

	const ro = bool(raw['read_only']);
	if (ro !== undefined) out.read_only = ro;

	const wo = bool(raw['write_only']);
	if (wo !== undefined) out.write_only = wo;

	const osd = str(raw['on_source_delete']);
	if (osd === 'keep' || osd === 'unset') out.on_source_delete = osd;

	// Cross-domain replication config — a `{via, field}` object. Both keys are
	// required by the backend `ReplicateConfig`; a partial object is ignored
	// (the backend rejects it at authoring time).
	const repRaw = raw['replicate'];
	if (repRaw && typeof repRaw === 'object' && !Array.isArray(repRaw)) {
		const r = repRaw as Record<string, unknown>;
		const via = str(r['via']);
		const field = str(r['field']);
		if (via !== undefined && field !== undefined) out.replicate = { via, field };
	}

	const accept = strArr(raw['accept']);
	if (accept !== undefined) out.accept = accept;

	const mode = str(raw['mode']);
	if (mode === 'hash' || mode === 'sealed' || mode === 'token') out.mode = mode;

	const ttl = num(raw['ttl_seconds']);
	if (ttl !== undefined) out.ttl_seconds = ttl;

	return out;
}

/**
 * Parse a dictionary of field definitions (keyed by field name) into an
 * alphabetically-sorted array of typed {@link FieldDef} objects.
 *
 * Fields are sorted by key — this matches their JSONB storage ordering
 * and keeps the editor display stable.
 */
export function parseFieldEntries(fields: Record<string, unknown>): FieldDef[] {
	const entries = Object.entries(fields)
		.filter(([, val]) => val && typeof val === 'object')
		.map(([key, val]) => parseFieldDef(key, val as Record<string, unknown>));
	entries.sort((a, b) => a.key.localeCompare(b.key));
	return entries;
}

// ── Child definition ─────────────────────────────────────────────────────────

export interface ChildDef {
	/** The relationship key (e.g. "activities"). */
	key: string;
	/** Target doctype name (e.g. "Activity"). */
	doctype: string;
	/** Whether this holds multiple child documents (default: true). */
	collection?: boolean;
	/** Human-readable description. */
	description?: string;
}

/**
 * Parse a single child definition entry.
 */
export function parseChildDef(key: string, raw: Record<string, unknown>): ChildDef {
	return {
		key,
		doctype: str(raw['doctype']) ?? '(unknown)',
		collection: bool(raw['collection']) ?? true,
		description: str(raw['description'])
	};
}

/**
 * Parse the `children` dictionary from a doctype definition.
 */
export function parseChildEntries(children?: Record<string, unknown>): ChildDef[] {
	if (!children || typeof children !== 'object') return [];
	const out = Object.entries(children)
		.filter(([, val]) => val && typeof val === 'object')
		.map(([key, val]) => parseChildDef(key, val as Record<string, unknown>));
	out.sort((a, b) => a.key.localeCompare(b.key));
	return out;
}

// ── Sidecar definition ───────────────────────────────────────────────────────

export interface SidecarDef {
	/** The segment name in the host's nested route (e.g. "comments"). */
	key: string;
	/** Qualified sidecar doctype (e.g. "core.Comment"). */
	doctype: string;
	/** Reference column on the sidecar pointing back at the host (e.g. "target"). */
	column: string;
	/** Optional tab order; defaults to 0 (jsonb does not preserve key order). */
	order?: number;
	/** Optional host-owned tab label override. */
	label?: string;
}

/**
 * Parse a single sidecar definition entry.
 */
export function parseSidecarDef(key: string, raw: Record<string, unknown>): SidecarDef {
	const out: SidecarDef = {
		key,
		doctype: str(raw['doctype']) ?? '(unknown)',
		column: str(raw['column']) ?? '(unknown)'
	};
	const order = num(raw['order']);
	if (order !== undefined) out.order = order;
	const label = str(raw['label']);
	if (label !== undefined) out.label = label;
	return out;
}

/**
 * Parse the `sidecars` dictionary from a doctype definition.
 *
 * Entries are sorted by `{order ?? 0, key}` — this is the tab order the
 * sidecar panel renders. `order` compares numerically, `key` with
 * `localeCompare`.
 */
export function parseSidecarEntries(sidecars?: Record<string, unknown>): SidecarDef[] {
	if (!sidecars || typeof sidecars !== 'object') return [];
	const out = Object.entries(sidecars)
		.filter(([, val]) => val && typeof val === 'object')
		.map(([key, val]) => parseSidecarDef(key, val as Record<string, unknown>));
	out.sort((a, b) => {
		const oa = a.order ?? 0;
		const ob = b.order ?? 0;
		return oa !== ob ? oa - ob : a.key.localeCompare(b.key);
	});
	return out;
}

// ── Action definition ────────────────────────────────────────────────────────

export interface ArgDef {
	key: string;
	type: FieldType;
	required?: boolean;
	default?: unknown;
	values?: EnumValue[];
	min?: number;
	max?: number;
	doctype?: string;
	collection?: boolean;
}

function parseArgDef(key: string, raw: Record<string, unknown>): ArgDef {
	const out: ArgDef = { key, type: readFieldType(raw['type']) };
	const req = bool(raw['required']);
	if (req !== undefined) out.required = req;
	if (raw['default'] !== undefined) out.default = raw['default'];
	const vals = parseEnumValues(raw['values']);
	if (vals !== undefined) out.values = vals;
	const min = num(raw['min']);
	if (min !== undefined) out.min = min;
	const max = num(raw['max']);
	if (max !== undefined) out.max = max;
	const dt = str(raw['doctype']);
	if (dt !== undefined) out.doctype = dt;
	const coll = bool(raw['collection']);
	if (coll !== undefined) out.collection = coll;
	return out;
}

export interface ActionDef {
	/** The action key (e.g. "move_stage"). */
	key: string;
	/** Optional display label (falls back to a humanized key). */
	label?: string;
	/** Optional description shown as helper text. */
	description?: string;
	/** Argument definitions. */
	args: ArgDef[];
	/** Optional custom event name. */
	event_name?: string;
	/** Optional state gate: field name → values the field must carry in the
	 *  document content for the action to be available. Absent = every state. */
	states?: Record<string, string[]>;
}

/**
 * Parse a single action definition entry.
 */
export function parseActionDef(key: string, raw: Record<string, unknown>): ActionDef {
	const argsRaw = raw['args'];
	const args: ArgDef[] =
		argsRaw && typeof argsRaw === 'object'
			? Object.entries(argsRaw as Record<string, unknown>)
					.filter(([, val]) => val && typeof val === 'object')
					.map(([k, v]) => parseArgDef(k, v as Record<string, unknown>))
			: [];

	const out: ActionDef = { key, args };
	const lbl = str(raw['label']);
	if (lbl !== undefined) out.label = lbl;
	const desc = str(raw['description']);
	if (desc !== undefined) out.description = desc;
	const ev = str(raw['event_name']);
	if (ev !== undefined) out.event_name = ev;
	const statesRaw = raw['states'];
	if (statesRaw && typeof statesRaw === 'object' && !Array.isArray(statesRaw)) {
		const states: Record<string, string[]> = {};
		for (const [field, values] of Object.entries(statesRaw as Record<string, unknown>)) {
			if (!Array.isArray(values)) continue;
			const list = values.filter((v): v is string => typeof v === 'string' && v.length > 0);
			if (list.length > 0) states[field] = list;
		}
		if (Object.keys(states).length > 0) out.states = states;
	}
	return out;
}

/**
 * Whether an action is available in a document's current state: every gated
 * field must carry a listed value in the content. An action without `states`
 * is available in every state. Mirrors `ActionDefinition#state_allowed?`.
 */
export function actionStateAllowed(
	act: Pick<ActionDef, 'states'>,
	content: Record<string, unknown>
): boolean {
	if (!act.states) return true;
	return Object.entries(act.states).every(([field, values]) => {
		const value = content[field];
		return typeof value === 'string' && values.includes(value);
	});
}

/**
 * Parse the `actions` dictionary from a doctype definition.
 */
export function parseActionEntries(actions?: Record<string, unknown>): ActionDef[] {
	if (!actions || typeof actions !== 'object') return [];
	const out = Object.entries(actions)
		.filter(([, val]) => val && typeof val === 'object')
		.map(([key, val]) => parseActionDef(key, val as Record<string, unknown>));
	out.sort((a, b) => a.key.localeCompare(b.key));
	return out;
}

// ── Doctype definition ───────────────────────────────────────────────────────

export interface DoctypeDef {
	/** The doctype name (e.g. "Deal"). */
	doctype: string;
	/** The domain name (e.g. "crm"). */
	domain: string;
	/** Optional human display label; every surface falls back to `doctype` when absent or empty. */
	label?: string;
	/** Optional human plural noun (e.g. "contacts"). Sourced from `core.DocType.plural_label`;
	 *  app consent screens and grant summaries fall back to a naive pluraliser when absent. */
	plural_label?: string;
	/** Schema version number. */
	schema_version?: number;
	/** Whether this is an aggregate root. */
	aggregate_root?: boolean;
	/** Parent doctype name (when not an aggregate root). */
	member_of?: string;
	/** Human-readable description. */
	description?: string;
	/** Accent color. */
	color?: string;
	/** Optional Lucide icon name (kebab-case) shown in doctype marks. */
	icon?: string;
	/** Parsed fields (alphabetically sorted). */
	fields: FieldDef[];
	/** Parsed children. */
	children: ChildDef[];
	/** Parsed actions. */
	actions: ActionDef[];
	/** Whether nested sidecar routes are enabled for this doctype. */
	sidecar?: boolean;
	/** Parsed sidecars in tab order. Optional on the type (hand-built literals predate it); `parseDoctypeDef` always populates it. */
	sidecars?: SidecarDef[];
	/** Surface id override for document rendering. */
	surface?: string;
	/** Lua script content. */
	script?: string;
	/**
	 * Schema migration map: source schema version → Lua function name
	 * (e.g. `{ '1': 'migrate_from_1' }`). Each function must be exported by
	 * the script; the backend runs the gap functions in order on read.
	 */
	migrations?: Record<string, string>;
	/** Jinja2 template rendered at mutation time into the projection's `search` column for trigram substring search over the accent-folded label corpus. When absent, the search bar is hidden. */
	search?: string;
}

/**
 * Parse a full doctype definition record.
 */
export function parseDoctypeDef(raw: Record<string, unknown>): DoctypeDef {
	const fieldsRaw = raw['fields'];
	const childrenRaw = raw['children'];
	const actionsRaw = raw['actions'];
	const sidecarsRaw = raw['sidecars'];

	return {
		doctype: str(raw['doctype']) ?? '(unnamed)',
		domain: str(raw['domain']) ?? '',
		label: str(raw['label']),
		plural_label: str(raw['plural_label']),
		schema_version: num(raw['schema_version']),
		aggregate_root: bool(raw['aggregate_root']),
		member_of: str(raw['member_of']),
		description: str(raw['description']),
		color: str(raw['color']),
		icon: str(raw['icon']),
		fields:
			fieldsRaw && typeof fieldsRaw === 'object'
				? parseFieldEntries(fieldsRaw as Record<string, unknown>)
				: [],
		children: parseChildEntries(
			childrenRaw && typeof childrenRaw === 'object'
				? (childrenRaw as Record<string, unknown>)
				: undefined
		),
		actions: parseActionEntries(
			actionsRaw && typeof actionsRaw === 'object'
				? (actionsRaw as Record<string, unknown>)
				: undefined
		),
		sidecar: bool(raw['sidecar']),
		sidecars: parseSidecarEntries(
			sidecarsRaw && typeof sidecarsRaw === 'object'
				? (sidecarsRaw as Record<string, unknown>)
				: undefined
		),
		surface: str(raw['surface']),
		script: str(raw['script']),
		search: str(raw['search']),
		migrations: parseMigrations(raw['migrations'])
	};
}

/** Parse the `migrations` map: version string → Lua function name. */
function parseMigrations(raw: unknown): Record<string, string> | undefined {
	if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
	const out: Record<string, string> = {};
	for (const [version, fn] of Object.entries(raw as Record<string, unknown>)) {
		if (typeof fn === 'string') out[version] = fn;
	}
	return Object.keys(out).length > 0 ? out : undefined;
}

// ── Serialization ───────────────────────────────────────────────────────────
//
// The serialize direction lives in `./serialize.js`. Parse and serialize have
// different importers; `serialize.js` imports its types from here (one-way —
// no import cycle).
