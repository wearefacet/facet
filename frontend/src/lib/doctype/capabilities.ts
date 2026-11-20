// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Filter capability tables for the doctype editors — the frontend mirror of
 * the backend `Facet::Doctype::FilterCapability` enum
 * (`src/doctype/filter_capability.cr`).
 *
 * A capability is what the doctype author picks per field. The backend
 * derives both the runtime operator set and the physical indexes from it;
 * the editors here only gate which checkboxes render and which start
 * checked.
 */

/** Authored capability names, in the backend enum declaration order. */
export const FILTER_CAPABILITIES = [
	'text_search',
	'comparison',
	'equality',
	'interval',
	'membership',
	'currency'
] as const;

export type FilterCapability = (typeof FILTER_CAPABILITIES)[number];

/** Field types each capability is valid on (mirrors `valid_for?`). */
const CAPABILITY_TYPES: Record<FilterCapability, readonly string[]> = {
	equality: [
		'string',
		'longtext',
		'integer',
		'duration',
		'datetime',
		'date',
		'boolean',
		'enum',
		'phone',
		'url',
		'money',
		'color',
		'period',
		'dateperiod',
		'reference',
		'child'
	],
	comparison: [
		'string',
		'longtext',
		'integer',
		'duration',
		'datetime',
		'date',
		'enum',
		'phone',
		'url',
		'money',
		'color'
	],
	text_search: ['string', 'longtext', 'phone', 'url', 'enum'],
	interval: ['period', 'dateperiod'],
	membership: ['array'],
	currency: ['money']
};

/**
 * Capabilities the author may pick for a field of the given type.
 * Unknown type names yield the empty list — the type editor then shows the
 * "not filterable" note.
 */
export function validFilterCapabilities(type: string): FilterCapability[] {
	return FILTER_CAPABILITIES.filter((cap) => CAPABILITY_TYPES[cap]?.includes(type));
}

/**
 * The capabilities a new field starts with, per type — the same "typical
 * choices" the domain-builder skill teaches (`field-types.md`). Authors can
 * still uncheck any of them; the goal is that a freshly added field is
 * filterable by default instead of silently invisible to every filter
 * surface (a field without capabilities derives no operators).
 */
const DEFAULT_CAPABILITIES: Readonly<Record<string, readonly FilterCapability[]>> = {
	string: ['equality', 'text_search'],
	longtext: ['equality', 'text_search'],
	phone: ['equality', 'text_search'],
	url: ['equality', 'text_search'],
	integer: ['comparison'],
	duration: ['comparison'],
	datetime: ['comparison'],
	date: ['comparison'],
	boolean: ['equality'],
	enum: ['equality'],
	reference: ['equality'],
	child: ['equality'],
	money: ['comparison', 'currency'],
	color: ['equality'],
	period: ['interval'],
	dateperiod: ['interval'],
	array: ['membership']
};

/**
 * The default capability set for `type`, restricted to what the type may
 * declare. Returns an empty array for types that cannot be filtered at all
 * (`data`, `object`, `file`, `secret`, `dictionary`, `any`).
 */
export function defaultFilterCapabilities(type: string): FilterCapability[] {
	const defaults = DEFAULT_CAPABILITIES[type] ?? [];
	const valid = new Set(validFilterCapabilities(type));
	return defaults.filter((cap) => valid.has(cap));
}
