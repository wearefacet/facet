// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	ARTIFACT_URN_PREFIX,
	artifactUrn,
	artifactDownloadUrl,
	parseArtifactUrn,
	resolveArtifactUrl
} from './artifacts.js';

describe('artifacts — URN helpers', () => {
	it('round-trips an artifact id through the URN', () => {
		const id = '01HZZZZZZZZZZZZZZZZZZZZZZZ';
		expect(artifactUrn(id)).toBe(`${ARTIFACT_URN_PREFIX}${id}`);
		expect(parseArtifactUrn(artifactUrn(id))).toBe(id);
	});

	it('returns null for non-URN and malformed inputs', () => {
		expect(parseArtifactUrn('https://example.com/file.pdf')).toBeNull();
		expect(parseArtifactUrn('/Api/core/artifacts/01H/download')).toBeNull();
		expect(parseArtifactUrn(ARTIFACT_URN_PREFIX)).toBeNull();
		expect(parseArtifactUrn('')).toBeNull();
	});

	it('builds the download gateway URL', () => {
		expect(artifactDownloadUrl('01H')).toBe('/Api/core/artifacts/01H/download');
	});

	it('resolves URNs to the gateway URL and passes everything else through', () => {
		expect(resolveArtifactUrl(artifactUrn('01H'))).toBe('/Api/core/artifacts/01H/download');
		expect(resolveArtifactUrl('https://example.com/x.png')).toBe('https://example.com/x.png');
		expect(resolveArtifactUrl('blob:https://app/blobid')).toBe('blob:https://app/blobid');
		expect(resolveArtifactUrl('#anchor')).toBe('#anchor');
	});
});
