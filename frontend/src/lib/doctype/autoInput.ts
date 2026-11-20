// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Type-driven dispatch for the auto `input` template node.
 *
 * `resolveAutoInput` reads the field's declared type in the doctype
 * definition and returns either a synthesized specialized `input-*` node
 * (rendered by the matching `DvtInput*` component) or a `not-editable`
 * verdict for container/computed fields. Props the definition already
 * knows — enum options, the reference target, the required flag, the
 * url/tel/number sub-typing — are derived, never hand-copied.
 *
 * Display safety: a missing definition or an unknown field dispatches to
 * `input-text` (every input component has a read-only branch and the
 * validator rejects unknown fields at authoring time). Container and
 * computed fields never fall back — the backend validator rejects those
 * bindings outright, and the component renders a diagnostic.
 */

import { humanize } from './types.js';
import type { FieldDef } from './types.js';
import type {
	InputAutoNode,
	InputColorNode,
	InputDateNode,
	InputDateperiodNode,
	InputDatetimeNode,
	InputFileNode,
	InputLongtextNode,
	InputMoneyNode,
	InputPeriodNode,
	InputReferenceNode,
	InputSecretNode,
	InputSelectNode,
	InputTextNode,
	InputToggleNode
} from '$lib/template-types';

/** A synthesized specialized node the auto `input` renders. */
export type AutoInputNode =
	| InputTextNode
	| InputSelectNode
	| InputToggleNode
	| InputDatetimeNode
	| InputDateNode
	| InputPeriodNode
	| InputDateperiodNode
	| InputLongtextNode
	| InputReferenceNode
	| InputMoneyNode
	| InputColorNode
	| InputFileNode
	| InputSecretNode;

/** Why the auto `input` cannot edit the bound field. */
export type AutoNotEditableReason = 'array' | 'object' | 'dictionary' | 'data';

export type AutoInputResolution =
	| { kind: 'node'; node: AutoInputNode }
	| { kind: 'not-editable'; reason: AutoNotEditableReason };

/** Field types the auto `input` never edits (the backend validator agrees). */
const NOT_EDITABLE: ReadonlySet<string> = new Set(['array', 'object', 'dictionary', 'data']);

/** Derived label: template override, then the field's title, then the humanized key. */
function derivedLabel(node: InputAutoNode, fieldDef: FieldDef | null | undefined): string {
	return node.label ?? fieldDef?.title ?? humanize(node.field);
}

/** Derived required flag: template override, then the field definition's. */
function derivedRequired(
	node: InputAutoNode,
	fieldDef: FieldDef | null | undefined
): boolean | undefined {
	return node.required ?? fieldDef?.required;
}

/**
 * Resolve the auto `input` node into the specialized node to render.
 *
 * - `fieldDef` is the resolved definition for `node.field` (`null` when the
 *   definition is missing or the field is unknown — both dispatch to
 *   `input-text`).
 * - Enum options derive from the definition's `values` (`{value, label}`,
 *   humanized when the entry carries no label).
 */
export function resolveAutoInput(
	fieldDef: FieldDef | null | undefined,
	node: InputAutoNode
): AutoInputResolution {
	const label = derivedLabel(node, fieldDef);
	const required = derivedRequired(node, fieldDef);

	if (fieldDef && NOT_EDITABLE.has(fieldDef.type)) {
		return {
			kind: 'not-editable',
			reason: fieldDef.type as AutoNotEditableReason
		};
	}

	const type = fieldDef?.type;
	const base = {
		field: node.field,
		label,
		placeholder: node.placeholder,
		helper: node.helper,
		required
	};

	switch (type) {
		case 'enum': {
			const options = (fieldDef?.values ?? []).map((v) => ({
				value: v.key,
				label: v.label ?? humanize(v.key)
			}));
			return {
				kind: 'node',
				node: { type: 'input-select', ...base, options }
			};
		}
		case 'boolean':
			return { kind: 'node', node: { type: 'input-toggle', field: node.field, label } };
		case 'datetime':
			return { kind: 'node', node: { type: 'input-datetime', ...base } };
		case 'date':
			return { kind: 'node', node: { type: 'input-date', ...base } };
		case 'period':
			return { kind: 'node', node: { type: 'input-period', ...base } };
		case 'dateperiod':
			return { kind: 'node', node: { type: 'input-dateperiod', ...base } };
		case 'longtext':
			return {
				kind: 'node',
				node: {
					type: 'input-longtext',
					field: node.field,
					label,
					placeholder: node.placeholder
				}
			};
		case 'reference':
		case 'child':
			// The component derives the target doctype from the definition.
			return { kind: 'node', node: { type: 'input-reference', ...base } };
		case 'money':
			return { kind: 'node', node: { type: 'input-money', ...base } };
		case 'color':
			return { kind: 'node', node: { type: 'input-color', ...base } };
		case 'file':
			return { kind: 'node', node: { type: 'input-file', ...base } };
		case 'secret':
			return { kind: 'node', node: { type: 'input-secret', ...base } };
		default: {
			// Scalars, `any`, and the no-definition fallback: a text input.
			// `integer`/`duration` sub-type to `number`, `url`/`phone` to their
			// keyboards — the same sub-typing the validator's affinity table
			// already assigns to `input-text`.
			let inputType: InputTextNode['inputType'];
			if (type === 'integer' || type === 'duration') inputType = 'number';
			else if (type === 'url') inputType = 'url';
			else if (type === 'phone') inputType = 'tel';
			return {
				kind: 'node',
				node: inputType
					? { type: 'input-text', ...base, inputType }
					: { type: 'input-text', ...base }
			};
		}
	}
}
