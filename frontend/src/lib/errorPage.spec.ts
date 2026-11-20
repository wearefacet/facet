// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { documentHistoryParams, errorPageKind } from './errorPage.js';

describe('errorPageKind', () => {
	it('renders a tracked 404 as the not-found page', () => {
		expect(errorPageKind({ pageStatus: 404, message: 'Doctype iam.Employee not found' })).toBe(
			'404'
		);
	});

	it('renders a tracked 410 as the deleted page', () => {
		expect(errorPageKind({ pageStatus: 410, message: 'Document "X" was deleted' })).toBe('410');
	});

	it('renders a tracked 500 as the server-error page', () => {
		expect(errorPageKind({ pageStatus: 500, message: 'Internal Error' })).toBe('500');
	});

	it('renders any other tracked status as the server-error page', () => {
		expect(errorPageKind({ pageStatus: 403, message: 'Forbidden' })).toBe('500');
		expect(errorPageKind({ pageStatus: 400, message: 'Bad Request' })).toBe('500');
		expect(errorPageKind({ pageStatus: 502, message: 'Could not reach the app registry.' })).toBe(
			'500'
		);
	});

	it('never lets message text override a known status', () => {
		// The error-boundary regression: a genuine 500 whose message mentions “not found”
		// must stay a server error.
		expect(
			errorPageKind({ pageStatus: 500, message: 'Registry not found: connection refused' })
		).toBe('500');
	});

	it('falls back to the message check only when no status is usable', () => {
		expect(errorPageKind({ pageStatus: 200, message: 'Doctype iam.Employee not found' })).toBe(
			'404'
		);
		expect(errorPageKind({ pageStatus: 200, message: 'Domain hr not found' })).toBe('404');
		expect(errorPageKind({ pageStatus: 200, message: 'Failed to fetch' })).toBe('500');
		expect(errorPageKind({ pageStatus: 200 })).toBe('500');
	});

	it('prefers a status carried on the error body over the tracked one', () => {
		expect(errorPageKind({ errorStatus: 404, pageStatus: 500, message: 'Not found' })).toBe('404');
		expect(errorPageKind({ errorStatus: 410, pageStatus: 500, message: 'Deleted' })).toBe('410');
		expect(errorPageKind({ errorStatus: 403, pageStatus: 404, message: 'Forbidden' })).toBe('500');
	});
});

describe('documentHistoryParams', () => {
	const params = { domain: 'hr', doctype: 'Employee', id: '06FWRBQTR87M2CBBMQN61CEBZ2' };

	it('returns the document triple for the show and edit routes', () => {
		expect(documentHistoryParams('/[domain=notApi]/[doctype]/[id]', params)).toEqual(params);
		expect(documentHistoryParams('/[domain=notApi]/[doctype]/[id]/edit', params)).toEqual(params);
	});

	it('returns undefined for other routes and a missing route context', () => {
		expect(documentHistoryParams('/[domain=notApi]/[doctype]', params)).toBeUndefined();
		expect(
			documentHistoryParams('/[domain=notApi]/[doctype]/[id]/history', params)
		).toBeUndefined();
		expect(documentHistoryParams(null, params)).toBeUndefined();
	});

	it('returns undefined when the router rendered the error page without params', () => {
		expect(documentHistoryParams('/[domain=notApi]/[doctype]/[id]', {})).toBeUndefined();
		expect(
			documentHistoryParams('/[domain=notApi]/[doctype]/[id]', {
				domain: 'hr',
				doctype: 'Employee'
			})
		).toBeUndefined();
	});
});
