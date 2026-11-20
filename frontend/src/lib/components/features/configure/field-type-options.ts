// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { Component } from 'svelte';
import type { FieldType } from '$lib/doctype/types.js';
import Type from '@lucide/svelte/icons/type';
import FileText from '@lucide/svelte/icons/file-text';
import Hash from '@lucide/svelte/icons/hash';
import ToggleLeft from '@lucide/svelte/icons/toggle-left';
import List from '@lucide/svelte/icons/list';
import DollarSign from '@lucide/svelte/icons/dollar-sign';
import Calendar from '@lucide/svelte/icons/calendar';
import CalendarDays from '@lucide/svelte/icons/calendar-days';
import CalendarRange from '@lucide/svelte/icons/calendar-range';
import Hourglass from '@lucide/svelte/icons/hourglass';
import File from '@lucide/svelte/icons/file';
import Package from '@lucide/svelte/icons/package';
import Columns from '@lucide/svelte/icons/columns';
import Book from '@lucide/svelte/icons/book';
import Link from '@lucide/svelte/icons/link';
import Database from '@lucide/svelte/icons/database';
import Asterisk from '@lucide/svelte/icons/asterisk';
import Palette from '@lucide/svelte/icons/palette';
import Clock from '@lucide/svelte/icons/clock';
import Phone from '@lucide/svelte/icons/phone';
import Globe from '@lucide/svelte/icons/globe';
import KeyRound from '@lucide/svelte/icons/key-round';

/**
 * The complete set of selectable {@link FieldType} values, each paired with a
 * human label and an icon for the `Select` component's trigger and dropdown.
 *
 * Shared by `DoctypeFieldEditor` (field `type`) and `DoctypeEditor` (action
 * argument `type`) so both surfaces present the same type vocabulary, validated
 * via {@link readFieldType} at parse time.
 */
export interface FieldTypeOption {
	value: FieldType;
	label: string;
	icon: Component;
}

export const FIELD_TYPE_OPTIONS = [
	{ value: 'string', label: 'String', icon: Type },
	{ value: 'longtext', label: 'Long Text', icon: FileText },
	{ value: 'integer', label: 'Integer', icon: Hash },
	{ value: 'boolean', label: 'Boolean', icon: ToggleLeft },
	{ value: 'enum', label: 'Enum', icon: List },
	{ value: 'money', label: 'Money', icon: DollarSign },
	{ value: 'datetime', label: 'Date & Time', icon: Calendar },
	{ value: 'date', label: 'Date', icon: CalendarDays },
	{ value: 'dateperiod', label: 'Date Range', icon: CalendarRange },
	{ value: 'period', label: 'Period', icon: Hourglass },
	{ value: 'object', label: 'Object', icon: Package },
	{ value: 'array', label: 'Array', icon: Columns },
	{ value: 'dictionary', label: 'Dictionary', icon: Book },
	{ value: 'reference', label: 'Reference', icon: Link },
	{ value: 'data', label: 'Data', icon: Database },
	{ value: 'any', label: 'Any', icon: Asterisk },
	{ value: 'color', label: 'Color', icon: Palette },
	{ value: 'duration', label: 'Duration', icon: Clock },
	{ value: 'phone', label: 'Phone', icon: Phone },
	{ value: 'url', label: 'URL', icon: Globe },
	{ value: 'file', label: 'File', icon: File },
	{ value: 'secret', label: 'Secret', icon: KeyRound }
] satisfies FieldTypeOption[];

/**
 * FieldType members the picker must not offer. `child` is structural —
 * child doctypes are declared in the definition's `children` map, not as
 * fields — so the selectable set is every other member of the union.
 */
type NonSelectableFieldTypes = 'child';

/** The set {@link FIELD_TYPE_OPTIONS} must cover. */
type SelectableFieldType = Exclude<FieldType, NonSelectableFieldTypes>;

/**
 * Compile-time exhaustiveness guard: a new backend field type (see
 * `src/doctype/field_types/`) must gain a picker option, or this resolves
 * to `never` and `pnpm check` fails. A type that must stay non-selectable
 * goes into {@link NonSelectableFieldTypes} instead. The `satisfies`
 * annotation above keeps the `value` members literal — a declared
 * `FieldTypeOption[]` would widen them back to `FieldType` and make this
 * assertion vacuous.
 */
type MissingSelectableFieldTypes = Exclude<
	SelectableFieldType,
	(typeof FIELD_TYPE_OPTIONS)[number]['value']
>;
const _FIELD_TYPE_OPTIONS_COVER_SELECTABLE: [MissingSelectableFieldTypes] extends [never]
	? true
	: never = true;
