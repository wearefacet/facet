// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { ensureAbsoluteUrl, hasUrlScheme, urlAdornment, urlFieldError } from './urlValue.js';

describe('hasUrlScheme', () => {
	it('detects http and https schemes', () => {
		expect(hasUrlScheme('https://www.acme.com')).toBe(true);
		expect(hasUrlScheme('http://www.acme.com')).toBe(true);
	});

	it('detects an uppercase scheme', () => {
		expect(hasUrlScheme('HTTPS://www.acme.com')).toBe(true);
	});

	it('rejects a bare host and a host:port pair', () => {
		expect(hasUrlScheme('www.acme.com')).toBe(false);
		expect(hasUrlScheme('localhost:3000')).toBe(false);
		expect(hasUrlScheme('')).toBe(false);
	});
});

describe('ensureAbsoluteUrl', () => {
	it('prepends the default scheme to a dotted bare host (B-294)', () => {
		expect(ensureAbsoluteUrl('www.acme.com')).toBe('https://www.acme.com');
		expect(ensureAbsoluteUrl('acme.io')).toBe('https://acme.io');
	});

	it('keeps a path, query, and port on the bare host', () => {
		expect(ensureAbsoluteUrl('www.acme.com/path?q=1')).toBe('https://www.acme.com/path?q=1');
		expect(ensureAbsoluteUrl('www.acme.com:8443')).toBe('https://www.acme.com:8443');
	});

	it('does not complete a dotless scheme-less value (B-294)', () => {
		// Free text that reads like a host and single-label hosts must carry
		// their scheme explicitly — the value passes through and the gate
		// (frontend) and the backend 422 refuse it.
		expect(ensureAbsoluteUrl('not-a-url')).toBe('not-a-url');
		expect(ensureAbsoluteUrl('localhost:3000')).toBe('localhost:3000');
	});

	it('does not complete a stray-punctuation authority (B-174)', () => {
		expect(ensureAbsoluteUrl('ht!tp://bad url')).toBe('ht!tp://bad url');
	});

	it('keeps an absolute value untouched (http or https)', () => {
		expect(ensureAbsoluteUrl('https://www.acme.com')).toBe('https://www.acme.com');
		expect(ensureAbsoluteUrl('http://insecure.example')).toBe('http://insecure.example');
	});

	it('keeps a non-web scheme untouched — the gate refuses it', () => {
		expect(ensureAbsoluteUrl('ftp://example.com')).toBe('ftp://example.com');
	});

	it('trims whitespace around a bare host', () => {
		expect(ensureAbsoluteUrl('  www.acme.com  ')).toBe('https://www.acme.com');
	});

	it('trims an absolute value without re-prepending', () => {
		expect(ensureAbsoluteUrl('  https://www.acme.com  ')).toBe('https://www.acme.com');
	});

	it('prepends a caller-supplied scheme', () => {
		expect(ensureAbsoluteUrl('www.acme.com', 'http://')).toBe('http://www.acme.com');
	});

	it('collapses empty and whitespace-only values to an empty string', () => {
		expect(ensureAbsoluteUrl('')).toBe('');
		expect(ensureAbsoluteUrl('   ')).toBe('');
	});
});

describe('urlAdornment', () => {
	it('shows the implied scheme while the text carries none', () => {
		expect(urlAdornment('www.acme.com')).toBe('https://');
		expect(urlAdornment('www.acme.com/path?q=1')).toBe('https://');
	});

	it('shows the scheme on an empty field too — it reads as a url before typing', () => {
		expect(urlAdornment('')).toBe('https://');
		expect(urlAdornment(undefined)).toBe('https://');
	});

	it('drops the chrome once the value self-describes with any scheme', () => {
		expect(urlAdornment('https://www.acme.com')).toBeUndefined();
		expect(urlAdornment('http://insecure.example')).toBeUndefined();
	});

	it('prepends a caller-supplied scheme, mirroring ensureAbsoluteUrl', () => {
		expect(urlAdornment('www.acme.com', 'http://')).toBe('http://');
		expect(urlAdornment('http://insecure.example', 'http://')).toBeUndefined();
	});
});

describe('urlFieldError', () => {
	it('accepts absolute http and https values', () => {
		expect(urlFieldError('https://www.acme.com')).toBeNull();
		expect(urlFieldError('http://insecure.example/path?q=1')).toBeNull();
	});

	it('accepts localhost, IPv4, and bracketed IPv6 hosts', () => {
		expect(urlFieldError('https://localhost:3000')).toBeNull();
		expect(urlFieldError('https://192.168.1.10/x')).toBeNull();
		expect(urlFieldError('https://[2001:db8::1]:8443/x')).toBeNull();
	});

	it('accepts an underscore host (the backend set is lenient too)', () => {
		expect(urlFieldError('https://my_server.local/x')).toBeNull();
	});

	it('treats blank as a cleared field, never an error', () => {
		expect(urlFieldError('')).toBeNull();
	});

	it('rejects a host with a space (B-174)', () => {
		expect(urlFieldError('https://exa mple.test/x')).not.toBeNull();
	});

	it('rejects the prefixed scheme-lookalike the widget would otherwise store (B-174)', () => {
		// `ht!tp://bad url` does not match the scheme pattern and has no
		// dotted host, so completion passes it through — the raw form must
		// fail validation, not a mangled prefixed one.
		expect(urlFieldError(ensureAbsoluteUrl('ht!tp://bad url'))).not.toBeNull();
		expect(urlFieldError('https://ht!tp://bad url')).not.toBeNull();
	});

	it('rejects a non-web scheme', () => {
		expect(urlFieldError('javascript:alert(1)')).not.toBeNull();
		expect(urlFieldError('ftp://example.com')).not.toBeNull();
	});

	it('rejects a relative path and free text', () => {
		expect(urlFieldError('/foo/bar')).not.toBeNull();
		expect(urlFieldError('not a url')).not.toBeNull();
	});

	it('rejects an empty authority even though WHATWG URL parses it', () => {
		// `new URL('https:///foo/bar')` parses with hostname "foo" — the
		// backend's empty-host refusal is mirrored up front.
		expect(urlFieldError('https:///foo/bar')).not.toBeNull();
	});

	it('rejects a value that stays scheme-less after completion (B-294)', () => {
		// The gate runs on the post-ensureAbsoluteUrl form: a dotless host
		// is never completed, so it is refused exactly like the backend.
		expect(urlFieldError(ensureAbsoluteUrl('not-a-url'))).not.toBeNull();
		expect(urlFieldError(ensureAbsoluteUrl('localhost:3000'))).not.toBeNull();
	});
});
