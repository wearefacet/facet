// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { test as setup, expect } from '@playwright/test';

/**
 * Setup project: logs in through the real login screen once
 * per stack and saves the admin `storageState` for the scenario projects.
 * The login screen is itself a gate surface — this is the only step that
 * exercises it, and every scenario reuses its cookie jar.
 *
 * Credentials come from the stack baseline `facet db_reset seed:dev`
 * (`admin@example.tld` / `admin`, no MFA — `config.e2e.yml` disables the
 * TOTP gates).
 */
const authDir = path.join(process.cwd(), '.auth');
const authFile = path.join(authDir, 'admin.json');

setup('authenticate as the seeded admin', async ({ page }) => {
	mkdirSync(authDir, { recursive: true });

	await page.goto('/Login');

	// The login form hydrates after SSR. A click that lands before hydration
	// submits the form natively, with the credentials in the URL. Wait for
	// the bundle to settle before the form is touched.
	await page.waitForLoadState('networkidle', { timeout: 15_000 });
	await page.getByLabel('Email').fill('admin@example.tld');
	await page.getByLabel('Password').fill('admin');
	await page.getByRole('button', { name: 'Sign in' }).click();

	// Success is the dashboard landing: the auth hook accepted the session
	// and the app shell hydrated.
	await expect(page).toHaveURL(/\/(\?.*)?$/);
	await expect(page.getByRole('heading', { name: /Hello Administrator/ })).toBeVisible();

	// The first-run welcome tour opens for the seeded admin on every fresh
	// stack (`core.show_welcome` defaults to true) and its overlay blocks
	// every pointer action behind it. Dismiss it through the real checkbox —
	// the write persists server-side, so no scenario page re-opens the tour —
	// then prove the persistence with one reload. This step doubles as the
	// only coverage the tour's dismissal contract needs here: opens for the
	// admin, the checkbox write lands, the reload stays quiet.
	const dontShow = page.getByRole('checkbox', { name: "Don't show again" });
	await expect(dontShow).toBeVisible();
	await dontShow.check();
	await expect(dontShow).toBeHidden();
	await page.reload();
	await expect(page.getByRole('heading', { name: /Hello Administrator/ })).toBeVisible();
	await expect(dontShow).toBeHidden();

	await page.context().storageState({ path: authFile });
});
