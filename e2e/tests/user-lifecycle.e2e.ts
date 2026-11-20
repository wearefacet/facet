// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { test, expect, type Browser, type BrowserContext, type Locator, type Page } from '@playwright/test';

/**
 * User lifecycle: the account journey end
 * to end — an admin creates an account and assigns a role; the account
 * logs in with a temporary password, is forced to change it, loses access
 * when disabled, and recovers when re-enabled.
 *
 * UI paths this file pins (drive what the app actually has):
 * - `/Configure/access` redirects to the roles list; the accounts admin is
 *   `/Configure/access/accounts` (the Configure sidebar's Accounts link).
 * - Creating an account is the standard document form at
 *   `/iam/Account/new`; the seeded create hook starts every human account
 *   `pending` regardless of the submitted status.
 * - Role assignment is its own surface: `/Configure/access/assignments` in
 *   "By account" mode. The temporary password lives with the other
 *   credential actions on the account show page (the
 *   `AccountCredentialActions` panel).
 * - Disabling/re-enabling rides the account edit form's `status` enum
 *   (`/iam/Account/{id}/edit` → Disabled/Active). The credential panel has
 *   no status action.
 *
 * Session policy: the admin keeps the setup project's
 * `storageState` context. The account under test gets a fresh context per
 * login phase — its sessions are never persisted, so each login proves the
 * full credential path against the server.
 *
 * The temp password displays exactly once (reveal-once dialog) and is read
 * in the same step that generated it; no fixture stores it.
 */

const ACCOUNT_EMAIL = 'nia@example.tld';
const ACCOUNT_NAME = 'Nia Okafor';
const PERMANENT_PASSWORD = 'Orchid-Lantern-Vault-42';

/** The accounts table's `search` box (FilterBar). */
const SEARCH = { placeholder: 'Search…' } as const;

type JarCookie = Awaited<ReturnType<BrowserContext['cookies']>>[number];

function escapeRegExp(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** The dashboard URL — the bare root of the app. */
const DASHBOARD_URL = /\/(\?|$)/;

/**
 * Opens the login page ready for interaction. The form hydrates after SSR,
 * and a click that lands before hydration submits the form natively, with
 * the credentials in the URL. Waiting for the network to settle costs under
 * a second and makes every login below hydration-safe.
 */
async function openLoginPage(page: Page): Promise<void> {
	await page.goto('/Login');
	await page.waitForLoadState('networkidle', { timeout: 15_000 });
}

/**
 * Reads the status cell of the account row in the accounts table. The
 * fallback columns render enum fields as `span.cell-enum` with the
 * humanized value, and `status` is the table's only enum column.
 */
async function accountStatusCell(page: Page): Promise<string> {
	const row = page.getByRole('row', { name: new RegExp(escapeRegExp(ACCOUNT_EMAIL)) });
	const status = row.locator('span.cell-enum');
	await expect(status).toHaveCount(1);
	return (await status.innerText()).trim();
}

/** Narrows the accounts table to the account under test. */
async function searchAccountRow(page: Page): Promise<Locator> {
	await page.getByPlaceholder(SEARCH.placeholder).fill(ACCOUNT_EMAIL);
	const row = page.getByRole('row', { name: new RegExp(escapeRegExp(ACCOUNT_EMAIL)) });
	await expect(row).toBeVisible();
	return row;
}

/**
 * A truly anonymous context. `browser.newContext()` inside a test inherits
 * the project `use` context options — including the admin `storageState` —
 * so every manual context must override it with an empty jar, or `/Login`
 * bounces straight back to the dashboard (the auth hook's login-route
 * redirect) and the account-under-test never sees the login form.
 */
function anonymousContext(browser: Browser): Promise<BrowserContext> {
	return browser.newContext({ storageState: { cookies: [], origins: [] } });
}

/**
 * Opens an account's full show page from the accounts table: search to
 * narrow, click the row to open the QuickView peek (the email cell — the
 * first column is a reference capsule whose click would open the role
 * document instead), then follow the peek header's "Open full page" link.
 * Returns the account's document id (the last URL segment).
 */
async function openAccountShowPage(page: Page): Promise<string> {
	await page.goto('/Configure/access/accounts');
	const row = await searchAccountRow(page);
	await row.getByRole('cell', { name: ACCOUNT_EMAIL }).click();
	await page.getByRole('link', { name: 'Open full page' }).click();
	await expect(page).toHaveURL(/\/iam\/Account\/[^/]+$/);
	// The show page carries the account name twice — the DoctypeHeader (h1)
	// and the DocumentViewTemplate's own header (h2).
	await expect(page.getByRole('heading', { name: ACCOUNT_NAME }).first()).toBeVisible();
	return page.url().split('/').filter(Boolean).pop() as string;
}

/**
 * Sets the account's `status` enum through the edit form — the disable and
 * re-enable path (the credential panel carries no status action). The
 * fallback enum select is searchable but not type-to-search: on focus it
 * lists all values while the input holds the current selection's label.
 */
async function setAccountStatus(page: Page, statusLabel: 'Disabled' | 'Active'): Promise<void> {
	await openAccountShowPage(page);
	// `Button href` renders an `a[role=button]`, so the Edit affordance is
	// a button role, not a link.
	await page.getByRole('button', { name: 'Edit', exact: true }).click();
	await expect(page).toHaveURL(/\/edit$/);

	const statusInput = page.getByLabel('Status');
	await statusInput.click();
	const option = page.getByRole('option', { name: statusLabel });
	await expect(option).toBeVisible();
	await option.click();
	await page.getByRole('button', { name: 'Save' }).click();

	// Saving returns to the show page; the flip itself is only proven
	// through the accounts table (see the calling steps).
	await expect(page).toHaveURL(/\/iam\/Account\/[^/]+$/);
}

test('user lifecycle: create, bootstrap, disable, recover', async ({ page, browser }) => {
	// ── 1. The admin creates the account ────────────────────────────────
	await test.step('admin creates the account with the accounts form', async () => {
		await page.goto('/Configure/access/accounts');
		await expect(page.getByRole('heading', { name: 'Accounts' })).toBeVisible();

		// `Button href` renders `a[role=button]` — the affordance is a
		// button role even though it navigates.
		await page.getByRole('button', { name: 'New account' }).click();
		// The create link carries a `from` return param — the form sends the
		// admin back to the accounts list after saving.
		await expect(page).toHaveURL(/\/iam\/Account\/new(\?.*)?$/);

		await page.getByLabel('Email').fill(ACCOUNT_EMAIL);
		await page.getByLabel('Display Name').fill(ACCOUNT_NAME);
		// The submitted status (active by default) is irrelevant — the
		// create hook starts every human account `pending`.
		await page.getByRole('button', { name: 'Create' }).click();

		// The form honours the `from` return param — saving sends the admin
		// back to the accounts list, where the new row renders `pending`.
		await expect(page).toHaveURL(/\/Configure\/access\/accounts$/);
		await expect(
			page.getByRole('row', { name: new RegExp(escapeRegExp(ACCOUNT_NAME)) })
		).toBeVisible();
	});

	// ── 2. Admin assigns the editor role ────────────────────────────────
	await test.step('admin assigns the editor role on /Configure/access/assignments', async () => {
		// The assignments page deep-links on `?mode=account&account=…`, and
		// the deep link reaches it as render-time URL state — this test does
		// not lean on the picker's own commit path (its `onValueChange`
		// URL write does not re-derive this build's `page.url` readers).
		const accountId = await openAccountShowPage(page);
		await page.goto(`/Configure/access/assignments?mode=account&account=${accountId}`);
		await expect(page.getByRole('heading', { name: 'Roles assigned to account' })).toBeVisible();

		// The role picker searches on role name (`name__match`); the
		// option label is the humanized name.
		const roleSelect = page.getByPlaceholder('Add a role to this account…');
		await expect(roleSelect).toBeVisible();
		await roleSelect.click();
		await roleSelect.fill('editor');
		const roleOption = page.getByRole('option', { name: 'Editor' });
		await expect(roleOption).toBeVisible();
		await roleOption.click();
		await page.getByRole('button', { name: 'Assign role' }).click();

		// The role lands on the membership list (single row: title, the
		// role description, the `default` tag — first assignment becomes
		// `default_role` per roleMembership.ts, which is what login resolves).
		await expect(page.getByRole('listitem').filter({ hasText: 'Editor' })).toHaveCount(1);
	});

	// The temporary password displays exactly once: read it from the
	// reveal-once dialog in the same step that generated it and carry it
	// in this scope — no fixture stores it.
	let tempPassword: string;
	await test.step('admin generates the temporary password (reveal once)', async () => {
		await openAccountShowPage(page);

		await page.getByRole('button', { name: 'Generate password' }).click();

		const dialog = page.getByRole('dialog');
		await expect(dialog).toContainText('Temporary password generated');
		await expect(dialog).toContainText('cannot be retrieved again');
		tempPassword = (await dialog.locator('code.pw-value').innerText()).trim();
		expect(tempPassword.length).toBeGreaterThan(8);

		// Closing burns the only chance to read the value.
		await dialog.getByRole('button', { name: 'Done' }).click();
		await expect(dialog).not.toBeVisible();
	});

	// ── 4. Temp-password login holds at the forced change ───────────────
	await test.step('temp-password login holds at the forced change screen', async () => {
		const boot = await anonymousContext(browser);
		const bootPage = await boot.newPage();
		await openLoginPage(bootPage);
		await bootPage.getByLabel('Email').fill(ACCOUNT_EMAIL);
		await bootPage.getByLabel('Password').fill(tempPassword);
		await bootPage.getByRole('button', { name: 'Sign in' }).click();

		// Held: the `must_change_password` branch (PasswordChangeRequired
		// in the login pipeline) renders ForcedChangeScreen — not the app.
		await expect(bootPage).toHaveURL(/\/Login/);
		await expect(
			bootPage.getByRole('heading', { name: 'Set a new password' })
		).toBeVisible();

		// Never persist this phase's state: the temp password must not
		// become a usable session for later steps.
		await boot.close();
	});

	// ── 5. Set the permanent password ───────────────────────────────────
	await test.step('new password lands the account on the dashboard', async () => {
		const activate = await anonymousContext(browser);
		const activatePage = await activate.newPage();

		await openLoginPage(activatePage);
		await activatePage.getByLabel('Email').fill(ACCOUNT_EMAIL);
		await activatePage.getByLabel('Password').fill(tempPassword);
		await activatePage.getByRole('button', { name: 'Sign in' }).click();
		await expect(
			activatePage.getByRole('heading', { name: 'Set a new password' })
		).toBeVisible();

		await activatePage.getByLabel('Current password').fill(tempPassword);
		// Exact matching on this label resolves to nothing: the Field renders
		// the required marker "*" inside the same label element ("New
		// password*"), and "New password" alone also substring-matches the
		// confirm field. Target the label-wired id instead.
		await activatePage.locator('input[id="input-New password"]').fill(PERMANENT_PASSWORD);
		await activatePage.getByLabel('Confirm new password').fill(PERMANENT_PASSWORD);
		await activatePage.getByRole('button', { name: 'Save password and continue' }).click();

		// Dashboard: identity + session. The greeting renders the first
		// name token (`Hello {firstName},`) and the active role label from
		// the hydrated session — roles and permissions resolved for editor.
		await expect(activatePage).toHaveURL(DASHBOARD_URL);
		await expect(activatePage.getByRole('heading', { name: `Hello Nia,` })).toBeVisible();
		await expect(activatePage.getByText('connected as Editor')).toBeVisible();

		await activate.close();
	});

	// ── 6. The account went active after the first full login ───────────
	await test.step('accounts list shows the account active', async () => {
		await page.goto('/Configure/access/accounts');
		await searchAccountRow(page);
		// The list is a full-load read — but give the projection a tick.
		await expect
			.poll(() => accountStatusCell(page), { message: 'status should settle to Active' })
			.toBe('Active');
	});

	// ── 7. Admin disables the account ───────────────────────────────────
	await test.step('admin disables the account', async () => {
		await setAccountStatus(page, 'Disabled');
		await page.goto('/Configure/access/accounts');
		await searchAccountRow(page);
		await expect
			.poll(() => accountStatusCell(page), { message: 'status should settle to Disabled' })
			.toBe('Disabled');
	});

	// ── 8. Disabled login: 403, no session ──────────────────────────────
	await test.step('disabled account login is rejected (no session lands)', async () => {
		const disabled = await anonymousContext(browser);
		const disabledPage = await disabled.newPage();

		await openLoginPage(disabledPage);
		await disabledPage.getByLabel('Email').fill(ACCOUNT_EMAIL);
		await disabledPage.getByLabel('Password').fill(PERMANENT_PASSWORD);
		await disabledPage.getByRole('button', { name: 'Sign in' }).click();

		// `Login.pre_auth_checks` 403 path — the backend message reaches
		// the login form's alert, and no session cookies land (the locale
		// cookie the app may drop is not a credential).
		await expect(disabledPage).toHaveURL(/\/Login/);
		await expect(disabledPage.getByRole('alert')).toContainText('Account is disabled');
		const landed = await disabled.cookies();
		expect(landed.filter((c) => c.name === 'auth_token' || c.name === 'refresh_token')).toHaveLength(0);

		await disabled.close();
	});

	// ── 9. Admin re-enables the account ─────────────────────────────────
	await test.step('admin re-enables the account', async () => {
		await setAccountStatus(page, 'Active');
		await page.goto('/Configure/access/accounts');
		await searchAccountRow(page);
		await expect
			.poll(() => accountStatusCell(page), { message: 'status should settle to Active again' })
			.toBe('Active');
	});

	// ── 10. Recovery login + session behaviour ──────────────────────────
	await test.step('recovery login keeps the session across reload and a stale access token', async () => {
		const recovery = await anonymousContext(browser);
		const recoveryPage = await recovery.newPage();

		// Recovery uses the credential set in the forced change — the
		// disabled period must not have wiped the changed password
		// (steps 7–9 pin this).
		await openLoginPage(recoveryPage);
		await recoveryPage.getByLabel('Email').fill(ACCOUNT_EMAIL);
		await recoveryPage.getByLabel('Password').fill(PERMANENT_PASSWORD);
		await recoveryPage.getByRole('button', { name: 'Sign in' }).click();
		await expect(recoveryPage).toHaveURL(DASHBOARD_URL);
		await expect(recoveryPage.getByRole('heading', { name: `Hello Nia,` })).toBeVisible();

		// Reload keeps the session: the cookie pair survives and the
		// auth-hook server round trip re-resolves it.
		await recoveryPage.reload();
		await expect(
			recoveryPage.getByRole('heading', { name: `Hello Nia,` })
		).toBeVisible();

		// A stale access token refreshes: replace only `auth_token` with
		// an invalid value, keep `refresh_token`, and prove the SSR
		// refresh pipeline (`handleAuth` → `/Api/iam/refresh` rotation)
		// re-establishes the session on the next full load.
		const jar: JarCookie[] = await recovery.cookies();
		const names = new Set(jar.map((c) => c.name));
		expect(names).toContain('refresh_token');
		expect(names).toContain('auth_token');

		const stale: JarCookie[] = jar.map((c) =>
			c.name === 'auth_token' ? { ...c, value: 'stale-access-token-forced-refresh' } : c
		);
		await recovery.clearCookies();
		await recovery.addCookies(stale);

		await recoveryPage.goto('/');
		await expect(
			recoveryPage.getByRole('heading', { name: `Hello Nia,` })
		).toBeVisible();

		await recovery.close();
	});
});
