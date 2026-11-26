// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Generates site-docs/src/content/docs/reference/feature-index.md from
// site-docs/inventory.yml (the feature inventory, WP 02) plus a front-matter
// scan over every English page — the same data site-docs/scripts/check-coverage.mjs
// reads, with the same parsers. Run: make gen-docs-feature-index
//
// One table per area maps every feature ID to the pages whose `features`
// front-matter cites it (wildcards such as IAM-* expand to their inventory
// IDs). Output is byte-stable: inventory order drives sections, pages are
// sorted, verified_at is pinned. The French page under fr/reference/ takes
// its prose from scripts/gen_docs/fr_overlay/feature-index.json; feature
// names and area headings stay verbatim English in both locales.

import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SITE_ROOT = join(REPO_ROOT, 'site-docs');
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const INVENTORY_PATH = join(SITE_ROOT, 'inventory.yml');
const EXCLUDE_PATH = join(SITE_ROOT, 'coverage-exclude.yml');
const PAGE_PATHS = {
  en: join(SITE_ROOT, 'src', 'content', 'docs', 'reference', 'feature-index.md'),
  fr: join(SITE_ROOT, 'src', 'content', 'docs', 'fr', 'reference', 'feature-index.md'),
};
// The commit where the page content was last verified; both locales pin it.
const VERIFIED_AT = 'f1409cdc';
// French prose for the fr page.
const ov = JSON.parse(readFileSync(new URL('./fr_overlay/feature-index.json', import.meta.url), 'utf8'));

// --- small YAML parsers (same shapes as check-coverage.mjs) ------------------

function parseInventory(text) {
  const features = [];
  const areas = []; // { code, label } from the "# area: CODE (label) — N features" comments
  let current = null;
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const areaComment = line.match(/^#\s*area:\s*([A-Z]+)\s*\(([^)]*)\)/);
    if (areaComment) {
      areas.push({ code: areaComment[1], label: areaComment[2].trim() });
      continue;
    }
    const idMatch = line.match(/^- id:\s*(\S+)\s*$/);
    if (idMatch) {
      if (current) features.push(current);
      current = { id: idMatch[1], name: '', area: '' };
      continue;
    }
    if (!current) continue;
    const nameMatch = line.match(/^name:\s*(.+)$/);
    if (nameMatch) current.name = nameMatch[1].trim();
    const areaMatch = line.match(/^area:\s*(\S+)\s*$/);
    if (areaMatch) current.area = areaMatch[1];
  }
  if (current) features.push(current);
  return { features, areas };
}

function parseExclusions(text) {
  const exclusions = [];
  let current = null;
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    const idMatch = line.match(/^- id:\s*(\S+)\s*$/);
    if (idMatch) {
      if (current) exclusions.push(current);
      current = { id: idMatch[1], reason: '' };
      continue;
    }
    if (!current) continue;
    const reasonMatch = line.match(/^reason:\s*(.+)$/);
    if (reasonMatch) current.reason = reasonMatch[1].trim();
  }
  if (current) exclusions.push(current);
  return exclusions;
}

function parseFrontMatter(text) {
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return match ? match[1] : null;
}

// The page contract fixes features as a flat YAML array on one line.
function parseFeatures(frontMatter) {
  const line = frontMatter.split('\n').find((l) => /^features:/.test(l));
  if (!line) return [];
  const value = line.slice('features:'.length).trim();
  if (!value.startsWith('[') || !value.endsWith(']')) {
    fail(`front-matter features is not a flat one-line array`);
  }
  const inner = value.slice(1, -1).trim();
  if (!inner) return [];
  return inner
    .split(',')
    .map((item) => item.trim().replace(/^['"]|['"]$/g, ''))
    .filter(Boolean);
}

function parseTitle(frontMatter) {
  // `frontMatter` is the block between the `---` fences, so the title key can
  // sit at the start of any line; trim each line before matching, as
  // parseFeatures does for its own key.
  const line = frontMatter.split('\n').map((l) => l.trim()).find((l) => /^title:/.test(l));
  if (!line) return null;
  return line.slice('title:'.length).trim().replace(/^['"]|['"]$/g, '') || null;
}

// --- loud failure ------------------------------------------------------------

function fail(message) {
  console.error(`feature_index.mjs: ${message}`);
  process.exit(1);
}

// --- page scan (same tree walk as check-coverage.mjs) ------------------------

function collectPages(dir, base = dir) {
  const pages = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      // French pages share their feature IDs with the English source page.
      if (entry.name === 'fr') continue;
      pages.push(...collectPages(full, base));
    } else if (entry.name.endsWith('.md') || entry.name.endsWith('.mdx')) {
      pages.push(relative(base, full).split(sep).join('/'));
    }
  }
  return pages;
}

// build/field-types.md -> /build/model/data/field-types/ ; start/index.md -> /discover/
function pageUrl(page) {
  const noExt = page.replace(/\.mdx?$/, '');
  const parts = noExt.split('/');
  if (parts[parts.length - 1] === 'index') parts.pop();
  return '/' + parts.join('/') + '/';
}

function escapeCell(text) {
  return text.replace(/\|/g, '\\|');
}

// --- build the ID -> pages map ------------------------------------------------

const inventoryText = readFileSync(INVENTORY_PATH, 'utf8');
const { features, areas } = parseInventory(inventoryText);
if (features.length === 0) fail(`inventory is empty: ${INVENTORY_PATH}`);
if (areas.length === 0) fail(`no "# area:" comments found in ${INVENTORY_PATH}`);

const areaCodes = new Set(areas.map((area) => area.code));
for (const feature of features) {
  if (!areaCodes.has(feature.area)) {
    fail(`feature ${feature.id} names area ${feature.area}, which no "# area:" comment declares`);
  }
}

const exclusions = parseExclusions(readFileSync(EXCLUDE_PATH, 'utf8'));
const excludedIds = new Set(exclusions.map((entry) => entry.id));

const pages = collectPages(DOCS_DIR).sort();
const coveredBy = new Map(); // inventory id -> Set of page paths

for (const page of pages) {
  const text = readFileSync(join(DOCS_DIR, page), 'utf8');
  const frontMatter = parseFrontMatter(text);
  if (!frontMatter) fail(`${page}: no front-matter block`);
  for (const id of parseFeatures(frontMatter)) {
    if (id.endsWith('-*')) {
      const area = id.slice(0, -2);
      if (!areaCodes.has(area)) fail(`${page}: wildcard ${id} names unknown area ${area}`);
      for (const feature of features) {
        if (feature.area === area) {
          if (!coveredBy.has(feature.id)) coveredBy.set(feature.id, new Set());
          coveredBy.get(feature.id).add(page);
        }
      }
    } else if (features.some((feature) => feature.id === id)) {
      if (!coveredBy.has(id)) coveredBy.set(id, new Set());
      coveredBy.get(id).add(page);
    }
    // IDs outside the inventory are check-coverage's business; this page only
    // maps inventory IDs, so unknowns are ignored here on purpose.
  }
}

// --- emit ---------------------------------------------------------------------

// The Pages cell for one cited page: link text from the page title, href from
// the page URL. The French variant retargets the href to /fr/ and takes the
// link text from the French twin's title when that twin exists. A page with
// no French twin keeps its English href — Starlight serves the English page
// to French readers until WP 22 translates it (decision D8).
function linkCell(page, url, title, locale) {
  if (locale === 'en') return `[${escapeCell(title)}](${url})`;
  const frPath = join(DOCS_DIR, 'fr', page);
  if (!existsSync(frPath)) return `[${escapeCell(title)}](${url})`;
  const frTitle = parseTitle(parseFrontMatter(readFileSync(frPath, 'utf8'))) ?? title;
  return `[${escapeCell(frTitle)}](/fr${url})`;
}

function pagesCellFor(feature, locale) {
  const cited = [...(coveredBy.get(feature.id) ?? [])].sort();
  const cells = cited.map((page) => {
    const url = pageUrl(page);
    const title = parseTitle(parseFrontMatter(readFileSync(join(DOCS_DIR, page), 'utf8'))) ?? url;
    return linkCell(page, url, title, locale);
  });
  if (cells.length > 0) return cells.join(', ');
  return excludedIds.has(feature.id)
    ? locale === 'en' ? 'Excluded from user docs' : ov.excluded_note
    : '—';
}

function emit(locale) {
  const isFr = locale === 'fr';
  const out = [];
  out.push('---');
  out.push(isFr ? 'title: Index des fonctionnalités' : 'title: Feature index');
  out.push(`description: ${isFr ? ov.description : 'Every feature ID mapped to the pages that document it.'}`);
  out.push('audience: [developer, operator]');
  out.push('type: reference');
  out.push('features: []');
  out.push(`verified_at: ${VERIFIED_AT}`);
  out.push('---');
  out.push('');
  out.push(
    isFr
      ? ov.generated_note
      : '> Generated from `site-docs/inventory.yml` by `make gen-docs-feature-index`. Do not edit this file by hand.',
  );
  out.push('');
  out.push(isFr ? ov.intro : `A writer or reviewer traces a feature to its pages — or finds the pages a change must touch. This table maps every feature ID in the inventory (${features.length} features in ${areas.length} areas) to the documentation pages that cover it, generated from the page front-matter. The build's coverage check requires each ID to appear on at least one page or sit on the exclusion list in \`site-docs/coverage-exclude.yml\`. A dash means no page cites the ID yet.`);
  out.push('');
  for (const area of areas) {
    const inArea = features.filter((feature) => feature.area === area.code);
    const heading = area.label ? `${area.code} — ${area.label}` : area.code;
    out.push(`## ${heading}`);
    out.push('');
    out.push(
      isFr
        ? `| ${ov.col_id} | ${ov.col_feature} | ${ov.col_pages} |`
        : '| ID | Feature | Pages |',
    );
    out.push('| --- | --- | --- |');
    for (const feature of inArea) {
      out.push(`| ${feature.id} | ${escapeCell(feature.name)} | ${pagesCellFor(feature, locale)} |`);
    }
    out.push('');
  }
  out.push(`## ${isFr ? ov.related_heading : 'Related'}`);
  out.push('');
  if (isFr) {
    out.push(ov.related_start);
    out.push(ov.related_build);
    out.push(ov.related_govern);
    out.push(ov.related_apps);
    out.push(ov.related_operate);
  } else {
    out.push('- [Getting started](/discover/)');
    out.push('- [Build domains](/build/)');
    out.push('- [Govern access](/admin/)');
    out.push('- [Build apps](/build/apps/)');
    out.push('- [Operate](/admin/)');
  }
  out.push('');
  return out.join('\n');
}

for (const [locale, text] of Object.entries({ en: emit('en'), fr: emit('fr') })) {
  writeFileSync(PAGE_PATHS[locale], text);
}
console.log(`feature_index.mjs: wrote reference/feature-index.md + fr twin (${features.length} features, ${pages.length} pages scanned)`);
