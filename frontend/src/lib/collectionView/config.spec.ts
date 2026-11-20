// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	pickableFields,
	sortableFields,
	defaultColumns,
	remainingFields,
	discriminatorFields,
	endFields,
	colorByFields,
	fieldOptions,
	groupableFields,
	dropUnknownFilter,
	buildConfig,
	buildPayload,
	validateDraft,
	type CollectionViewDraft
} from './config.js';
import { SYSTEM_TIMESTAMP_FIELD_DEFS } from '$lib/doctype/filters.js';
import type { FieldDef } from '$lib/doctype/types.js';

const field = (key: string, type: FieldDef['type'], extra: Partial<FieldDef> = {}): FieldDef => ({
	key,
	type,
	...extra
});

const FLAT_FIELDS: FieldDef[] = [
	field('title', 'string', { title: 'Deal Title' }),
	field('value', 'money'),
	field('status', 'enum', { operators: ['eq'] }),
	field('owner_id', 'reference'),
	field('notes', 'longtext'),
	field('payload', 'data'),
	field('expected_close_date', 'date', { operators: ['eq', 'gte', 'lte', 'between'] }),
	field('meta', 'object')
];

const tableDraft = (overrides: Partial<CollectionViewDraft> = {}): CollectionViewDraft => ({
	name: 'My view',
	surface: 'table',
	columns: [{ key: 'title', label: 'Deal Title' }],
	discriminator: '',
	endField: '',
	colorBy: '',
	titleTemplate: '',
	weekStart: 'monday',
	filters: {},
	filterableFields: [],
	fields: FLAT_FIELDS,
	kanbanMode: 'values',
	groupBy: '',
	lanes: [],
	sortField: '',
	sortDesc: true,
	sortFields: [],
	...overrides
});

describe('collectionView/config — editor config helpers', () => {
	describe('pickableFields', () => {
		it('drops container, computed, and secret types, keeps flat fields in order', () => {
			const out = pickableFields(FLAT_FIELDS).filter(
				(f) => !f.key.startsWith('created_at') && !f.key.startsWith('updated_at')
			);
			expect(out.map((f) => f.key)).toEqual([
				'title',
				'value',
				'status',
				'owner_id',
				'notes',
				'expected_close_date'
			]);
		});

		it('appends the system timestamp defs after the schema fields', () => {
			const out = pickableFields(FLAT_FIELDS);
			const systemKeys = SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key);
			expect(out.slice(-systemKeys.length).map((f) => f.key)).toEqual(systemKeys);
		});
	});

	describe('sortableFields', () => {
		it('keeps the types the backend sorts on and drops the rest', () => {
			const out = sortableFields(FLAT_FIELDS).filter(
				(f) => !f.key.startsWith('created_at') && !f.key.startsWith('updated_at')
			);
			expect(out.map((f) => f.key)).toEqual([
				'title',
				'value',
				'status',
				'owner_id',
				'notes',
				'expected_close_date'
			]);
		});

		it('keeps the system timestamp columns — the backend sorts them', () => {
			const out = sortableFields(FLAT_FIELDS);
			expect(out.filter((f) => f.key === 'created_at' || f.key === 'updated_at').length).toBe(2);
		});
	});

	describe('defaultColumns', () => {
		it('seeds from the first 4 flat fields, labelled with the field title', () => {
			expect(defaultColumns(FLAT_FIELDS)).toEqual([
				{ key: 'title', label: 'Deal Title' },
				{ key: 'value', label: 'value' },
				{ key: 'status', label: 'status' },
				{ key: 'owner_id', label: 'owner_id' }
			]);
		});

		it('skips non-flat types when counting the first 4', () => {
			// `payload` (data) and `meta` (object) sit inside the first 8 entries
			// but must not consume a seed slot.
			const out = defaultColumns(FLAT_FIELDS);
			expect(out.map((c) => c.key)).not.toContain('payload');
			expect(out.map((c) => c.key)).not.toContain('meta');
		});

		it('seeds only the flat fields when there are fewer than 4 (no system timestamps)', () => {
			const few = [field('title', 'string'), field('value', 'money')];
			expect(defaultColumns(few)).toEqual([
				{ key: 'title', label: 'title' },
				{ key: 'value', label: 'value' }
			]);
		});

		it('marks plain boolean columns editable, but not read_only/write_only ones', () => {
			const fields = [
				field('name', 'string'),
				field('active', 'boolean'),
				field('locked', 'boolean', { read_only: true }),
				field('masked', 'boolean', { write_only: true })
			];
			expect(defaultColumns(fields)).toEqual([
				{ key: 'name', label: 'name' },
				{ key: 'active', label: 'active', editable: true },
				{ key: 'locked', label: 'locked' },
				{ key: 'masked', label: 'masked' }
			]);
		});
	});

	describe('remainingFields', () => {
		it('subtracts used column keys and keeps pick order incl. system timestamps', () => {
			const pickable = pickableFields(FLAT_FIELDS);
			const columns = defaultColumns(FLAT_FIELDS);
			expect(remainingFields(pickable, columns).map((f) => f.key)).toEqual([
				'notes',
				'expected_close_date',
				...SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			]);
		});

		it('returns every pickable entry when no columns are used', () => {
			const pickable = pickableFields(FLAT_FIELDS);
			expect(remainingFields(pickable, [])).toEqual(pickable);
		});
	});

	describe('discriminatorFields', () => {
		it('keeps comparison-capable date/datetime and range fields, then appends the system timestamps', () => {
			const fields = [
				field('title', 'string'),
				field('actual_close_date', 'date', { operators: ['eq', 'gte', 'lte'] }),
				field('expected_close_date', 'datetime', { operators: ['eq', 'gte', 'lte'] }),
				field('window', 'period'),
				field('stay', 'dateperiod'),
				field('status', 'enum')
			];
			expect(discriminatorFields(fields).map((f) => f.key)).toEqual([
				'actual_close_date',
				'expected_close_date',
				'window',
				'stay',
				...SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			]);
		});

		it('drops a date/datetime whose operators lack gte or lte — the window filter would 422', () => {
			const fields = [
				field('capability_less', 'date'),
				field('equality_only', 'date', { operators: ['eq'] }),
				field('half_window', 'datetime', { operators: ['eq', 'gte'] })
			];
			// Only the system timestamps stay eligible — they always carry gte/lte.
			expect(discriminatorFields(fields).map((f) => f.key)).toEqual(
				SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			);
			// A range-typed sibling stays eligible alongside them.
			const mixed = [...fields, field('window', 'period')];
			expect(discriminatorFields(mixed).map((f) => f.key)).toEqual([
				'window',
				...SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			]);
		});

		it('keeps period/dateperiod fields without operators — the native range path emits no window filter', () => {
			const fields = [field('window', 'period'), field('stay', 'dateperiod')];
			expect(discriminatorFields(fields).map((f) => f.key)).toEqual([
				'window',
				'stay',
				...SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			]);
		});

		it('still offers the system timestamps for a doctype with no date fields', () => {
			const fields = [field('title', 'string'), field('status', 'enum')];
			expect(discriminatorFields(fields).map((f) => f.key)).toEqual(
				SYSTEM_TIMESTAMP_FIELD_DEFS.map((f) => f.key)
			);
		});
	});

	describe('endFields', () => {
		const fields = [
			field('actual_close_date', 'date', { operators: ['eq', 'gte', 'lte'] }),
			field('expected_close_date', 'date', { operators: ['eq', 'gte', 'lte'] }),
			field('capability_less', 'date'),
			field('created_at', 'datetime', { operators: ['eq', 'gte', 'lte'] }),
			field('updated_at', 'datetime', { operators: ['eq', 'gte', 'lte'] }),
			field('title', 'string')
		];

		it('offers sibling date fields when the discriminator is a date, minus itself', () => {
			expect(endFields(fields, 'actual_close_date').map((f) => f.key)).toEqual([
				'expected_close_date'
			]);
		});

		it('offers sibling datetime fields when the discriminator is a datetime', () => {
			expect(endFields(fields, 'created_at').map((f) => f.key)).toEqual(['updated_at']);
		});

		it('drops a sibling without the gte operator — the range bound would 422', () => {
			// capability_less is a schema date with no operators; the gte-capable
			// discriminator must not offer it as a range end.
			expect(endFields(fields, 'expected_close_date').map((f) => f.key)).toEqual([
				'actual_close_date'
			]);
		});

		it('offers nothing for period/dateperiod or unknown discriminators', () => {
			expect(endFields(fields, 'stay')).toEqual([]);
			expect(endFields(fields, 'ghost')).toEqual([]);
		});

		it('pairs the system timestamps when the schema has no date fields', () => {
			const plain = [field('title', 'string'), field('status', 'enum')];
			expect(endFields(plain, 'created_at').map((f) => f.key)).toEqual(['updated_at']);
			expect(endFields(plain, 'updated_at').map((f) => f.key)).toEqual(['created_at']);
		});
	});

	describe('colorByFields', () => {
		const fields = [
			field('status', 'enum'),
			field('owner_id', 'reference'),
			field('expected_close_date', 'date')
		];

		it('keeps enum and reference fields, excluding the discriminator key', () => {
			expect(colorByFields(fields, 'expected_close_date').map((f) => f.key)).toEqual([
				'status',
				'owner_id'
			]);
		});

		it('excludes an enum discriminator key even though it matches the type filter', () => {
			expect(colorByFields(fields, 'status').map((f) => f.key)).toEqual(['owner_id']);
		});
	});

	describe('fieldOptions', () => {
		it('labels with the field title when present', () => {
			expect(fieldOptions([field('title', 'string', { title: 'Deal Title' })])).toEqual([
				{ value: 'title', label: 'Deal Title' }
			]);
		});

		it('falls back to the humanized key', () => {
			expect(fieldOptions([field('expected_close_date', 'date')])).toEqual([
				{ value: 'expected_close_date', label: 'Expected close date' }
			]);
		});
	});

	describe('dropUnknownFilter', () => {
		const fields = [
			field('status', 'enum', { operators: ['eq'] }),
			field('expected_close_date', 'date', { operators: ['eq', 'between'] }),
			field('title', 'string')
		];

		it('keeps only keys that resolve to a field with operators', () => {
			const filters = {
				status__eq: 'open',
				expected_close_date__between: ['2026-01-01', '2026-12-31'],
				title__eq: 'nope',
				ghost__eq: 'gone'
			};
			expect(dropUnknownFilter(filters, fields)).toEqual({
				status__eq: 'open',
				expected_close_date__between: ['2026-01-01', '2026-12-31']
			});
		});

		it('splits on the last __ so operator-like suffix chains resolve to the field', () => {
			expect(dropUnknownFilter({ a__b__eq: 1 }, fields)).toEqual({});
			expect(dropUnknownFilter({ expected_close_date: 5 }, fields)).toEqual({
				expected_close_date: 5
			});
		});

		it('drops keys whose field exists but has no operators', () => {
			expect(dropUnknownFilter({ title__eq: 'x' }, fields)).toEqual({});
		});

		it('returns an empty object for empty input', () => {
			expect(dropUnknownFilter({}, fields)).toEqual({});
		});
	});

	describe('buildConfig', () => {
		it('clones the authored columns for a table surface', () => {
			const draft = tableDraft();
			const cfg = buildConfig(draft);
			expect(cfg).toEqual({ columns: [{ key: 'title', label: 'Deal Title' }] });
			expect(cfg.columns![0]).not.toBe(draft.columns[0]);
		});

		it('builds the calendar config, trimming the discriminator and nulling empty values', () => {
			const draft = tableDraft({
				surface: 'calendar',
				discriminator: '  expected_close_date  ',
				endField: '',
				colorBy: 'status',
				titleTemplate: '',
				weekStart: 'sunday',
				filters: { status__eq: 'open', ghost__eq: 'x' },
				filterableFields: [field('status', 'enum', { operators: ['eq'] })]
			});
			expect(buildConfig(draft)).toEqual({
				calendar: {
					discriminator: 'expected_close_date',
					end_field: null,
					color_by: 'status',
					title_template: null,
					week_start: 'sunday',
					filters: { status__eq: 'open' }
				}
			});
		});

		it('drops stale filter keys against the draft filterable fields', () => {
			const draft = tableDraft({
				surface: 'calendar',
				discriminator: 'expected_close_date',
				filters: { title__eq: 'x' },
				filterableFields: [field('status', 'enum', { operators: ['eq'] })]
			});
			expect(buildConfig(draft).calendar?.filters).toEqual({});
		});
	});

	describe('groupableFields', () => {
		const fields = [
			field('title', 'string'),
			field('status', 'enum', { operators: ['eq'] }),
			field('completed', 'boolean', { operators: ['eq'] }),
			field('capability_less', 'enum'),
			field('text_only', 'enum', { operators: ['match', 'starts_with'] }),
			field('locked', 'enum', { read_only: true, operators: ['eq'] }),
			field('masked', 'enum', { write_only: true, operators: ['eq'] }),
			field('frozen', 'boolean', { read_only: true, operators: ['eq'] }),
			field('owner_id', 'reference')
		];

		it('keeps writable enum and boolean fields that serve eq', () => {
			expect(groupableFields(fields).map((f) => f.key)).toEqual(['status', 'completed']);
		});

		it('drops an enum without the eq operator — lanes filter field__eq', () => {
			// text_search-only operators never derive eq, capability-less ones
			// derive nothing; both would 422 every lane fetch.
			expect(groupableFields([fields[1], fields[3], fields[4]]).map((f) => f.key)).toEqual([
				'status'
			]);
		});

		it('returns an empty list when the doctype has neither enum nor boolean fields', () => {
			expect(groupableFields([field('title', 'string')])).toEqual([]);
		});
	});

	describe('buildConfig — kanban', () => {
		it('builds the values-mode config with the group-by field and page cap', () => {
			const draft = tableDraft({
				surface: 'kanban',
				kanbanMode: 'values',
				groupBy: ' status '
			});
			expect(buildConfig(draft)).toEqual({
				kanban: { mode: 'values', page_size: 25, group_by: 'status', filters: {} }
			});
		});

		it('builds the custom-mode config with cloned lanes', () => {
			const lanes = [
				{ label: 'Low', filter: { probability__lt: 50 } },
				{ label: 'High', color: '#0a86ac', filter: { probability__gte: 50 } }
			];
			const draft = tableDraft({ surface: 'kanban', kanbanMode: 'custom', lanes });
			const cfg = buildConfig(draft);
			expect(cfg.kanban?.lanes).toEqual(lanes);
			// The stored lanes are clones, not the draft's objects.
			expect(cfg.kanban?.lanes![0]).not.toBe(lanes[0]);
			expect(cfg.kanban?.lanes![0].filter).not.toBe(lanes[0].filter);
		});

		it('composes the sort entry with the - prefix for descending', () => {
			const desc = tableDraft({
				surface: 'kanban',
				kanbanMode: 'values',
				groupBy: 'status',
				sortField: 'probability',
				sortDesc: true,
				sortFields: [field('probability', 'integer')]
			});
			expect(buildConfig(desc).kanban?.sort).toEqual(['-probability']);

			const asc = tableDraft({
				surface: 'kanban',
				kanbanMode: 'values',
				groupBy: 'status',
				sortField: 'probability',
				sortDesc: false,
				sortFields: [field('probability', 'integer')]
			});
			expect(buildConfig(asc).kanban?.sort).toEqual(['probability']);
		});

		it('omits sort when unset — the surface defaults to -updated_at', () => {
			const draft = tableDraft({ surface: 'kanban', kanbanMode: 'values', groupBy: 'status' });
			expect('sort' in (buildConfig(draft).kanban ?? {})).toBe(false);
		});

		it('drops the composed sort when the sort field no longer resolves', () => {
			// A field removed from the schema (or re-typed to an unsortable
			// one) leaves the draft's sortable list — the config carries no
			// sort rather than one the backend answers 422 to.
			const draft = tableDraft({
				surface: 'kanban',
				kanbanMode: 'values',
				groupBy: 'status',
				sortField: 'probability',
				sortFields: [field('value', 'money')]
			});
			expect('sort' in (buildConfig(draft).kanban ?? {})).toBe(false);
		});

		it('drops stale base-filter keys against the draft filterable fields', () => {
			const draft = tableDraft({
				surface: 'kanban',
				kanbanMode: 'values',
				groupBy: 'status',
				filters: { status__ne: 'abandoned', ghost__eq: 'x' },
				filterableFields: [field('status', 'enum', { operators: ['eq', 'ne'] })]
			});
			expect(buildConfig(draft).kanban?.filters).toEqual({ status__ne: 'abandoned' });
		});
	});

	describe('buildPayload', () => {
		it('sets owner_id only for a personal view with a viewer', () => {
			const draft = tableDraft();
			expect(buildPayload(draft, { personal: true, viewerId: 'iam.Account.1' }).owner_id).toBe(
				'iam.Account.1'
			);
		});

		it('omits owner_id for a personal view without a viewer', () => {
			const payload = buildPayload(tableDraft(), { personal: true });
			expect('owner_id' in payload).toBe(false);
		});

		it('omits owner_id for a general view even with a viewer', () => {
			const payload = buildPayload(tableDraft(), { personal: false, viewerId: 'iam.Account.1' });
			expect('owner_id' in payload).toBe(false);
		});

		it('trims the name and carries surface + config', () => {
			const draft = tableDraft({ name: '  Padded  ' });
			const payload = buildPayload(draft, { personal: true, viewerId: 'iam.Account.1' });
			expect(payload.name).toBe('Padded');
			expect(payload.surface).toBe('table');
			expect(payload.config).toEqual({ columns: [{ key: 'title', label: 'Deal Title' }] });
		});
	});

	describe('validateDraft', () => {
		it('accepts a valid table draft', () => {
			expect(validateDraft(tableDraft())).toEqual({
				nameError: null,
				columnsError: null,
				discriminatorError: null,
				endFieldError: null,
				groupByError: null,
				lanesError: null,
				laneErrors: [],
				canSave: true
			});
		});

		it('requires a non-blank name', () => {
			const out = validateDraft(tableDraft({ name: '   ' }));
			expect(out.nameError).toBeTruthy();
			expect(out.canSave).toBe(false);
		});

		it('requires at least one column on the table surface', () => {
			const out = validateDraft(tableDraft({ columns: [] }));
			expect(out.columnsError).toBeTruthy();
			expect(out.canSave).toBe(false);
		});

		it('requires a discriminator only on the calendar surface', () => {
			const table = validateDraft(tableDraft({ discriminator: '' }));
			expect(table.discriminatorError).toBeNull();

			const calendar = validateDraft(tableDraft({ surface: 'calendar' }));
			expect(calendar.discriminatorError).toBeTruthy();
			expect(calendar.canSave).toBe(false);

			const calendarOk = validateDraft(
				tableDraft({ surface: 'calendar', discriminator: 'expected_close_date' })
			);
			expect(calendarOk.canSave).toBe(true);
		});

		it('rejects a discriminator whose field cannot serve the window filter', () => {
			// Edit mode loads the stored key; a field that lost its `filters:`
			// capability (or only carries equality) cannot window the calendar.
			const out = validateDraft(tableDraft({ surface: 'calendar', discriminator: 'owner_id' }));
			expect(out.discriminatorError).toBeTruthy();
			expect(out.canSave).toBe(false);

			// A period discriminator needs no operators — the native range path
			// emits no window filter.
			const fields = [...FLAT_FIELDS, field('window', 'period')];
			const period = validateDraft(
				tableDraft({ surface: 'calendar', discriminator: 'window', fields })
			);
			expect(period.discriminatorError).toBeNull();
			expect(period.canSave).toBe(true);
		});

		it('rejects an end field without the gte operator', () => {
			const fields = [...FLAT_FIELDS, field('other_date', 'date')];
			const out = validateDraft(
				tableDraft({
					surface: 'calendar',
					discriminator: 'expected_close_date',
					endField: 'other_date',
					fields
				})
			);
			expect(out.endFieldError).toBeTruthy();
			expect(out.canSave).toBe(false);

			const ok = validateDraft(
				tableDraft({
					surface: 'calendar',
					discriminator: 'expected_close_date',
					endField: 'other_date',
					fields: [...FLAT_FIELDS, field('other_date', 'date', { operators: ['gte'] })]
				})
			);
			expect(ok.endFieldError).toBeNull();
			expect(ok.canSave).toBe(true);
		});

		it('does not check the end field while the discriminator is missing', () => {
			const out = validateDraft(
				tableDraft({ surface: 'calendar', discriminator: '', endField: 'ghost' })
			);
			expect(out.discriminatorError).toBeTruthy();
			expect(out.endFieldError).toBeNull();
		});

		it('does not require columns on the calendar surface', () => {
			const out = validateDraft(
				tableDraft({ surface: 'calendar', discriminator: 'expected_close_date', columns: [] })
			);
			expect(out.columnsError).toBeTruthy();
			expect(out.canSave).toBe(true);
		});

		it('requires a group-by field only on the kanban values mode', () => {
			const missing = validateDraft(tableDraft({ surface: 'kanban', kanbanMode: 'values' }));
			expect(missing.groupByError).toBeTruthy();
			expect(missing.canSave).toBe(false);

			const ok = validateDraft(
				tableDraft({ surface: 'kanban', kanbanMode: 'values', groupBy: 'status' })
			);
			expect(ok.groupByError).toBeNull();
			expect(ok.canSave).toBe(true);

			// Custom mode has no group-by requirement.
			const custom = validateDraft(tableDraft({ surface: 'kanban', kanbanMode: 'custom' }));
			expect(custom.groupByError).toBeNull();
		});

		it('rejects a group-by field whose field cannot serve the lanes eq filter', () => {
			// Edit mode loads the stored key; a capability-less (or read-only)
			// field would 422 every lane fetch.
			const capabilityLess = validateDraft(
				tableDraft({ surface: 'kanban', kanbanMode: 'values', groupBy: 'owner_id' })
			);
			expect(capabilityLess.groupByError).toBeTruthy();
			expect(capabilityLess.canSave).toBe(false);

			const readOnly = validateDraft(
				tableDraft({
					surface: 'kanban',
					kanbanMode: 'values',
					groupBy: 'locked',
					fields: [...FLAT_FIELDS, field('locked', 'enum', { read_only: true, operators: ['eq'] })]
				})
			);
			expect(readOnly.groupByError).toBeTruthy();
		});

		it('requires at least one lane on the kanban custom mode', () => {
			const out = validateDraft(tableDraft({ surface: 'kanban', kanbanMode: 'custom', lanes: [] }));
			expect(out.lanesError).toBeTruthy();
			expect(out.canSave).toBe(false);
		});

		it('surfaces per-lane errors and blocks save while any is present', () => {
			const lanes = [
				{ label: '', filter: {} },
				{ label: 'Same', filter: { probability__lt: 50 } },
				{ label: 'Same', filter: { probability__gte: 50 } }
			];
			const out = validateDraft(tableDraft({ surface: 'kanban', kanbanMode: 'custom', lanes }));
			expect(out.lanesError).toBeNull();
			// Lane 0: label + filter errors; lane 2: duplicate label error.
			expect(out.laneErrors.map((e) => e.index)).toEqual([0, 0, 2]);
			expect(out.canSave).toBe(false);

			const ok = validateDraft(
				tableDraft({
					surface: 'kanban',
					kanbanMode: 'custom',
					lanes: [
						{ label: 'Low', filter: { probability__lt: 50 } },
						{ label: 'High', filter: { probability__gte: 50 } }
					]
				})
			);
			expect(ok.laneErrors).toEqual([]);
			expect(ok.canSave).toBe(true);
		});
	});
});
