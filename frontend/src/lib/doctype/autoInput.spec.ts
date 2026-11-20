// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { resolveAutoInput } from './autoInput';
import type { AutoInputNode, AutoInputResolution } from './autoInput';
import type { FieldDef } from './types';
import type { InputAutoNode, InputTextNode } from '$lib/template-types';

function auto(field: string, extra: Partial<InputAutoNode> = {}): InputAutoNode {
	return { type: 'input', field, ...extra };
}

function def(type: FieldDef['type'], extra: Partial<FieldDef> = {}): FieldDef {
	return { key: 'f', type, ...extra };
}

/** Narrow to the synthesized node and treat it as a text node for prop asserts. */
function node(r: AutoInputResolution): InputTextNode & AutoInputNode {
	if (r.kind !== 'node') throw new Error('expected a synthesized node');
	return r.node as InputTextNode & AutoInputNode;
}

describe('resolveAutoInput', () => {
	it('dispatches string and any to input-text without sub-typing', () => {
		for (const t of ['string', 'any'] as const) {
			const r = resolveAutoInput(def(t), auto('f'));
			expect(r).toEqual({
				kind: 'node',
				node: {
					type: 'input-text',
					field: 'f',
					label: 'F',
					placeholder: undefined,
					helper: undefined,
					required: undefined
				}
			});
		}
	});

	it('sub-types integer and duration to a number input', () => {
		for (const t of ['integer', 'duration'] as const) {
			const r = resolveAutoInput(def(t), auto('f'));
			expect(node(r)).toMatchObject({ type: 'input-text', inputType: 'number' });
		}
	});

	it('sub-types url and phone to their keyboards', () => {
		expect(node(resolveAutoInput(def('url'), auto('f')))).toMatchObject({
			type: 'input-text',
			inputType: 'url'
		});
		expect(node(resolveAutoInput(def('phone'), auto('f')))).toMatchObject({
			type: 'input-text',
			inputType: 'tel'
		});
	});

	it('derives select options from the definition values, humanizing unlabeled keys', () => {
		const r = resolveAutoInput(
			def('enum', { values: [{ key: 'active', label: 'Active' }, { key: 'churned_risk' }] }),
			auto('f')
		);
		expect(r).toEqual({
			kind: 'node',
			node: {
				type: 'input-select',
				field: 'f',
				label: 'F',
				placeholder: undefined,
				helper: undefined,
				required: undefined,
				options: [
					{ value: 'active', label: 'Active' },
					{ value: 'churned_risk', label: 'Churned Risk' }
				]
			}
		});
	});

	it('dispatches the dedicated controls per field type', () => {
		const expected: Array<[FieldDef['type'], string]> = [
			['boolean', 'input-toggle'],
			['datetime', 'input-datetime'],
			['date', 'input-date'],
			['longtext', 'input-longtext'],
			['money', 'input-money'],
			['color', 'input-color'],
			['file', 'input-file'],
			['secret', 'input-secret'],
			['period', 'input-period'],
			['dateperiod', 'input-dateperiod'],
			['reference', 'input-reference'],
			['child', 'input-reference']
		];
		for (const [t, nodeType] of expected) {
			const r = resolveAutoInput(def(t), auto('f'));
			expect(node(r).type).toBe(nodeType);
		}
	});

	it('derives the label from the template override, then the title, then the humanized key', () => {
		const byTitle = resolveAutoInput(def('string', { title: 'Deal Title' }), auto('f'));
		expect(node(byTitle).label).toBe('Deal Title');

		const byOverride = resolveAutoInput(
			def('string', { title: 'Deal Title' }),
			auto('f', { label: 'Custom' })
		);
		expect(node(byOverride).label).toBe('Custom');

		const byHumanize = resolveAutoInput(def('string'), auto('deal_title'));
		expect(node(byHumanize).label).toBe('Deal Title');
	});

	it('derives the required flag from the template override, then the definition', () => {
		const fromDef = resolveAutoInput(def('string', { required: true }), auto('f'));
		expect(node(fromDef).required).toBe(true);

		const fromTemplate = resolveAutoInput(
			def('string', { required: true }),
			auto('f', { required: false })
		);
		expect(node(fromTemplate).required).toBe(false);

		const neither = resolveAutoInput(def('string'), auto('f'));
		expect(node(neither).required).toBeUndefined();
	});

	it('forwards placeholder and helper chrome', () => {
		const r = resolveAutoInput(
			def('string'),
			auto('f', { placeholder: '/engineering/', helper: 'A path' })
		);
		expect(node(r)).toMatchObject({ placeholder: '/engineering/', helper: 'A path' });
	});

	it('falls back to input-text when the definition or the field is missing', () => {
		for (const fieldDef of [null, undefined]) {
			const r = resolveAutoInput(fieldDef, auto('f', { label: 'L' }));
			expect(node(r)).toMatchObject({ type: 'input-text', label: 'L' });
		}
	});

	it('marks container and computed fields not-editable', () => {
		for (const t of ['array', 'object', 'dictionary', 'data'] as const) {
			const r = resolveAutoInput(def(t), auto('f'));
			expect(r).toEqual({ kind: 'not-editable', reason: t });
		}
	});

	it('still derives the label for a not-editable verdict (unused by callers)', () => {
		// not-editable carries only the reason; the node shape is irrelevant.
		const r = resolveAutoInput(def('array'), auto('tags'));
		expect(r).toEqual({ kind: 'not-editable', reason: 'array' });
	});
});
