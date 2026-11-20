// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { createMockAssistant, MOCK_APP_ID } from '../../src/index.js';

/**
 * Smoke test against the BUILT bundle (`dist/index.js`) — the artifact hosts
 * actually import. Closes the gap between the source-level element tests and
 * the compiled output (compiler output, style injection, element
 * registration). Skipped when `pnpm build` has not run yet.
 */
const distPath = resolve(process.cwd(), 'dist/index.js');
describe.runIf(existsSync(distPath))('dist bundle', () => {
	it('registers the custom elements and mounts the inline panel', async () => {
		const dist = await import(distPath);
		expect(dist.FacetAssistantElement).toBeDefined();
		expect(dist.FacetAssistantWindowElement).toBeDefined();

		const el = document.createElement('facet-assistant') as HTMLElement & {
			appId: string;
			driver: object;
		};
		el.appId = MOCK_APP_ID;
		el.driver = createMockAssistant();
		document.body.appendChild(el);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
		});
		el.remove();
	});
});
