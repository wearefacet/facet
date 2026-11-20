// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { buildLoginRedirect } from './loginRedirect.js';

describe('buildLoginRedirect', () => {
	it('keeps an app path as the return target', () => {
		expect(buildLoginRedirect('/hr/Employee')).toBe('/Login?redirectTo=%2Fhr%2FEmployee');
	});

	it('keeps the path and the query string', () => {
		const url = buildLoginRedirect('/_abc123/MachineType?page=2');
		expect(url.startsWith('/Login?redirectTo=')).toBe(true);
		expect(decodeURIComponent(url)).toBe('/Login?redirectTo=/_abc123/MachineType?page=2');
	});

	it('falls back to / for an empty path', () => {
		expect(buildLoginRedirect('')).toBe('/Login?redirectTo=%2F');
	});

	it('falls back to / for a target that is not root-relative', () => {
		expect(buildLoginRedirect('https://evil.example')).toBe('/Login?redirectTo=%2F');
	});

	it('falls back to / for a protocol-relative target', () => {
		expect(buildLoginRedirect('//evil.example')).toBe('/Login?redirectTo=%2F');
	});

	it('falls back to / when the target is the login page itself', () => {
		expect(buildLoginRedirect('/Login')).toBe('/Login?redirectTo=%2F');
		expect(buildLoginRedirect('/Login?redirectTo=/x')).toBe('/Login?redirectTo=%2F');
	});
});
