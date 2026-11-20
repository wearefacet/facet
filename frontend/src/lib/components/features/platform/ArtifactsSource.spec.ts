// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	buildArtifactsQuery,
	listArtifacts,
	listArtifactGrants,
	listArtifactReferences,
	revokeArtifactGrant,
	purgeArtifact,
	ArtifactsError,
	formatArtifactSize
} from './ArtifactsSource.js';

// ── Helpers ───────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function fetchStub(body: unknown, status = 200) {
	return vi.fn(async () => jsonResponse(body, status)) as unknown as typeof fetch;
}

const SAMPLE_ARTIFACTS = {
	data: [
		{
			id: '01ART1',
			filename: 'logo.png',
			mime_type: 'image/png',
			size: 2048,
			sha256: 'abc123',
			deleted_at: null,
			created_at: '2026-01-10T08:00:00Z',
			uploaded_by: 'account_kim',
			owner_count: 2,
			grant_count: 1,
			reference_count: 3
		}
	],
	meta: { count: 1, more: false }
};

const SAMPLE_GRANTS = {
	data: [
		{
			id: '01GRANT1',
			artifact_id: '01ART1',
			owner_id: '01OWNER1',
			kind: 'permanent',
			expires_at: null,
			epoch: 0,
			created_by: 'op',
			created_at: '2026-01-10T09:00:00Z'
		}
	],
	meta: { count: 1, more: false }
};

const SAMPLE_REFERENCES = {
	data: [
		{
			domain: 'hr',
			doc_type: 'Employee',
			resource_id: '01DOC1',
			display_name: 'Alice',
			resource_field: 'avatar',
			last_reference_at: '2026-01-10T10:00:00Z'
		}
	],
	meta: { count: 1, more: false }
};

// ── buildArtifactsQuery ───────────────────────────────────────────────────

describe('buildArtifactsQuery', () => {
	it('builds page, items, and sort params', () => {
		const qs = buildArtifactsQuery({ page: 2, items: 25, sort: ['-created_at'] });
		expect(qs).toContain('page=2');
		expect(qs).toContain('items=25');
		expect(qs).toContain('sort=-created_at');
	});

	it('maps filters to filters[key] params', () => {
		const qs = buildArtifactsQuery({ filters: { filename__match: 'logo', deleted__eq: 'true' } });
		expect(qs).toContain('filters%5Bfilename__match%5D=logo');
		expect(qs).toContain('filters%5Bdeleted__eq%5D=true');
	});

	it('JSON-encodes an array filter value', () => {
		const qs = buildArtifactsQuery({ filters: { size__between: [100, 5000] } });
		expect(qs).toContain(
			`filters%5Bsize__between%5D=${encodeURIComponent(JSON.stringify([100, 5000]))}`
		);
	});

	it('skips empty and null filter values', () => {
		const qs = buildArtifactsQuery({ filters: { filename__match: '', deleted__eq: null } });
		expect(qs).toBe('');
	});

	it('returns an empty string for empty params', () => {
		expect(buildArtifactsQuery({})).toBe('');
	});
});

// ── listArtifacts ─────────────────────────────────────────────────────────

describe('listArtifacts', () => {
	it('calls GET /Api/Artifacts and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_ARTIFACTS);
		const res = await listArtifacts({ page: 1, items: 25 }, fetchFn);
		expect(res).toEqual(SAMPLE_ARTIFACTS);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Artifacts?page=1&items=25');
	});

	it('omits the question mark when no params are given', async () => {
		const fetchFn = fetchStub(SAMPLE_ARTIFACTS);
		await listArtifacts({}, fetchFn);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Artifacts');
	});

	it('throws an ArtifactsError with the status on failure', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(listArtifacts({}, fetchFn)).rejects.toMatchObject({
			name: 'ArtifactsError',
			status: 403,
			message: 'Forbidden'
		});
	});
});

// ── per-artifact listings ─────────────────────────────────────────────────

describe('listArtifactGrants', () => {
	it('calls the grants sub-resource and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_GRANTS);
		const res = await listArtifactGrants('01ART1', fetchFn);
		expect(res).toEqual(SAMPLE_GRANTS);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Artifacts/01ART1/grants');
	});

	it('throws an ArtifactsError with the status on 404', async () => {
		const fetchFn = fetchStub({ error: 'Artifact not found' }, 404);
		await expect(listArtifactGrants('01X', fetchFn)).rejects.toMatchObject({ status: 404 });
	});
});

describe('listArtifactReferences', () => {
	it('calls the references sub-resource and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_REFERENCES);
		const res = await listArtifactReferences('01ART1', fetchFn);
		expect(res).toEqual(SAMPLE_REFERENCES);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Artifacts/01ART1/references');
	});
});

// ── revoke ────────────────────────────────────────────────────────────────

describe('revokeArtifactGrant', () => {
	it('DELETEs the shared grant route and resolves on 204', async () => {
		const fetchFn = vi.fn(
			async () => new Response(null, { status: 204 })
		) as unknown as typeof fetch;
		await expect(revokeArtifactGrant('01GRANT1', fetchFn)).resolves.toBeUndefined();
		expect(fetchFn).toHaveBeenCalledWith('/Api/core/artifacts/grants/01GRANT1', {
			method: 'DELETE'
		});
	});

	it('throws an ArtifactsError with the status on 403', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(revokeArtifactGrant('01GRANT1', fetchFn)).rejects.toMatchObject({
			status: 403
		});
	});
});

// ── force delete ─────────────────────────────────────────────────────────

describe('purgeArtifact', () => {
	it('DELETEs the admin route with the CSRF header and the reason body', async () => {
		const fetchFn = vi.fn(
			async () => new Response(null, { status: 204 })
		) as unknown as typeof fetch;
		await expect(purgeArtifact('01ART1', 'security incident', fetchFn)).resolves.toBeUndefined();
		expect(fetchFn).toHaveBeenCalledWith('/Api/Artifacts/01ART1', {
			method: 'DELETE',
			headers: {
				'X-Requested-With': 'XMLHttpRequest',
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({ reason: 'security incident' })
		});
	});

	it('throws an ArtifactsError with the status on 404', async () => {
		const fetchFn = fetchStub({ error: 'Artifact not found' }, 404);
		await expect(purgeArtifact('01X', '', fetchFn)).rejects.toMatchObject({ status: 404 });
	});
});

// ── formatting ────────────────────────────────────────────────────────────

describe('formatArtifactSize', () => {
	it('renders bytes verbatim below 1 KiB', () => {
		expect(formatArtifactSize(512)).toBe('512 B');
	});

	it('renders KiB / MB with one decimal', () => {
		expect(formatArtifactSize(2048)).toBe('2.0 KB');
		expect(formatArtifactSize(5 * 1024 * 1024)).toBe('5.0 MB');
	});

	it('rounds large values to integers', () => {
		expect(formatArtifactSize(1500 * 1024 * 1024)).toBe('1.5 GB');
		expect(formatArtifactSize(900 * 1024 * 1024)).toBe('900 MB');
	});
});

describe('ArtifactsError', () => {
	it('carries the HTTP status', () => {
		const err = new ArtifactsError(403, 'Forbidden');
		expect(err.status).toBe(403);
		expect(err.message).toBe('Forbidden');
	});
});
