#!/usr/bin/env node
// R3 reachability check for the documentation site (WP 20).
//
// Every user-facing feature ID must be findable from its tab index within
// two clicks: the tab index itself links the page that documents it, or
// links a group index that does. "Documents it" = the page cites the ID in
// its `features` front-matter. "User-facing" = not reference-only, not
// removed, not in coverage-exclude.yml.
//
// Reads the same inputs as check-coverage.mjs (inventory.yml,
// coverage-exclude.yml, English page front-matter) and walks the internal
// content-link graph of the English tree. Prints a per-tab table and exits
// non-zero when an ID has no reachable documenting page.

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const INVENTORY_PATH = join(SITE_ROOT, 'inventory.yml');
const EXCLUDE_PATH = join(SITE_ROOT, 'coverage-exclude.yml');
const TABS = ['discover', 'use', 'build', 'admin', 'reference'];
const MAX_CLICKS = 2;

// --- small YAML parsers (same shape as check-coverage.mjs) -------------------

function parseInventory(text) {
  const features = [];
  let current = null;
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const idMatch = line.match(/^- id:\s*(\S+)\s*$/);
    if (idMatch) {
      if (current) features.push(current);
      current = { id: idMatch[1], name: '', area: '', referenceOnly: false, removed: null };
      continue;
    }
    if (!current) continue;
    const nameMatch = line.match(/^name:\s*(.+)$/);
    if (nameMatch) current.name = nameMatch[1].trim();
    const areaMatch = line.match(/^area:\s*(\S+)\s*$/);
    if (areaMatch) current.area = areaMatch[1];
    if (/^reference-only:\s*true\s*$/.test(line)) current.referenceOnly = true;
    const removedMatch = line.match(/^removed:\s*(.+)$/);
    if (removedMatch) current.removed = removedMatch[1].trim();
  }
  if (current) features.push(current);
  return features;
}

function parseExclusions(text) {
  const exclusions = [];
  let current = null;
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const idMatch = line.match(/^- id:\s*(\S+)\s*$/);
    if (idMatch) {
      if (current) exclusions.push(current);
      current = { id: idMatch[1] };
      continue;
    }
  }
  if (current) exclusions.push(current);
  return exclusions;
}

function parseFrontMatter(text) {
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return match ? match[1] : null;
}

function parseFeatures(frontMatter) {
  const line = frontMatter.split('\n').find((l) => /^features:/.test(l));
  if (!line) return [];
  const value = line.slice('features:'.length).trim();
  if (!value.startsWith('[') || !value.endsWith(']')) return [];
  const inner = value.slice(1, -1).trim();
  if (!inner) return [];
  return inner
    .split(',')
    .map((item) => item.trim().replace(/^['"]|['"]$/g, ''))
    .filter(Boolean);
}

// --- page scan ---------------------------------------------------------------

function collectPages(dir, base = dir) {
  const pages = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'fr') continue; // English tree only
      pages.push(...collectPages(full, base));
    } else if (entry.name.endsWith('.md') || entry.name.endsWith('.mdx')) {
      pages.push(relative(base, full).split(sep).join('/'));
    }
  }
  return pages;
}

// Internal content links: markdown [..](/path) and HTML href="/path".
// Skips anchors, assets and fragments; returns URL paths without a trailing
// slash, query or hash.
function extractLinks(body) {
  const urls = new Set();
  const patterns = [/\]\((\/[^)\s]*)(?:\s+"[^"]*")?\)/g, /href="(\/[^"]*)"/g, /href='(\/[^']*)'/g];
  for (const re of patterns) {
    for (const match of body.matchAll(re)) {
      let url = match[1];
      if (url.startsWith('//')) continue;
      url = url.split('#')[0].split('?')[0];
      if (url.length === 0 || url === '/') continue;
      if (/\.(png|svg|jpg|webp|ico|txt|xml|json|yml|yaml)$/i.test(url)) continue;
      urls.add(url.replace(/\/+$/, ''));
    }
  }
  return [...urls];
}

// URL path (no leading slash) -> page key, for every English content page.
function buildUrlIndex(pages) {
  const index = new Map();
  for (const page of pages) {
    const noExt = page.replace(/\.(md|mdx)$/, '');
    const url = noExt.endsWith('/index') ? noExt.slice(0, -'/index'.length) : noExt;
    index.set(url, page);
  }
  return index;
}

// --- main --------------------------------------------------------------------

console.log(`R3 reachability check — every user-facing feature ID must be reachable from its tab index within ${MAX_CLICKS} clicks`);
console.log('');

if (!existsSync(INVENTORY_PATH)) {
  console.error(`Inventory not found: ${INVENTORY_PATH}`);
  process.exit(2);
}

const inventory = parseInventory(readFileSync(INVENTORY_PATH, 'utf8'));
const excludedIds = existsSync(EXCLUDE_PATH)
  ? new Set(parseExclusions(readFileSync(EXCLUDE_PATH, 'utf8')).map((e) => e.id))
  : new Set();

// Wildcards expand like the coverage check: 'X-*' covers every 'X-' ID.
const areaIds = new Map();
for (const feature of inventory) {
  if (!areaIds.has(feature.area)) areaIds.set(feature.area, []);
  areaIds.get(feature.area).push(feature.id);
}
function expand(features) {
  const out = new Set();
  for (const id of features) {
    if (id.endsWith('-*')) {
      for (const expanded of areaIds.get(id.slice(0, -2)) ?? []) out.add(expanded);
    } else {
      out.add(id);
    }
  }
  return out;
}

const userFacing = new Set(
  inventory
    .filter((f) => !f.referenceOnly && !f.removed && !excludedIds.has(f.id))
    .map((f) => f.id),
);

const pages = collectPages(DOCS_DIR);
const urlIndex = buildUrlIndex(pages);
const featuresByPage = new Map();
const linksByPage = new Map();

for (const page of pages) {
  const text = readFileSync(join(DOCS_DIR, page), 'utf8');
  const frontMatter = parseFrontMatter(text);
  const body = frontMatter ? text.slice(text.indexOf('\n---', 4) + 4) : text;
  featuresByPage.set(page, frontMatter ? expand(parseFeatures(frontMatter)) : new Set());
  const targets = new Set();
  for (const url of extractLinks(body)) {
    const target = urlIndex.get(url.replace(/^\//, ''));
    if (target && target !== page) targets.add(target);
  }
  linksByPage.set(page, targets);
}

// Pages within MAX_CLICKS of each tab index (BFS over content links).
const reachableFromTab = new Map();
for (const tab of TABS) {
  const tabIndex = urlIndex.get(tab);
  const reachable = new Set();
  if (tabIndex) {
    let frontier = [tabIndex];
    reachable.add(tabIndex);
    for (let click = 1; click <= MAX_CLICKS; click++) {
      const next = [];
      for (const page of frontier) {
        for (const target of linksByPage.get(page) ?? []) {
          if (!reachable.has(target)) {
            reachable.add(target);
            next.push(target);
          }
        }
      }
      frontier = next;
    }
  }
  reachableFromTab.set(tab, reachable);
}

// ID -> pages that document it (cite it in features).
const documentedBy = new Map();
for (const [page, features] of featuresByPage) {
  for (const id of features) {
    if (!userFacing.has(id)) continue;
    if (!documentedBy.has(id)) documentedBy.set(id, new Set());
    documentedBy.get(id).add(page);
  }
}

// --- report ------------------------------------------------------------------

const perTab = new Map(TABS.map((t) => [t, { ids: 0, reachable: 0 }]));
const gaps = [];
const coveredPages = new Set();

for (const id of [...documentedBy.keys()].sort()) {
  const documenting = [...documentedBy.get(id)];
  const tab = documenting[0].split('/')[0];
  const reachable = documenting.filter((p) => reachableFromTab.get(tab).has(p));
  const stats = perTab.get(tab) ?? perTab.get('reference');
  if (reachable.length > 0) {
    stats.ids += 1;
    stats.reachable += 1;
    for (const p of reachable) coveredPages.add(p);
  } else {
    gaps.push({ id, tab, documenting });
  }
}

const header = 'Tab'.padEnd(12) + 'IDs cited'.padStart(10) + 'Reachable'.padStart(10) + 'Unreachable'.padStart(12);
console.log(header);
console.log('-'.repeat(header.length));
let total = 0;
let reachableTotal = 0;
for (const tab of TABS) {
  const s = perTab.get(tab);
  total += s.ids;
  reachableTotal += s.reachable;
  console.log(
    tab.padEnd(12) + String(s.ids).padStart(10) + String(s.reachable).padStart(10) + String(s.ids - s.reachable).padStart(12),
  );
}
console.log('All'.padEnd(12) + String(total).padStart(10) + String(reachableTotal).padStart(10) + String(total - reachableTotal).padStart(12));
console.log('');

if (gaps.length === 0) {
  console.log('All user-facing feature IDs are reachable from their tab index. ✓');
  process.exit(0);
}

console.log(`Unreachable IDs (${gaps.length}) — no page documenting the ID is within ${MAX_CLICKS} clicks of its tab index:`);
for (const gap of gaps) {
  console.log(`  ${gap.id} (${gap.tab}) — documented by: ${gap.documenting.join(', ')}`);
}
console.log('');
console.log('Fix: link the documenting page (or a group index that links it) from the tab index, or from a page the tab index already reaches.');
process.exit(1);
