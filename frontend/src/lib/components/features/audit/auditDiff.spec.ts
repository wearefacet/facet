// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	channelLabel,
	describeMutation,
	groupChanges,
	hasCause,
	isAccountActioner,
	mutationChanges,
	truncateValue,
	viaLine,
	VALUE_PREVIEW_LIMIT,
	type ChangeEntry
} from './auditDiff.js';
import type { MutationRecord } from '$lib/datasource/types.js';
import * as messages from '$lib/paraglide/messages';

/** A minimal valid mutation row — tests override the fields they exercise. */
function record(overrides: Partial<MutationRecord>): MutationRecord {
	return {
		id: '01HAAAAAAAAAAAAAAAAAAAAAAA',
		domain: 'hr',
		doc_type: 'Employee',
		doc_id: '01HBBBBBBBBBBBBBBBBBBBBBB',
		idx: 1,
		action: 'update',
		actioner_id: 'system',
		arguments: {},
		channel: 'session',
		cause_kind: 'request',
		cause_trace: '01HAAAAAAAAAAAAAAAAAAAAAAA',
		emitted_at: '2026-01-15T08:00:00Z',
		...overrides
	};
}

describe('groupChanges', () => {
	it('orders groups init, set, patch, unset', () => {
		const changes: ChangeEntry[] = [
			{ path: '/a', kind: 'unset' },
			{ path: '/b', kind: 'set', value: 1 },
			{ path: '/c', kind: 'init', value: 'x' },
			{ path: '/d', kind: 'patch' }
		];
		expect(groupChanges(changes).map((g) => g.kind)).toEqual(['init', 'set', 'patch', 'unset']);
	});

	it('keeps the diff order inside a group and drops empty groups', () => {
		const changes: ChangeEntry[] = [
			{ path: '/first', kind: 'set', value: 1 },
			{ path: '/second', kind: 'set', value: 2 },
			{ path: '/gone', kind: 'unset' }
		];
		const groups = groupChanges(changes);
		expect(groups.length).toBe(2);
		expect(groups[0]!.entries.map((c) => c.path)).toEqual(['/first', '/second']);
		expect(groups[1]!.kind).toBe('unset');
	});

	it('returns an empty list for no changes', () => {
		expect(groupChanges([])).toEqual([]);
	});
});

describe('mutationChanges — redacted', () => {
	it('marks a redacted create field with no value', () => {
		const m = record({
			action: 'create',
			arguments: { content: { name: 'Ada' } },
			redacted: [['salary']]
		});
		expect(mutationChanges(m)).toStrictEqual([
			{ path: '/name', kind: 'init', value: 'Ada' },
			{ path: '/salary', kind: 'redacted' }
		]);
	});

	it('hides a redacted update set value and keeps a single row', () => {
		const m = record({
			arguments: { diff: { set: [{ path: ['salary'], value: 125000 }], unset: [] } },
			redacted: [['salary']]
		});
		expect(mutationChanges(m)).toStrictEqual([{ path: '/salary', kind: 'redacted' }]);
	});

	it('hides a redacted long-text patch', () => {
		const m = record({
			arguments: { diff: { set: [{ path: ['notes'], patch: { base: 'x' } }], unset: [] } },
			redacted: [['notes']]
		});
		expect(mutationChanges(m)).toStrictEqual([{ path: '/notes', kind: 'redacted' }]);
	});

	it('marks a redacted snapshot field with no value', () => {
		const m = record({
			action: 'snapshot',
			arguments: { content: { status: 'live' } },
			redacted: [['salary']]
		});
		expect(mutationChanges(m)).toStrictEqual([
			{ path: '/status', kind: 'init', value: 'live' },
			{ path: '/salary', kind: 'redacted' }
		]);
	});

	it('redacts a nested diff path', () => {
		const m = record({
			arguments: { diff: { set: [{ path: ['address', 'city'], value: 'Oslo' }], unset: [] } },
			redacted: [['address', 'city']]
		});
		expect(mutationChanges(m)).toStrictEqual([{ path: '/address/city', kind: 'redacted' }]);
	});

	it('appends a redacted entry for a nested path under a visible create container', () => {
		const m = record({
			action: 'create',
			// The server strips the hidden segment before sending, so the
			// container value arrives without it.
			arguments: { content: { address: { city: 'Oslo' } } },
			redacted: [['address', 'zip']]
		});
		expect(mutationChanges(m)).toStrictEqual([
			{ path: '/address', kind: 'init', value: { city: 'Oslo' } },
			{ path: '/address/zip', kind: 'redacted' }
		]);
	});

	it('does not duplicate a redacted unset path', () => {
		const m = record({
			arguments: { diff: { set: [], unset: [['salary']] } },
			redacted: [['salary']]
		});
		expect(mutationChanges(m)).toStrictEqual([{ path: '/salary', kind: 'unset' }]);
	});

	it('keeps visible siblings next to a redacted set', () => {
		const m = record({
			arguments: {
				diff: {
					set: [
						{ path: ['status'], value: 'approved' },
						{ path: ['salary'], value: 125000 }
					],
					unset: []
				}
			},
			redacted: [['salary']]
		});
		expect(mutationChanges(m)).toStrictEqual([
			{ path: '/status', kind: 'set', value: 'approved' },
			{ path: '/salary', kind: 'redacted' }
		]);
	});

	it('treats a row without redacted metadata as a plain update', () => {
		const m = record({
			arguments: { diff: { set: [{ path: ['salary'], value: 125000 }], unset: [] } }
		});
		expect(mutationChanges(m)).toStrictEqual([{ path: '/salary', kind: 'set', value: 125000 }]);
	});

	it('groups redacted entries after unset, one badge per kind', () => {
		const groups = groupChanges([
			{ path: '/a', kind: 'unset' },
			{ path: '/b', kind: 'redacted' }
		]);
		expect(groups.map((g) => g.kind)).toEqual(['unset', 'redacted']);
	});

	it('counts redacted entries in the update summary', () => {
		const m = record({
			arguments: { diff: { set: [{ path: ['salary'] }], unset: [] } },
			redacted: [['salary']]
		});
		expect(describeMutation(m)).toBe(messages.audit_summary_redacted({ count: 1 }));
	});
});

describe('truncateValue', () => {
	it('keeps text at or under the limit verbatim', () => {
		expect(truncateValue('short')).toBe('short');
		expect(truncateValue('a'.repeat(VALUE_PREVIEW_LIMIT)).length).toBe(VALUE_PREVIEW_LIMIT);
	});

	it('cuts longer text at the limit with an ellipsis', () => {
		const out = truncateValue('b'.repeat(VALUE_PREVIEW_LIMIT + 100));
		expect(out.length).toBe(VALUE_PREVIEW_LIMIT + 1);
		expect(out.endsWith('…')).toBe(true);
	});

	it('honours an explicit limit', () => {
		expect(truncateValue('abcdef', 4)).toBe('abcd…');
	});
});

describe('channelLabel', () => {
	it('shows the session channel as facet', () => {
		expect(channelLabel('session')).toBe('facet');
	});

	it('passes other channels through verbatim', () => {
		expect(channelLabel('api_key')).toBe('api_key');
		expect(channelLabel('mcp')).toBe('mcp');
	});
});

describe('viaLine', () => {
	it('names the transport and rides the action name for an action write', () => {
		expect(
			viaLine(record({ cause_kind: 'action', cause_name: 'confirm', channel: 'session' }))
		).toEqual({ label: 'facet', sub: 'confirm' });
	});

	it('keeps the transport sub null when the action carries no name', () => {
		expect(viaLine(record({ cause_kind: 'action', cause_name: null, channel: 'mcp' }))).toEqual({
			label: 'mcp',
			sub: null
		});
	});

	it('keeps the humanized kind label for the other cause kinds', () => {
		expect(viaLine(record({ cause_kind: 'rollback' }))).toEqual({ label: 'Rollback', sub: null });
		expect(viaLine(record({ cause_kind: 'assistant' }))).toEqual({ label: 'Assistant', sub: null });
	});
});

describe('hasCause', () => {
	it('is false for the default request write', () => {
		expect(hasCause({ cause_kind: 'request' })).toBe(false);
	});

	it('is true for every provenance-bearing cause kind', () => {
		for (const kind of [
			'assistant',
			'action',
			'rollback',
			'cascade',
			'hook_event',
			'hook_schedule',
			'replication',
			'periodic_snapshot',
			'compaction',
			'migration',
			'webhook_test',
			'seed'
		]) {
			expect(hasCause({ cause_kind: kind })).toBe(true);
		}
	});
});

describe('isAccountActioner', () => {
	it('accepts a bare account ULID', () => {
		expect(isAccountActioner('01HAAAAAAAAAAAAAAAAAAAAAAA')).toBe(true);
	});

	it('accepts a qualified iam.Account token', () => {
		expect(isAccountActioner('iam.Account.01HAAAAAAAAAAAAAAAAAAAAAAA')).toBe(true);
	});

	it('rejects machine principals and bare labels', () => {
		expect(isAccountActioner('system')).toBe(false);
		expect(isAccountActioner('system:rollback')).toBe(false);
		expect(isAccountActioner('account-1')).toBe(false);
		expect(isAccountActioner('')).toBe(false);
	});
});
