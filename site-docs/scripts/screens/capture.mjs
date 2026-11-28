// Docs screenshot capture — Playwright pipeline for the Facet documentation.
//
// Reads the shot declarations from shots.yml, signs in as each shot's
// persona through the real sign-in form, visits the URL, and saves PNGs to
// site-docs/src/assets/screens/.
//
// Run command (from site-docs/ — Playwright lives in frontend/node_modules,
// the site-docs package does not depend on it, so point NODE_PATH there):
//
//   cd site-docs
//   NODE_PATH=$(pwd)/../frontend/node_modules node scripts/screens/capture.mjs
//
// Options:
//   --shots <path>   shot file to run (default scripts/screens/shots.yml)
//   --base <url>     override the base URL from the shot file
//   --only <id,...>  run a subset of shots
//
// Browsers: Playwright uses the shared cache under ~/.cache/ms-playwright.
// If chromium is missing, install it once without root:
//   cd frontend && npx playwright install chromium
//
// Shots are committed assets: nothing here is gitignored. The example data
// is deterministic (anchor date 2026-12-07), but any "today"-relative UI
// (dashboard panels, relative timestamps, notification counts) moves with
// the wall clock — reruns differ in those pixels only.
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SITE_DOCS = resolve(SCRIPT_DIR, '..', '..');
const ASSETS = resolve(SITE_DOCS, 'src', 'assets', 'screens');

function parseArgs(argv) {
  const args = { shots: resolve(SCRIPT_DIR, 'shots.yml') };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--shots') args.shots = resolve(argv[++i]);
    else if (argv[i] === '--base') args.base = argv[++i];
    else if (argv[i] === '--only') args.only = argv[++i].split(',').map((s) => s.trim());
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const spec = parse(await readFile(args.shots, 'utf8'));
const defaults = { settle: 800, ...spec.defaults };
if (args.base) defaults.base = args.base;
const only = args.only ? new Set(args.only) : null;
const shots = spec.shots.filter((s) => !only || only.has(s.id));
if (shots.length === 0) throw new Error('no shots selected');

const browser = await chromium.launch();

// One context per persona: sign in once through the real form, reuse the
// session for every shot of that persona.
const contexts = new Map();
async function contextFor(personaKey) {
  if (contexts.has(personaKey)) return contexts.get(personaKey);
  const persona = spec.personas?.[personaKey];
  if (!persona) throw new Error(`unknown persona: ${personaKey}`);
  const ctx = await browser.newContext({
    viewport: defaults.viewport,
    colorScheme: defaults.theme,
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  await page.goto(`${defaults.base}/Login`, { waitUntil: 'networkidle' });
  await page.getByPlaceholder('you@example.com').fill(persona.email);
  await page.locator('input[type=password]').fill(persona.password);
  await page.getByRole('button', { name: 'Sign in' }).click();

  await page
    .getByRole('button', { name: 'Skip for now' })
    .click({ timeout: 4000 })
    .catch(() => {
      /* no MFA enrollment prompt — plain login */
    });
  await page.waitForFunction(() => !window.location.pathname.includes('/Login'), null, {

    timeout: 20000,

  });
  await page.waitForLoadState('networkidle');
  contexts.set(personaKey, ctx);
  console.log(`signed in as ${persona.email}`);
  return ctx;
}

for (const shot of shots) {
  const ctx = shot.login ? await browser.newContext({
    viewport: shot.viewport ?? defaults.viewport,
    colorScheme: shot.theme ?? defaults.theme,
    ignoreHTTPSErrors: true,
  }) : await contextFor(shot.persona);
  const page = await ctx.newPage();
  try {
    const url = shot.url.startsWith('http') ? shot.url : `${defaults.base}${shot.url}`;
    await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
    if (shot.wait) await page.waitForSelector(shot.wait, { timeout: 15000 });
    await page.waitForTimeout(shot.settle ?? defaults.settle);
    if (shot.highlight) {
      await page.locator(shot.highlight).first().evaluate((el) => {
        el.style.outline = '2px solid #2563eb';
        el.style.outlineOffset = '2px';
      });
      await page.waitForTimeout(200);
    }
    const out = resolve(ASSETS, shot.out);
    mkdirSync(dirname(out), { recursive: true });
    const target = shot.crop ? page.locator(shot.crop).first() : page;
    await target.screenshot({ path: out, animations: 'disabled', caret: 'hide' });
    console.log(`saved ${shot.out} (${shot.id})`);
  } finally {
    if (shot.login) await ctx.close();
    else await page.close();
  }
}

await browser.close();
console.log('done');
