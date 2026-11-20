// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	buildJobsQuery,
	fetchMaintenanceStatus,
	enqueueReproject,
	enqueueMigrateAhead,
	listMaintenanceJobs,
	extractJobStats,
	MaintenanceError,
	type MaintenanceJobRow,
	type MaintenanceJobsResponse,
	type MaintenanceStatus
} from './MaintenanceSource.js';

// ── Helpers ───────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function fetchStub(body: unknown, status = 200) {
	return vi.fn(async (_input: string, _init?: RequestInit) => jsonResponse(body, status));
}

const SAMPLE_STATUS: MaintenanceStatus = {
	doctype_id: 'crm.Company',
	current_version: 3,
	ahead_count: 12,
	blocked_count: 2
};

const SAMPLE_JOBS: MaintenanceJobsResponse = {
	data: [
		{
			id: '01JOB1',
			kind: 'doctype_reproject',
			status: 'succeeded',
			attempts: 1,
			max_attempts: 3,
			last_error: null,
			result: {
				total: 30,
				processed: 24,
				superseded: 3,
				skipped: 2,
				failed: 1,
				failed_ids: ['01DOC9']
			},
			account_id: '01ACC1',
			role_id: '01ROLE1',
			created_at: '2026-01-10T08:00:00Z',
			updated_at: '2026-01-10T08:01:00Z'
		}
	],
	meta: { count: 1, more: false, page: 1 }
};

function jobRow(overrides: Partial<MaintenanceJobRow>): MaintenanceJobRow {
	return {
		id: '01JOBX',
		kind: 'doctype_reproject',
		status: 'pending',
		attempts: 0,
		max_attempts: 3,
		last_error: null,
		result: null,
		account_id: null,
		role_id: null,
		created_at: '2026-01-10T08:00:00Z',
		updated_at: '2026-01-10T08:00:00Z',
		...overrides
	};
}

// ── buildJobsQuery ────────────────────────────────────────────────────────

describe('buildJobsQuery', () => {
	it('builds page and items params', () => {
		const qs = buildJobsQuery({ page: 3, items: 25 });
		expect(qs).toContain('page=3');
		expect(qs).toContain('items=25');
	});

	it('returns an empty string for empty params', () => {
		expect(buildJobsQuery({})).toBe('');
	});
});

// ── fetchMaintenanceStatus ────────────────────────────────────────────────

describe('fetchMaintenanceStatus', () => {
	it('calls GET maintenance_status and returns the parsed status', async () => {
		const fetchFn = fetchStub(SAMPLE_STATUS);
		const res = await fetchMaintenanceStatus('crm.Company', fetchFn);
		expect(res).toEqual(SAMPLE_STATUS);
		expect(fetchFn).toHaveBeenCalledWith('/Api/core/DocType/crm.Company/maintenance_status');
	});

	it('throws a MaintenanceError with the backend message on 404', async () => {
		const fetchFn = fetchStub({ error: 'unknown doctype' }, 404);
		await expect(fetchMaintenanceStatus('nope.Missing', fetchFn)).rejects.toMatchObject({
			name: 'MaintenanceError',
			status: 404,
			message: 'unknown doctype'
		});
	});

	it('maps a 403 to a MaintenanceError with status 403', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(fetchMaintenanceStatus('crm.Company', fetchFn)).rejects.toMatchObject({
			status: 403
		});
	});
});

// ── enqueueReproject / enqueueMigrateAhead ───────────────────────────────

describe('enqueueReproject', () => {
	it('POSTs an empty JSON body and returns the job handle', async () => {
		const fetchFn = fetchStub({ job_id: '01JOB1', status_url: '/Api/Jobs/01JOB1' }, 202);
		const res = await enqueueReproject('crm.Company', fetchFn);
		expect(res).toEqual({ job_id: '01JOB1', status_url: '/Api/Jobs/01JOB1' });
		expect(fetchFn).toHaveBeenCalledTimes(1);
		const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit];
		expect(url).toBe('/Api/core/DocType/crm.Company/reproject');
		expect(init.method).toBe('POST');
		expect(init.body).toBe('{}');
		expect((init.headers as Record<string, string>)['Content-Type']).toBe('application/json');
	});

	it('surfaces the 409 message naming the blocking kind', async () => {
		const fetchFn = fetchStub(
			{ error: 'a doctype_reproject job is already pending for crm.Company' },
			409
		);
		await expect(enqueueReproject('crm.Company', fetchFn)).rejects.toMatchObject({
			status: 409,
			message: 'a doctype_reproject job is already pending for crm.Company'
		});
	});

	it('maps a 422 (preview mode) to a MaintenanceError', async () => {
		const fetchFn = fetchStub({ error: 'preview doctypes cannot run jobs' }, 422);
		await expect(enqueueReproject('crm.Company', fetchFn)).rejects.toMatchObject({ status: 422 });
	});
});

describe('enqueueMigrateAhead', () => {
	it('POSTs to the migrate_ahead route with the same body contract', async () => {
		const fetchFn = fetchStub({ job_id: '01JOB2', status_url: '/Api/Jobs/01JOB2' }, 202);
		await enqueueMigrateAhead('crm.Company', fetchFn);
		const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit];
		expect(url).toBe('/Api/core/DocType/crm.Company/migrate_ahead');
		expect(init.method).toBe('POST');
		expect(init.body).toBe('{}');
	});

	it('maps other failures to a MaintenanceError with the status', async () => {
		const fetchFn = fetchStub({}, 500);
		await expect(enqueueMigrateAhead('crm.Company', fetchFn)).rejects.toMatchObject({
			status: 500
		});
	});
});

// ── listMaintenanceJobs ───────────────────────────────────────────────────

describe('listMaintenanceJobs', () => {
	it('calls GET maintenance_jobs with page and items and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_JOBS);
		const res = await listMaintenanceJobs('crm.Company', { page: 2, items: 50 }, fetchFn);
		expect(res).toEqual(SAMPLE_JOBS);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/DocType/crm.Company/maintenance_jobs?page=2&items=50'
		);
	});

	it('omits the question mark when no params are given', async () => {
		const fetchFn = fetchStub(SAMPLE_JOBS);
		await listMaintenanceJobs('crm.Company', {}, fetchFn);
		expect(fetchFn).toHaveBeenCalledWith('/Api/core/DocType/crm.Company/maintenance_jobs');
	});

	it('throws a MaintenanceError with the status on failure', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(listMaintenanceJobs('crm.Company', {}, fetchFn)).rejects.toMatchObject({
			name: 'MaintenanceError',
			status: 403,
			message: 'Forbidden'
		});
	});
});

// ── extractJobStats ───────────────────────────────────────────────────────

describe('extractJobStats', () => {
	it('extracts reproject stats from the result payload', () => {
		const row = jobRow({
			status: 'succeeded',
			result: {
				total: 30,
				processed: 24,
				superseded: 3,
				skipped: 2,
				failed: 1,
				failed_ids: ['01A', '01B']
			}
		});
		expect(extractJobStats(row)).toEqual({
			processed: 24,
			migrated: null,
			superseded: 3,
			skipped: 2,
			failed: 1,
			total: 30,
			batches: null,
			failedIds: ['01A', '01B']
		});
	});

	it('extracts migrate stats including batches', () => {
		const row = jobRow({
			kind: 'doctype_migrate_ahead',
			status: 'succeeded',
			result: {
				total: 12,
				migrated: 9,
				superseded: 1,
				skipped: 1,
				failed: 1,
				batches: 2,
				failed_ids: []
			}
		});
		const stats = extractJobStats(row);
		expect(stats?.migrated).toBe(9);
		expect(stats?.batches).toBe(2);
	});

	it('returns null when the row has no result payload', () => {
		expect(extractJobStats(jobRow({ status: 'pending', result: null }))).toBeNull();
	});

	it('returns null when the result carries no meaningful field', () => {
		expect(extractJobStats(jobRow({ status: 'failed', result: { unrelated: 'x' } }))).toBeNull();
	});

	it('drops non-string entries from failed_ids', () => {
		const row = jobRow({
			status: 'succeeded',
			result: { failed: 2, failed_ids: ['01A', 42, null] }
		});
		expect(extractJobStats(row)?.failedIds).toEqual(['01A']);
	});

	it('treats non-numeric stat fields as absent', () => {
		const row = jobRow({ status: 'succeeded', result: { processed: 'many', skipped: 4 } });
		const stats = extractJobStats(row);
		expect(stats?.processed).toBeNull();
		expect(stats?.skipped).toBe(4);
	});
});

// ── MaintenanceError ──────────────────────────────────────────────────────

describe('MaintenanceError', () => {
	it('carries the HTTP status', () => {
		const err = new MaintenanceError(409, 'Conflict');
		expect(err.status).toBe(409);
		expect(err.message).toBe('Conflict');
	});
});
