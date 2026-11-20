// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import * as messages from '$lib/paraglide/messages';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { MutationRecord } from '$lib/datasource/types.js';
import type { ChangeEntry } from './auditDiff.js';
import {
	actorLabel,
	changeStats,
	childFallbackLabel,
	detailEntity,
	detailLabel,
	isChildRow,
	resolveActorLabel,
	viaChip,
	CAUSE_ICONS,
	CHANNEL_ICONS
} from './historyDetail.js';

/** A full mutation record with the fields the derivations read; tests
 * override what they exercise. */
function mut(overrides: Partial<MutationRecord> = {}): MutationRecord {
	return {
		id: '01HXXXXXXXXXXXXXXXXXXXXXXX',
		domain: 'crm',
		doc_type: 'Employee',
		doc_id: '01JABCDEFGHIJKLMNOPQRSTUVWXYZAB',
		idx: 3,
		action: 'update',
		actioner_id: 'system',
		arguments: {},
		channel: 'session',
		cause_kind: 'request',
		cause_trace: '01HXXXXXXXXXXXXXXXXXXXXXXX',
		emitted_at: '2026-01-01T00:00:00.000Z',
		...overrides
	};
}

describe('viaChip', () => {
	it('returns null when nothing is selected', () => {
		expect(viaChip(null)).toBeNull();
	});

	it('names an assistant cause with its name and icon', () => {
		const chip = viaChip(mut({ cause_kind: 'assistant', cause_name: 'Atlas' }));
		expect(chip).toEqual({
			tone: 'assistant',
			label: 'Assistant',
			sub: 'Atlas',
			icon: CAUSE_ICONS['assistant']
		});
	});

	it('names other provenance kinds with a humanized label', () => {
		const chip = viaChip(mut({ cause_kind: 'hook_schedule', cause_name: null }));
		expect(chip).toEqual({
			tone: 'cause',
			label: 'Hook Schedule',
			sub: null,
			icon: CAUSE_ICONS['hook_schedule']
		});
	});

	it('names the transport and rides the action name for an action write', () => {
		const chip = viaChip(mut({ cause_kind: 'action', cause_name: 'confirm', channel: 'session' }));
		expect(chip).toEqual({
			tone: 'cause',
			label: 'facet',
			sub: 'confirm',
			icon: CHANNEL_ICONS['session']
		});
	});

	it('falls through to the auth channel on a plain request', () => {
		const chip = viaChip(mut({ channel: 'mcp', acting_role: 'admin' }));
		expect(chip).toEqual({ tone: 'chan', label: 'mcp', sub: 'admin', icon: CHANNEL_ICONS['mcp'] });
	});

	it('shows the elected role as the sub-label on a session write', () => {
		const chip = viaChip(mut({ channel: 'session', acting_role: 'iam.Roles.admin' }));
		expect(chip).toEqual({
			tone: 'chan',
			label: 'facet',
			sub: 'iam.Roles.admin',
			icon: CHANNEL_ICONS['session']
		});
	});

	it('shows the session channel as facet with no sub-label', () => {
		const chip = viaChip(mut({ channel: 'session' }));
		expect(chip).toEqual({
			tone: 'chan',
			label: 'facet',
			sub: null,
			icon: CHANNEL_ICONS['session']
		});
	});

	it('masks the api key tail on the api_key channel', () => {
		const chip = viaChip(mut({ channel: 'api_key', api_key: '01JT3STXXXXXXXXXXXXXXXXA91F' }));
		expect(chip).toEqual({
			tone: 'chan',
			label: 'api_key',
			sub: messages.audit_detail_key_sub({ mask: '…A91F' }),
			icon: CHANNEL_ICONS['api_key']
		});
	});

	it('gives an api_key row without a key no sub-label', () => {
		const chip = viaChip(mut({ channel: 'api_key', api_key: null }));
		expect(chip?.sub).toBeNull();
	});

	it('returns null for a request with no channel', () => {
		expect(viaChip(mut({ channel: '' }))).toBeNull();
	});
});

describe('changeStats', () => {
	it('counts set, patch and unset, and counts init as set', () => {
		const changes: ChangeEntry[] = [
			{ path: '/a', kind: 'init', value: 1 },
			{ path: '/b', kind: 'set', value: 2 },
			{ path: '/c', kind: 'patch' },
			{ path: '/d', kind: 'unset' }
		];
		expect(changeStats(changes)).toEqual([
			{ kind: 'set', label: messages.audit_summary_set({ count: 2 }) },
			{ kind: 'patch', label: messages.audit_summary_patch_singular({ count: 1 }) },
			{ kind: 'unset', label: messages.audit_summary_unset({ count: 1 }) }
		]);
	});

	it('uses the plural patch label for two patches', () => {
		const changes: ChangeEntry[] = [
			{ path: '/a', kind: 'patch' },
			{ path: '/b', kind: 'patch' }
		];
		expect(changeStats(changes)).toEqual([
			{ kind: 'patch', label: messages.audit_summary_patch_plural({ count: 2 }) }
		]);
	});

	it('omits parts with a zero count', () => {
		const changes: ChangeEntry[] = [{ path: '/a', kind: 'unset' }];
		expect(changeStats(changes)).toEqual([
			{ kind: 'unset', label: messages.audit_summary_unset({ count: 1 }) }
		]);
	});

	it('returns an empty list for no changes', () => {
		expect(changeStats([])).toEqual([]);
	});
});

describe('isChildRow', () => {
	const row = mut({ doc_type: 'Task' });

	it('is false when the aggregate mode is off', () => {
		expect(isChildRow(row, false, 'Employee')).toBe(false);
	});

	it('is false when the parent doctype is unknown', () => {
		expect(isChildRow(row, true, null)).toBe(false);
	});

	it('is true when the row doctype differs from the parent', () => {
		expect(isChildRow(row, true, 'Employee')).toBe(true);
	});

	it('is false for parent rows', () => {
		expect(isChildRow(mut({ doc_type: 'Employee' }), true, 'Employee')).toBe(false);
	});
});

describe('childFallbackLabel', () => {
	it('keeps a doc id of 12 chars verbatim', () => {
		expect(childFallbackLabel('0123456789ab')).toBe('0123456789ab');
	});

	it('cuts a longer doc id at 12 chars with an ellipsis', () => {
		expect(childFallbackLabel('0123456789abc')).toBe('0123456789ab…');
	});
});

describe('detailEntity', () => {
	it('is empty when nothing is selected', () => {
		expect(detailEntity(null)).toBe('');
	});

	it('is the doctype of the mutation target', () => {
		expect(detailEntity(mut())).toBe('Employee');
	});
});

describe('detailLabel', () => {
	it('is empty when nothing is selected', () => {
		expect(detailLabel(null, false, null, null)).toBe('');
	});

	it('prefers the display name from the record', () => {
		const row = mut({ display_name: 'Jane Doe' });
		expect(detailLabel(row, true, 'Employee', 'Page Label')).toBe('Jane Doe');
	});

	it('uses the page label for a parent row without a display name', () => {
		expect(detailLabel(mut(), false, null, 'Élise Martin')).toBe('Élise Martin');
	});

	it('ignores the page label on a child row and cuts the doc id', () => {
		const row = mut({ doc_type: 'Task', doc_id: '0123456789abcdef' });
		expect(detailLabel(row, true, 'Employee', 'Élise Martin')).toBe('0123456789ab…');
	});

	it('falls back to a cut doc id when no label source applies', () => {
		expect(detailLabel(mut(), false, null, null)).toBe('01JABCDEFGHI…');
	});
});

describe('actorLabel', () => {
	it('returns the resolved name when present', () => {
		const labels = { '01HAAAAAAAAAAAAAAAAAAAAAAA': 'Kim Patel' };
		expect(actorLabel(labels, '01HAAAAAAAAAAAAAAAAAAAAAAA')).toBe('Kim Patel');
	});

	it('falls back to the raw id', () => {
		expect(actorLabel({}, 'system')).toBe('system');
	});
});

const ACCOUNT_ULID = '01HAAAAAAAAAAAAAAAAAAAAAAA';

/** A driver stub whose `iam.Account` show runs `show`; records every
 * doc id the stub fetches. */
function accountDriver(show: (id: string) => Promise<unknown>): {
	driver: DataDriver;
	shown: string[];
} {
	const shown: string[] = [];
	const driver = {
		domain: () => ({
			doctype: () => ({
				doc: (id: string) => ({
					show: () => {
						shown.push(id);
						return show(id);
					}
				})
			})
		}),
		getDoctypeDefinition: () => undefined
	} as unknown as DataDriver;
	return { driver, shown };
}

describe('resolveActorLabel', () => {
	it('skips the show for machine principals', async () => {
		const { driver, shown } = accountDriver(async () => ({}));
		await expect(resolveActorLabel(driver, 'system')).resolves.toBeNull();
		expect(shown).toEqual([]);
	});

	it('prefers the meta display name', async () => {
		const { driver } = accountDriver(async () => ({
			data: { name: 'Content Name', email: 'kim@facet.dev' },
			meta: { display_name: 'Kim Patel' }
		}));
		await expect(resolveActorLabel(driver, ACCOUNT_ULID)).resolves.toBe('Kim Patel');
	});

	it('falls back to the content name', async () => {
		const { driver } = accountDriver(async () => ({
			data: { name: 'Content Name', email: 'kim@facet.dev' },
			meta: { display_name: null }
		}));
		await expect(resolveActorLabel(driver, ACCOUNT_ULID)).resolves.toBe('Content Name');
	});

	it('falls back to the email when no display name is readable', async () => {
		const { driver } = accountDriver(async () => ({
			data: { name: '', email: 'kim@facet.dev' },
			meta: { display_name: null }
		}));
		await expect(resolveActorLabel(driver, ACCOUNT_ULID)).resolves.toBe('kim@facet.dev');
	});

	it('returns null when the account has no readable label', async () => {
		const { driver } = accountDriver(async () => ({ data: {}, meta: {} }));
		await expect(resolveActorLabel(driver, ACCOUNT_ULID)).resolves.toBeNull();
	});

	it('returns null when the lookup fails', async () => {
		const { driver } = accountDriver(async () => {
			throw new Error('403');
		});
		await expect(resolveActorLabel(driver, ACCOUNT_ULID)).resolves.toBeNull();
	});
});
