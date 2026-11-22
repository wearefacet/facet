// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Header text for one saved-view column.
 *
 * A `core.CollectionView` column stores `{ key, label?, … }` and `label` is
 * optional. A view written by the editor resolves `key → title` before it
 * saves; a view written by REST, an agent, or an import stores the key alone.
 * One rule applies at render time so both doors show the same header:
 *
 * `label ?? field.title ?? humanize(key)`
 *
 * The humanized key reads better than the raw uppercased key (`f_string` →
 * `F String`, not `F_STRING`). An unknown key (a removed field) falls back to
 * its humanized form.
 */

import { humanize, type DoctypeDef } from './types.js';

export function resolveColumnLabel(
	def: DoctypeDef,
	key: string,
	label: string | undefined
): string {
	if (label !== undefined) return label;
	const field = def.fields.find((f) => f.key === key);
	return field?.title ?? humanize(key);
}
