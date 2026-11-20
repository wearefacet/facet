// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

/**
 * The login smoke passes inside the runner
 * container. It proves the whole product path on the real stack — browser
 * → Caddy (TLS) → SvelteKit serve → auth-hook SSR fetch through Caddy →
 * Kemal — with the storageState from the setup project. Nothing here may
 * talk to `127.0.0.1:3000` or `:4173` directly — the stack's Caddy is the
 * only entry point.
 *
	 * The scenario also carries the a11y smoke gate (audit 22): an axe scan of
	 * the signed-in dashboard that fails on `critical` violations. The known
	 * backlog lives in the Storybook a11y overrides (grep `test: 'todo'` in
	 * the frontend stories); this gate catches egregious regressions (unnamed
	 * buttons, broken ARIA trees) on a real page.
 */
test('login smoke: the dashboard renders for the seeded admin', async ({ page }) => {
	await test.step('open the app root with the setup storageState', async () => {
		await page.goto('/');
	});

	await test.step('the dashboard greets the signed-in admin through Caddy', async () => {
		// The greeting renders from the `/Api/iam/me` payload resolved during
		// SSR — a successful round trip through Caddy, the auth hook and the
		// backend with the session cookie.
		await expect(page.getByRole('heading', { name: /Hello Administrator/ })).toBeVisible();
		await expect(page.getByText(/connected as/)).toBeVisible();
	});

	await test.step('axe: no critical a11y violations on the dashboard', async () => {
		const results = await new AxeBuilder({ page })
			.withTags(['wcag2a', 'wcag21a', 'best-practice'])
			.analyze();
		const critical = results.violations.filter((v) => v.impact === 'critical');
		if (critical.length > 0) {
			console.error(
				'[a11y smoke] critical violations:',
				JSON.stringify(
					critical.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length })),
					null,
					2
				)
			);
		}
		expect(critical, 'critical a11y violations on the dashboard').toHaveLength(0);
	});
});
