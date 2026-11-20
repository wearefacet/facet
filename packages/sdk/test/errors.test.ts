// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	ApiError,
	AuthError,
	DeletedError,
	NetworkError,
	NotFoundError,
	normalizeDetails
} from '../src/errors.js';

describe('ApiError subclasses', () => {
	it('keeps status, details, and meta on the base class', () => {
		const error = new ApiError('HTTP 422 from /Api/crm/Company: validation_failed', 422, [
			{ message: 'name is required' }
		]);
		expect(error).toBeInstanceOf(Error);
		expect(error.status).toBe(422);
		expect(error.details).toEqual([{ message: 'name is required' }]);
		expect(error.meta).toEqual({});
		expect(error.name).toBe('ApiError');
	});

	it('raises NotFoundError with status 404', () => {
		const error = new NotFoundError('HTTP 404 from /Api/crm/Company/x: unknown_document');
		expect(error).toBeInstanceOf(ApiError);
		expect(error.status).toBe(404);
		expect(error.name).toBe('NotFoundError');
	});

	it('raises DeletedError with status 410 and tombstone fields from meta', () => {
		const error = new DeletedError('HTTP 410 from /Api/crm/Company/x: deleted', {
			display_name: 'Acme Corp',
			deleted_at: '2026-01-01T12:00:00Z'
		});
		expect(error).toBeInstanceOf(ApiError);
		expect(error.status).toBe(410);
		expect(error.displayName).toBe('Acme Corp');
		expect(error.deletedAt).toBe('2026-01-01T12:00:00Z');
		expect(error.meta).toEqual({
			display_name: 'Acme Corp',
			deleted_at: '2026-01-01T12:00:00Z'
		});
	});

	it('leaves the tombstone fields null when meta carries none', () => {
		const error = new DeletedError('HTTP 410 from /Api/crm/Company/x: deleted');
		expect(error.displayName).toBeNull();
		expect(error.deletedAt).toBeNull();
	});

	it('raises AuthError and NetworkError with status 0', () => {
		const auth = new AuthError('No credential is available for this request.');
		const network = new NetworkError('Cannot reach https://facet.example.com: fetch failed');
		expect(auth).toBeInstanceOf(ApiError);
		expect(auth.status).toBe(0);
		expect(network).toBeInstanceOf(ApiError);
		expect(network.status).toBe(0);
	});
});

describe('normalizeDetails', () => {
	it('accepts plain string items', () => {
		expect(normalizeDetails(['slug is taken', 'note is too long'])).toEqual([
			{ message: 'slug is taken' },
			{ message: 'note is too long' }
		]);
	});

	it('accepts {message} items', () => {
		expect(normalizeDetails([{ message: 'revision is read-only' }])).toEqual([
			{ message: 'revision is read-only' }
		]);
	});

	it('keeps the structured shape of a 422 item', () => {
		expect(
			normalizeDetails([
				{ field: 'name', message: 'name is required', code: 'required', params: { max: '3' } }
			])
		).toEqual([
			{ field: 'name', message: 'name is required', code: 'required', params: { max: '3' } }
		]);
	});

	it('drops unknown key types from a structured item', () => {
		expect(normalizeDetails([{ message: 'no good', field: 42, params: 'junk' }])).toEqual([
			{ message: 'no good' }
		]);
	});

	it('stringifies items it cannot read', () => {
		expect(normalizeDetails([42, { odd: true }])).toEqual([
			{ message: '42' },
			{ message: '{"odd":true}' }
		]);
	});

	it('returns an empty array when details are absent', () => {
		expect(normalizeDetails(undefined)).toEqual([]);
	});
});
