// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Grid clipboard text — copy-side only.
 *
 * Copy serializes the selected range as TSV, the grammar Excel and Google
 * Sheets both speak: cells joined with `\t`, rows with `\n`, and a cell
 * holding a tab, a newline, or a quote wrapped in double quotes with the
 * quotes doubled. A round trip back into the grid (the paste side, phase 3)
 * parses the same grammar, so copied cells land where they came from.
 *
 * Copy text is the raw stored form, not the display form: a money cell
 * copies `120000`, an enum copies its key, a date copies its ISO value.
 * Display strings (`€ 120,000.00`) would re-parse badly on paste and drift
 * per locale. Empty cells copy as empty text, so a copied block re-pastes
 * to the same shape.
 */

/** Serialize a 2-D block of cell texts as TSV. */
export function serializeTSV(rows: string[][]): string {
	return rows.map((row) => row.map(escapeCell).join('\t')).join('\n');
}

function escapeCell(text: string): string {
	if (text.includes('\t') || text.includes('\n') || text.includes('"')) {
		return `"${text.replaceAll('"', '""')}"`;
	}
	return text;
}

/**
 * The copy text for one cell — the raw stored form per field type.
 * `null`/absent values copy as empty text so a copied block keeps its
 * shape; the field-less fallback (a column with no schema behind it)
 * stringifies like the table's plain cells do.
 */
export function cellCopyText(field: FieldDef | null, value: unknown): string {
	if (value === null || value === undefined || value === '') return '';
	switch (field?.type) {
		case 'boolean':
			return value === true ? 'true' : 'false';
		case 'money': {
			if (typeof value !== 'object' || value === null) return String(value);
			const amount = (value as Record<string, unknown>).value;
			return amount == null ? '' : String(amount);
		}
		default:
			return String(value);
	}
}
