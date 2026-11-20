// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Schema-aware filter/search helpers for the table.
 *
 * A doctype field's `operators` array (mirroring the backend
 * `Facet::Doctype::Operator`) is the single source of truth for which
 * fields are searchable and which support equality, range, between, or
 * text-match filters. These helpers translate that metadata into the
 * `field__op=value` filter keys the backend `ListRequest` and the
 * `MockDataSource` both already understand.
 */
import type { DoctypeDef, FieldDef, FieldType } from './types.js';

/**
 * Operators mirrored from `src/doctype/operator.cr` (suffix form). The bar
 * renders the subset that pairs with a value control it already has: the
 * comparison family, `in` (enum multi-select), the two text operators, and
 * `currency` (a currency picker over the `core.Currency` registry). The range
 * operators (`contains`, `overlaps`, `within`) stay out until a range or
 * array editor exists for them.
 */
export type FilterOperator =
	| 'eq'
	| 'ne'
	| 'gt'
	| 'gte'
	| 'lt'
	| 'lte'
	| 'between'
	| 'in'
	| 'match'
	| 'currency';

/**
 * All operators the frontend toolbar knows how to render, in the backend
 * `Operator` declaration order — `operatorsFor` output follows this order,
 * so it matches the derived `operators` metadata order.
 */
export const ALL_OPERATORS: readonly FilterOperator[] = [
	'eq',
	'ne',
	'gt',
	'gte',
	'lt',
	'lte',
	'between',
	'in',
	'match',
	'currency'
];

/**
 * Maximum entries one `__in` filter may carry. Mirrors
 * `Util::FilterSet::MAX_IN_VALUES` (`src/util/filter_set.cr`): a longer
 * array, an empty one, or a non-array degrades to an always-false clause —
 * the bar disables further picks at the cap so users never build a filter
 * that silently matches nothing.
 */
export const MAX_IN_VALUES = 100;

/** True when a field advertises the given operator in its `operators` list. */
export function hasOperator(field: FieldDef, op: FilterOperator): boolean {
	const ops = field.operators;
	return Array.isArray(ops) && ops.includes(op);
}

/**
 * The operators a field supports, restricted to those the toolbar can render.
 * Preserves declaration order so the field author's preferred default comes first.
 */
export function operatorsFor(field: FieldDef): FilterOperator[] {
	const ops = field.operators ?? [];
	return ALL_OPERATORS.filter((op) => ops.includes(op));
}

/**
 * Fields that support at least one filter the toolbar can render (eq, ne,
 * gt, gte, lt, lte, between, in, match, currency). System-hidden fields are
 * excluded.
 */
export function filterableFields(fields: FieldDef[]): FieldDef[] {
	return fields.filter((f) => !isSystemHidden(f) && operatorsFor(f).length > 0);
}

/**
 * Virtual {@link FieldDef}s for the projection's system-managed timestamps
 * (`created_at`, `updated_at`) so they appear in the table toolbar's
 * "+ Add filter" menu and render the timezone-aware `DatetimePicker` (values
 * are UTC RFC-3339; the user enters wall time in their own zone). They are not
 * part of any doctype's `fields` schema — the backend routes them through
 * a dedicated WHERE-clause branch that targets the `projections` columns
 * directly (see `Document::List#build_system_clauses`).
 */
export const SYSTEM_TIMESTAMP_FIELD_DEFS: readonly FieldDef[] = [
	{
		key: 'created_at',
		type: 'datetime',
		title: 'Created At',
		operators: ['eq', 'gte', 'lte', 'between']
	},
	{
		key: 'updated_at',
		type: 'datetime',
		title: 'Updated At',
		operators: ['eq', 'gte', 'lte', 'between']
	}
];

/**
 * Virtual {@link FieldDef} for the system-managed parent link
 * (`meta.parent_id`) of an owned-child doctype.
 *
 * An owned child (one declaring `member_of`) deliberately defines no
 * back-reference field — the composition convention owns the link — so
 * this def exposes the parent as an equality filter (`parent_id__eq`)
 * that the backend routes through its dedicated parent clause (the same
 * narrowing the nested child route applies). The value control is the
 * standard reference combobox over the parent doctype: its target comes
 * from `member_of`, and the emitted value is the parent's fully
 * qualified id (`domain.Parent.id`), which the backend strips to the
 * bare stored id.
 *
 * Returns `undefined` for doctypes that are not owned children — the bar
 * then offers no parent filter at all.
 */
export function parentFieldDef(doctype: DoctypeDef | undefined): FieldDef | undefined {
	const parent = doctype?.member_of;
	if (!parent || !doctype?.domain) return undefined;
	return {
		key: 'parent_id',
		type: 'reference',
		title: parent,
		doctype: `${doctype.domain}.${parent}`,
		operators: ['eq']
	};
}

/** Fields that may be added as equality filters via the toolbar. */
export function eqFields(fields: FieldDef[]): FieldDef[] {
	return fields.filter((f) => !isSystemHidden(f) && hasOperator(f, 'eq'));
}

/** Fields that support a lower/upper bound (numeric/money/datetime). */
export function rangeFields(fields: FieldDef[]): FieldDef[] {
	return fields.filter(
		(f) =>
			!isSystemHidden(f) &&
			(hasOperator(f, 'gt') ||
				hasOperator(f, 'gte') ||
				hasOperator(f, 'lt') ||
				hasOperator(f, 'lte'))
	);
}

/** Compute the filter key (`field__op`) emitted to the datasource. */
export function filterKey(field: string, op: FilterOperator): string {
	return `${field}__${op}`;
}

/** Fields that should not appear as toolbar filter targets. */
function isSystemHidden(f: FieldDef): boolean {
	return f.read_only === true || f.write_only === true;
}

/** A coarse "kind" the toolbar uses to pick a control per field/operator. */
export type FilterControlKind =
	| 'enum'
	| 'enum-multi'
	| 'reference'
	| 'boolean'
	| 'number'
	| 'datetime'
	| 'currency'
	| 'text';

/**
 * Pick the right control for a field+operator pair.
 *
 * - `between` on a datetime field → a date/datetime range picker.
 * - `match` → a text input (substring search).
 * - `in` on an enum field → a multi-select (the backend derives `In` for
 *   enum fields; other types fall back to the text control).
 * - `eq` / `ne` → type-driven (enum dropdown, reference combobox, boolean
 *   True/False dropdown, number, etc.) — the exclusion filter takes the
 *   same value shape as equality.
 * - `gt`/`gte`/`lt`/`lte` → type-driven scalar input.
 * - `currency` → a currency picker emitting the stored ticker (the backend
 *   compares it against the money field's `currency` member).
 */
export function controlKindFor(field: FieldDef, op: FilterOperator): FilterControlKind {
	if (op === 'match') return 'text';
	if (op === 'in') return (field.type as FieldType) === 'enum' ? 'enum-multi' : 'text';
	if (op === 'currency') return 'currency';
	const t = field.type as FieldType;
	if (t === 'enum') return 'enum';
	if (t === 'reference') return 'reference';
	if (t === 'boolean') return 'boolean';
	if (t === 'integer' || t === 'money') return 'number';
	if (t === 'datetime') return 'datetime';
	return 'text';
}

/** Human-facing label for an operator. Refined by field type where relevant. */
export function operatorLabel(op: FilterOperator, field: FieldDef): string {
	const t = field.type as FieldType;
	switch (op) {
		case 'eq':
			return t === 'enum' || t === 'reference' || t === 'boolean' ? 'is' : '=';
		case 'ne':
			return t === 'enum' || t === 'reference' || t === 'boolean' ? 'is not' : '≠';
		case 'gt':
			return '>';
		case 'gte':
			return '≥';
		case 'lt':
			return '<';
		case 'lte':
			return '≤';
		case 'between':
			return t === 'datetime' ? 'between' : '±';
		case 'in':
			return 'is any of';
		case 'match':
			return 'contains';
		case 'currency':
			return 'is';
	}
}
