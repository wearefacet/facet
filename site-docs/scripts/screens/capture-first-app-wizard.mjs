// Captured-once recipe — the first-app wizard shots for
// build/first-hour/first-app.md. Hand-run: the flow fills forms the
// standard pipeline cannot drive, and the slug is unique, so a rerun
// needs the previous brw-checkout deleted first (pass its id as argv[2];
// find it with GET /Api/app/App?filters[slug__eq]=brw-checkout).
//
// The run leaves a live brw-checkout app behind — delete it after
// recapturing to free the slug for tutorial readers.
//
//   cd site-docs && NODE_PATH=$(pwd)/../frontend/node_modules \
//     node scripts/screens/capture-first-app-wizard.mjs [appIdToDelete]
//
// Sign-in needs bypassCSP: the dev frontend's SvelteKit start shim
// carries no CSP nonce, so hydration is blocked without it (see
// frontend/src/hooks.server.ts — the nonce stamping covers the theme
// script only). Revisit if the shim gains the nonce.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ASSETS = resolve(SCRIPT_DIR, '..', '..', 'src', 'assets', 'screens');

const base = 'https://facet.localhost:3443';
const HOSTED = 'https://checkout.apps.localhost:3443';
const SLUG = 'brw-checkout';
const deleteId = process.argv[2] ?? '';

const browser = await chromium.launch();
const ctx = await browser.newContext({
  ignoreHTTPSErrors: true,
  bypassCSP: true,
  viewport: { width: 1280, height: 800 },
});
const page = await ctx.newPage();

// ── sign in as ravi ─────────────────────────────────────────────────────
await page.goto(`${base}/Login`, { waitUntil: 'networkidle' });
await page.getByPlaceholder('you@example.com').fill('ravi@brightwater.example');
await page.locator('input[type=password]').fill('brightwater-ravi');
await page.getByRole('button', { name: 'Sign in' }).click();
await page.getByRole('button', { name: 'Skip for now' }).click({ timeout: 4000 }).catch(() => {});
await page.waitForFunction(() => !window.location.pathname.includes('/Login'), null, { timeout: 20000 });

if (deleteId) {
  const status = await page.evaluate(async (id) => {
    const res = await fetch(`/Api/app/App/${id}`, {
      method: 'DELETE',
      headers: { 'X-Requested-With': 'XMLHttpRequest' },
    });
    return res.status;
  }, deleteId);
  console.log(`deleted ${deleteId}: ${status}`);
}

// ── wizard setup ────────────────────────────────────────────────────────
await page.goto(`${base}/Configure/apps/new/setup?preset=external`, { waitUntil: 'networkidle' });
await page.waitForTimeout(1200);
const closeBtn = page.getByRole('button', { name: 'Close' });
if (await closeBtn.isVisible().catch(() => false)) {
  const box = page.locator('input[type=checkbox]').first();
  if (await box.isVisible().catch(() => false)) await box.check();
  await closeBtn.click();
  await page.waitForTimeout(400);
}

await page.fill('#app-name', 'Brightwater Check-out');
await page.getByRole('button', { name: 'Edit' }).click();
await page.fill('#app-slug', SLUG);
await page.waitForTimeout(900); // debounce the uniqueness check

async function addChip(ariaLabel, value) {
  const input = page.getByLabel(ariaLabel, { exact: true });
  await input.fill(value);
  await page.waitForTimeout(150);
  await input.press('Enter');
  await page.waitForTimeout(250);
}
await addChip('Allowed origins', 'http://localhost:5173');
await addChip('Allowed origins', HOSTED);
await addChip('Redirect URIs', 'http://localhost:5173/auth/callback');
await addChip('Redirect URIs', `${HOSTED}/auth/callback`);
await page.waitForTimeout(500);
await page.screenshot({ path: resolve(ASSETS, 'build/first-app-wizard-setup.png'), fullPage: true });
console.log('setup shot saved');

// ── permissions ────────────────────────────────────────────────────────
await page.getByRole('button', { name: 'Continue' }).click();
await page.waitForURL(/permissions/, { timeout: 15000 });
await page.waitForTimeout(1200);

// Set one doctype's level, then flip its required switches and verify.
// A child doctype renders nested inside its parent's card, so scope by
// root row (.grants-required-row) or child row (-compact) accordingly.
async function setGrant(domainRailLabel, cardLabel, level, requiredVerbs, isChild = false) {
  const rail = page.locator('[role=tablist][aria-label="Domains"] button');
  await rail.filter({ hasText: domainRailLabel }).first().click();
  await page.waitForTimeout(400);
  const seg = page.locator(`[aria-label="Access level for ${cardLabel}"]`);
  await seg.locator('button', { hasText: level }).click();
  await page.waitForTimeout(400);
  const row = page
    .locator(isChild ? '.grants-child' : '.grants-card')
    .filter({ has: seg })
    .locator(isChild ? '.grants-required-row-compact' : '.grants-required-row:not(.grants-required-row-compact)');
  for (const verb of requiredVerbs) {
    const sw = row.getByRole('switch', { name: verb, exact: true });
    for (let attempt = 0; attempt < 3; attempt++) {
      if ((await sw.getAttribute('aria-checked')) === 'true') break;
      await sw.click();
      await page.waitForTimeout(300);
    }
    if ((await sw.getAttribute('aria-checked')) !== 'true') {
      throw new Error(`required switch "${verb}" on ${cardLabel} did not turn on`);
    }
  }
}

await setGrant('rentals', 'Booking', 'Read', ['Read']);
await setGrant('rentals', 'BookingLine', 'Read', ['Read'], true);
await setGrant('equipment', 'Item', 'Write', ['Read', 'Create and edit']);
await page.waitForTimeout(500);
await page.screenshot({ path: resolve(ASSETS, 'build/first-app-wizard-permissions.png'), fullPage: true });
console.log('permissions shot saved');

// ── review ─────────────────────────────────────────────────────────────
await page.getByRole('button', { name: 'Continue' }).click();
await page.waitForURL(/review/, { timeout: 15000 });
await page.waitForTimeout(1000);
await page.screenshot({ path: resolve(ASSETS, 'build/first-app-wizard-review.png'), fullPage: true });
console.log('review shot saved');

// ── publish → credentials ──────────────────────────────────────────────
await page.getByRole('button', { name: 'Publish' }).click();
await page.waitForURL(/credentials/, { timeout: 20000 });
await page.waitForTimeout(1500);
await page.screenshot({ path: resolve(ASSETS, 'build/first-app-wizard-credentials.png'), fullPage: true });
const appId = page.url().match(/app=([^&]+)/)?.[1] ?? '';
console.log(`credentials shot saved — APP_ID=${appId}`);

// ── serving host on the Settings tab ───────────────────────────────────
await page.goto(`${base}/Configure/apps/${SLUG}/settings`, { waitUntil: 'networkidle' });
await page.waitForTimeout(1200);
const hostInput = page.getByLabel('Host', { exact: true });
await hostInput.fill('checkout.apps.localhost');
const serving = hostInput.locator('xpath=ancestor::section[1]');
await serving.getByRole('button', { name: 'Save' }).click();
await page.waitForTimeout(900);
await page.screenshot({ path: resolve(ASSETS, 'build/first-app-wizard-host.png'), fullPage: true });
console.log('host shot saved');

console.log(`done — delete app ${appId} to free the slug`);
await browser.close();
