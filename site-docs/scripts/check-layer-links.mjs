#!/usr/bin/env node
// Layer-link and dead-end check for the documentation site (WP 20).
//
// Layer model (01-voice-and-vibe.md §3): L1 orientation, L2 task, L3 depth.
// Every page links one layer up and one layer down in `## Related` (a link
// anywhere in the page body counts) when pages at that layer share a feature
// ID. Feature sets come from the `features` front-matter, expanded like the
// coverage check.
//
// Layer assignment:
//   overview                    -> L1
//   tutorial, how-to            -> L2
//   reference                   -> L3
//   explanation                 -> L3 under build/deeper/ or
//                                  admin/under-the-hood/, else L1
//
// Dead ends: no content page may lack an outgoing internal content link.
// The landing page (`index.mdx`) is exempt — it is the site entry.
//
// Prints both reports and exits non-zero on any gap.

import { readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const INVENTORY_PATH = join(SITE_ROOT, 'inventory.yml');
const LANDING = 'index.mdx';

// --- feature IDs (inventory only, for wildcard expansion) --------------------

function parseInventory(text) {
  const features = [];
  let current = null;
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const idMatch = line.match(/^- id:\s*(\S+)\s*$/);
    if (idMatch) {
      if (current) features.push(current);
      current = { id: idMatch[1], area: '' };
      continue;
    }
    if (!current) continue;
    const areaMatch = line.match(/^area:\s*(\S+)\s*$/);
    if (areaMatch) current.area = areaMatch[1];
  }
  if (current) features.push(current);
  return features;
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

function parseFrontMatter(text) {
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return match ? match[1] : null;
}

function frontMatterValue(frontMatter, key) {
  const line = frontMatter.split('\n').find((l) => new RegExp(`^${key}:`).test(l));
  if (!line) return null;
  return line.slice(key.length + 1).trim().replace(/^['"]|['"]$/g, '');
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

const PAGE_TYPES = ['overview', 'tutorial', 'how-to', 'explanation', 'reference'];

function layerOf(page, type) {
  if (type === 'overview') return 'L1';
  if (type === 'tutorial' || type === 'how-to') return 'L2';
  if (type === 'reference') return 'L3';
  if (type === 'explanation') {
    return page.startsWith('build/deeper/') || page.startsWith('admin/under-the-hood/') ? 'L3' : 'L1';
  }
  return null;
}

// Internal content links: markdown [..](/path) and HTML href="/path".
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

const inventory = parseInventory(readFileSync(INVENTORY_PATH, 'utf8'));
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

const pages = collectPages(DOCS_DIR);
const urlIndex = buildUrlIndex(pages);
const layerByPage = new Map();
const featuresByPage = new Map();
const linksByPage = new Map();
const noType = [];

for (const page of pages) {
  const text = readFileSync(join(DOCS_DIR, page), 'utf8');
  const frontMatter = parseFrontMatter(text);
  const body = frontMatter ? text.slice(text.indexOf('\n---', 4) + 4) : text;
  if (frontMatter) {
    const type = frontMatterValue(frontMatter, 'type');
    const layer = type && PAGE_TYPES.includes(type) ? layerOf(page, type) : null;
    if (layer) layerByPage.set(page, layer);
    else if (page !== LANDING) noType.push(page);
    featuresByPage.set(page, expand(parseFeatures(frontMatter)));
  } else {
    featuresByPage.set(page, new Set());
  }
  const targets = new Set();
  for (const url of extractLinks(body)) {
    const target = urlIndex.get(url.replace(/^\//, ''));
    if (target && target !== page) targets.add(target);
  }
  linksByPage.set(page, targets);
}

// Pages sharing at least one feature ID, per page, split by layer.
const matchesUp = new Map();
const matchesDown = new Map();
for (const [page, layer] of layerByPage) {
  const mine = featuresByPage.get(page);
  if (mine.size === 0) continue;
  const up = layer === 'L3' ? 'L2' : layer === 'L2' ? 'L1' : null;
  const down = layer === 'L1' ? 'L2' : layer === 'L2' ? 'L3' : null;
  const upPages = new Set();
  const downPages = new Set();
  for (const [other, otherLayer] of layerByPage) {
    if (other === page) continue;
    const shared = [...featuresByPage.get(other)].some((id) => mine.has(id));
    if (!shared) continue;
    if (up && otherLayer === up) upPages.add(other);
    if (down && otherLayer === down) downPages.add(other);
  }
  matchesUp.set(page, upPages);
  matchesDown.set(page, downPages);
}

const layerGaps = [];
const pagesWithFeatures = [...layerByPage.keys()].filter((p) => featuresByPage.get(p).size > 0);
for (const page of pagesWithFeatures) {
  const up = matchesUp.get(page);
  const down = matchesDown.get(page);
  const links = linksByPage.get(page) ?? new Set();
  if (up.size > 0 && ![...up].some((t) => links.has(t))) {
    layerGaps.push({ page, layer: layerByPage.get(page), direction: 'up', candidates: [...up].sort() });
  }
  if (down.size > 0 && ![...down].some((t) => links.has(t))) {
    layerGaps.push({ page, layer: layerByPage.get(page), direction: 'down', candidates: [...down].sort() });
  }
}

// Dead ends: every content page except the landing needs one outgoing link.
const deadEnds = pages.filter((p) => p !== LANDING && (linksByPage.get(p)?.size ?? 0) === 0);

// --- report ------------------------------------------------------------------

console.log('Layer-link check — every page links one layer up and one layer down when pages sharing a feature ID exist');
console.log(`Pages scanned: ${pages.length} (English tree); with feature IDs: ${pagesWithFeatures.length}`);
console.log('');

if (noType.length > 0) {
  console.log(`Pages without a valid type (skipped from layer checks; ${noType.length}):`);
  for (const page of noType) console.log(`  ${page}`);
  console.log('');
}

if (layerGaps.length === 0) {
  console.log('All layer links present. ✓');
} else {
  console.log(`Missing layer links (${layerGaps.length}):`);
  for (const gap of layerGaps) {
    const shown = gap.candidates.slice(0, 4).join(', ') + (gap.candidates.length > 4 ? `, +${gap.candidates.length - 4} more` : '');
    console.log(`  ${gap.page} (${gap.layer}, link ${gap.layer === 'L2' ? (gap.direction === 'up' ? 'L1' : 'L3') : gap.direction === 'up' ? 'L2' : 'L3'}): ${shown}`);
  }
}
console.log('');

console.log(`Dead ends (${deadEnds.length}) — content pages with no outgoing internal content link:`);
if (deadEnds.length === 0) console.log('  none');
for (const page of deadEnds) console.log(`  ${page}`);

if (layerGaps.length > 0 || deadEnds.length > 0) process.exit(1);
process.exit(0);
