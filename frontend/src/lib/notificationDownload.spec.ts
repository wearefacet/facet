// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { notificationDownloadUrl } from './notificationDownload.js';

describe('notificationDownloadUrl', () => {
	it('returns the download path of a matching notification', () => {
		expect(
			notificationDownloadUrl({
				data: { download: '/Api/crm/Company/import_export/j1/download' }
			})
		).toBe('/Api/crm/Company/import_export/j1/download');
	});

	it('returns null without data or without the key', () => {
		expect(notificationDownloadUrl({})).toBeNull();
		expect(notificationDownloadUrl({ data: {} })).toBeNull();
		expect(notificationDownloadUrl({ data: { other: '/x' } })).toBeNull();
		expect(notificationDownloadUrl(null)).toBeNull();
		expect(notificationDownloadUrl(undefined)).toBeNull();
	});

	it('returns null for a non-string value', () => {
		expect(notificationDownloadUrl({ data: { download: 42 } })).toBeNull();
		expect(notificationDownloadUrl({ data: { download: null } })).toBeNull();
		expect(notificationDownloadUrl({ data: { download: { href: '/Api/x' } } })).toBeNull();
	});

	it('returns null for an empty value', () => {
		expect(notificationDownloadUrl({ data: { download: '' } })).toBeNull();
	});

	it('rejects absolute and protocol-relative URLs — the field is producer-writable', () => {
		expect(notificationDownloadUrl({ data: { download: 'https://evil.example/file' } })).toBeNull();
		expect(notificationDownloadUrl({ data: { download: 'javascript:alert(1)' } })).toBeNull();
		expect(notificationDownloadUrl({ data: { download: '//evil.example/file' } })).toBeNull();
		// The URL parser reads a backslash as a slash, so `/\` is
		// protocol-relative too.
		expect(notificationDownloadUrl({ data: { download: '/\\evil.example/file' } })).toBeNull();
	});
});
