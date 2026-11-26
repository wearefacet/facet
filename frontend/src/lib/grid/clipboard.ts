// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Grid clipboard text — the TSV grammar both directions speak.
 *
 * Copy serializes the selected range as TSV, the grammar Excel and Google
 * Sheets both speak: cells joined with `\t`, rows with `\n`, and a cell
 * holding a tab, a newline, or a quote wrapped in double quotes with the
 * quotes doubled. Paste parses the same grammar back — `parseTSV` also
 * accepts the forms Excel's copy emits: `\r\n` row breaks and quoted
 * multi-line cells — so a round trip lands each cell where it came from.
 *
 * Copy text is the raw stored form, not the display form: a money cell
 * copies `120000`, an enum copies its key, a date copies its ISO value. A
 * range cell (`period` / `dateperiod`) copies its two stored bounds joined
 * with the arrow the paste grammar speaks — a `period`'s bounds are the
 * stored UTC instants, a `dateperiod`'s the calendar dates verbatim.
 * Display strings (`€ 120,000.00`) would re-parse badly on paste and drift
 * per locale. Empty cells copy as empty text, so a copied block re-pastes
 * to the same shape.
 */

/** Serialize a 2-D block of cell texts as TSV. */
export function serializeTSV(rows: string[][]): string {
	return rows.map((row) => row.map(escapeCell).join('\t')).join('\n');
}

/**
 * Parse clipboard TSV into a rectangular block of cell texts — the inverse
 * of `serializeTSV`, plus the dialect Excel copies in: `\r\n` (or a lone
 * `\r`) as a row break, and quoted cells whose doubled quotes unescape and
 * whose newlines stay inside the cell. Short rows pad with empty cells, so
 * the block is always rectangular; one trailing row break adds no row.
 */
export function parseTSV(text: string): string[][] {
	const rows: string[][] = [];
	let row: string[] = [];
	let cell = '';
	const endCell = () => {
		row.push(cell);
		cell = '';
	};
	const endRow = () => {
		endCell();
		rows.push(row);
		row = [];
	};

	let i = 0;
	while (i < text.length) {
		const ch = text[i];
		if (ch === '"') {
			// The quoted form — runs to the closing quote, doubled quotes are
			// literals. A quote mid-cell (never emitted by either writer) just
			// opens a quoted run; trailing junk after a closing quote drops.
			i++;
			while (i < text.length) {
				if (text[i] === '"') {
					if (text[i + 1] === '"') {
						cell += '"';
						i += 2;
						continue;
					}
					i++;
					while (i < text.length && text[i] !== '\t' && text[i] !== '\n' && text[i] !== '\r') i++;
					break;
				}
				cell += text[i];
				i++;
			}
			continue;
		}
		if (ch === '\t') {
			endCell();
			i++;
			continue;
		}
		if (ch === '\n' || ch === '\r') {
			if (ch === '\r' && text[i + 1] === '\n') i++;
			endRow();
			i++;
			continue;
		}
		cell += ch;
		i++;
	}
	// The final cell only exists when the text carries content past the last
	// row break — `a\tb\n` ends with no pending cell and adds no row.
	if (cell !== '' || row.length > 0) endRow();

	// Rectangularize — a short row pads with empty cells (Excel's paste shape).
	const width = rows.reduce((w, r) => Math.max(w, r.length), 0);
	for (const r of rows) {
		while (r.length < width) r.push('');
	}
	return rows;
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
		case 'period':
		case 'dateperiod': {
			// The two stored bounds — never the display form (a `period`'s
			// bounds would drift through a timezone conversion). A bound
			// that is missing or malformed drops: half a range names no
			// value, and `[object Object]` never belongs in a copied cell.
			if (typeof value !== 'object' || value === null) return String(value);
			const start = (value as Record<string, unknown>).start;
			const end = (value as Record<string, unknown>).end;
			if (start == null || end == null || start === '' || end === '') return '';
			return `${String(start)} → ${String(end)}`;
		}
		default:
			return String(value);
	}
}
