// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { resolveParentRel } from './parentLink.js';

/** A minimal parent definition record shaped like a raw `core.DocType`. */
function parentDef(children: unknown): Record<string, unknown> {
	return { doctype: 'Project', domain: 'production', children };
}

describe('resolveParentRel', () => {
	it('resolves the rel key for a bare target', () => {
		expect(
			resolveParentRel(parentDef({ tasks: { doctype: 'Task', collection: true } }), 'Task')
		).toBe('tasks');
	});

	it('resolves the rel key for a qualified target', () => {
		expect(resolveParentRel(parentDef({ tasks: { doctype: 'production.Task' } }), 'Task')).toBe(
			'tasks'
		);
	});

	it('skips entries whose target is a different doctype', () => {
		expect(
			resolveParentRel(
				parentDef({ members: { doctype: 'TeamMember' }, tasks: { doctype: 'Task' } }),
				'Task'
			)
		).toBe('tasks');
	});

	it('returns the first match when several entries target the same doctype', () => {
		expect(
			resolveParentRel(
				parentDef({ tasks: { doctype: 'Task' }, spare_tasks: { doctype: 'Task' } }),
				'Task'
			)
		).toBe('tasks');
	});

	it('returns null when no entry matches', () => {
		expect(resolveParentRel(parentDef({ members: { doctype: 'TeamMember' } }), 'Task')).toBeNull();
	});

	it('returns null when the parent declares no children map', () => {
		expect(resolveParentRel(parentDef(undefined), 'Task')).toBeNull();
		expect(resolveParentRel(parentDef(null), 'Task')).toBeNull();
		expect(resolveParentRel({ doctype: 'Project', domain: 'production' }, 'Task')).toBeNull();
	});

	it('returns null for malformed entries', () => {
		expect(resolveParentRel(parentDef({ broken: 'not-an-object' }), 'Task')).toBeNull();
		expect(resolveParentRel(parentDef({ broken: { no_doctype: true } }), 'Task')).toBeNull();
		expect(resolveParentRel(parentDef([1, 2]), 'Task')).toBeNull();
	});
});
