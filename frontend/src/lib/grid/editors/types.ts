// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { FieldDef } from '$lib/doctype/types.js';
import type { DataDriver } from '$lib/datasource/driver.js';

/** Where a keyboard commit sends the selection afterwards. Enter moves
 *  down, Tab moves right; mouse commits carry `null` (no move). */
export type CommitMove = 'down' | 'right' | null;

/**
 * The contract every per-type cell editor implements. An editor never
 * touches the datasource — it parses, validates, and reports. The grid
 * owns the write.
 */
export interface CellEditorProps {
	/** The column's field definition — the type switch and the bounds. */
	field: FieldDef;
	/** The stored value at open time (may be `null`). */
	value: unknown;
	/** The printable char that opened the editor; `null` when it opened on
	 *  the current value. Bare-input editors seed the draft with it. */
	seed?: string | null;
	/** Column label for the editor's `aria-label` (falls back to the field title). */
	label?: string;
	/** Driver forwarded to the reference picker's record search. */
	driver?: DataDriver;
	/**
	 * Publish the live draft on every internal value change. `valid: false`
	 * marks a draft that cannot commit yet — an outside commit then cancels
	 * instead of writing. The shell reads the latest draft when another cell
	 * takes the mousedown.
	 */
	ondraft?: (value: unknown, valid: boolean) => void;
	/** Commit the parsed value (`null` clears the field) with the move hint. */
	oncommit: (value: unknown, move: CommitMove) => void;
	/** Close without writing. */
	oncancel: () => void;
}
