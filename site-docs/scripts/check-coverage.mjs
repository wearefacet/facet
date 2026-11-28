#!/usr/bin/env node
// Feature coverage and staleness check for the documentation site.
//
// Reads:
//   inventory.yml        — every feature ID the product ships
//   coverage-exclude.yml — IDs that stay out of user docs, with a reason
//   src/content/docs/**  — page front-matter: features: [DOM-03], verified_at: <short SHA>
//
// Reports: per-area coverage table, uncovered and unknown IDs, stale pages.
// Modes:   warn (default) — report only, exit 0
//          --strict       — exit 1 when uncovered or unknown IDs exist
// The build runs this in warn mode through the prebuild npm hook.
//
// Staleness counts days, not releases: whole-doc §5 asks for pages "more than
// N releases old", but release tags do not exist yet (decision D11). Switch to
// a release-based measure when tags exist.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const INVENTORY_PATH = join(SITE_ROOT, 'inventory.yml');
const EXCLUDE_PATH = join(SITE_ROOT, 'coverage-exclude.yml');

// Days after which a page's verified_at commit counts as stale.
const STALE_DAYS = 90;

// --- small YAML parsers -----------------------------------------------------
// The inventory, the exclusion list and the front-matter values use one fixed
// shape (flat lists, one key per line), so a line parser is enough.

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
    // Rule R2 (04-coverage-and-verification.md): an ID whose only sensible
    // documentation is a generated table needs no task page.
    if (/^reference-only:\s*true\s*$/.test(line)) current.referenceOnly = true;
    // WP 10 marks retired features instead of deleting their rows.
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
  if (!line) return { features: [], malformed: false };
  const value = line.slice('features:'.length).trim();
  if (!value.startsWith('[') || !value.endsWith(']')) {
    return { features: [], malformed: true };
  }
  const inner = value.slice(1, -1).trim();
  if (!inner) return { features: [], malformed: false };
  const features = inner
    .split(',')
    .map((item) => item.trim().replace(/^['"]|['"]$/g, ''))
    .filter(Boolean);
  return { features, malformed: false };
}

function parseVerifiedAt(frontMatter) {
  const line = frontMatter.split('\n').find((l) => /^verified_at:/.test(l));
  if (!line) return null;
  const value = line.slice('verified_at:'.length).trim().replace(/^['"]|['"]$/g, '');
  return value || null;
}

// The page type comes from the v2 front-matter contract (00-contract.md §4).
const PAGE_TYPES = ['overview', 'tutorial', 'how-to', 'explanation', 'reference'];
// Rule R2: only these types establish coverage of a feature ID.
const TASK_TYPES = ['how-to', 'tutorial', 'explanation'];

function parseType(frontMatter) {
  const line = frontMatter.split('\n').find((l) => /^type:/.test(l));
  if (!line) return null;
  const value = line.slice('type:'.length).trim().replace(/^['"]|['"]$/g, '');
  return PAGE_TYPES.includes(value) ? value : null;
}

function parseTitle(frontMatter) {
  const line = frontMatter.split('\n').find((l) => /^title:/.test(l));
  if (!line) return null;
  return line.slice('title:'.length).trim().replace(/^['"]|['"]$/g, '');
}

// --- page scan ---------------------------------------------------------------

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

function record(map, key, value) {
  if (!map.has(key)) map.set(key, new Set());
  map.get(key).add(value);
}

function commitDate(sha) {
  try {
    return execFileSync('git', ['-C', SITE_ROOT, 'log', '-1', '--format=%cI', sha], {
      encoding: 'utf8',
    }).trim();
  } catch {
    return null;
  }
}

// --- output helpers ----------------------------------------------------------

function printWrapped(items, indent = '  ') {
  const width = 78;
  let line = indent;
  for (const item of items) {
    const piece = (line === indent ? '' : ', ') + item;
    if (line !== indent && line.length + piece.length > width) {
      console.log(line);
      line = indent + item;
    } else {
      line += piece;
    }
  }
  if (line.trim()) console.log(line);
}

function printUnknown(unknown) {
  if (unknown.size === 0) {
    console.log('  none');
    return;
  }
  for (const [id, pages] of unknown) {
    console.log(`  ${id} — ${[...pages].join(', ')}`);
  }
}

// --- main --------------------------------------------------------------------

const strict = process.argv.includes('--strict');
console.log(`Feature coverage check — ${strict ? 'strict' : 'warn'} mode`);
console.log(
  strict
    ? 'Fails when uncovered or unknown feature IDs exist.'
    : 'Report only. Run with --strict to fail on uncovered or unknown IDs.',
);
console.log('');

if (!existsSync(INVENTORY_PATH)) {
  console.error(`Inventory not found: ${INVENTORY_PATH}`);
  process.exit(2);
}

const inventory = parseInventory(readFileSync(INVENTORY_PATH, 'utf8'));
if (inventory.length === 0) {
  console.error(`Inventory is empty: ${INVENTORY_PATH}`);
  process.exit(2);
}
const byId = new Map(inventory.map((feature) => [feature.id, feature]));
const areas = [...new Set(inventory.map((feature) => feature.area))];

const exclusions = existsSync(EXCLUDE_PATH)
  ? parseExclusions(readFileSync(EXCLUDE_PATH, 'utf8'))
  : [];
const excludedIds = new Set(exclusions.map((entry) => entry.id));

const pagePaths = collectPages(DOCS_DIR);
const coveredBy = new Map(); // inventory id -> task pages (R2) that cite it
const citedBy = new Map(); // inventory id -> any page that cites it
const unknown = new Map(); // page id -> pages that cite it
const problems = []; // pages whose features front-matter breaks the contract
const missingType = []; // English pages without a valid type (landing exempt)
const longTitles = []; // titles over 40 characters (01-voice-and-vibe.md §6)
const emptyFeatures = []; // rule R5: non-overview pages with features: []

for (const page of pagePaths) {
  const text = readFileSync(join(DOCS_DIR, page), 'utf8');
  const frontMatter = parseFrontMatter(text);
  if (!frontMatter) {
    problems.push(`${page}: no front-matter block`);
    continue;
  }
  const { features, malformed } = parseFeatures(frontMatter);
  if (malformed) {
    problems.push(`${page}: features is not a flat one-line array`);
  }
  const type = parseType(frontMatter);
  if (!type && page !== 'index.mdx') {
    missingType.push(page);
  }
  const title = parseTitle(frontMatter);
  if (title && title.length > 40) {
    longTitles.push(`${page} — "${title}" (${title.length})`);
  }
  if (type && type !== 'overview' && features.length === 0 && page !== 'index.mdx') {
    emptyFeatures.push(`${page} (${type})`);
  }
  for (const id of features) {
    if (id.endsWith('-*')) {
      // A wildcard expands to every inventory ID of that area; the expansion,
      // not the wildcard, counts as coverage.
      const area = id.slice(0, -2);
      if (areas.includes(area)) {
        for (const feature of inventory) {
          if (feature.area === area) {
            record(citedBy, feature.id, page);
            if (TASK_TYPES.includes(type)) record(coveredBy, feature.id, page);
          }
        }
      } else {
        record(unknown, id, page);
      }
    } else if (byId.has(id)) {
      record(citedBy, id, page);
      if (TASK_TYPES.includes(type)) record(coveredBy, id, page);
      if (byId.get(id).removed) {
        // A removed feature keeps its row only so old citations surface here.
        record(unknown, id, page);
      }
    } else {
      record(unknown, id, page);
    }
  }
}

const uncovered = inventory
  .filter(
    (feature) =>
      !coveredBy.has(feature.id) &&
      !excludedIds.has(feature.id) &&
      !feature.referenceOnly &&
      !feature.removed,
  )
  .map((feature) =>
    citedBy.has(feature.id)
      ? `${feature.id} (cited, but only on overview/reference pages)`
      : feature.id,
  );

// --- coverage table ----------------------------------------------------------

console.log(
  `Inventory: ${inventory.length} features in ${areas.length} areas. ` +
    `Pages scanned: ${pagePaths.length} (English tree).`,
);
if (exclusions.length > 0) {
  console.log(
    `Excluded from the check: ${exclusions.map((entry) => entry.id).join(', ')}.`,
  );
}
console.log('');

const nameWidth = Math.max('Area'.length, ...areas.map((area) => area.length));
const header =
  'Area'.padEnd(nameWidth) + '  Total  Covered  Uncovered  Excluded';
console.log(header);
console.log('-'.repeat(header.length));
let totalTotal = 0;
let totalCovered = 0;
let totalUncovered = 0;
let totalExcluded = 0;
for (const area of areas) {
  const inArea = inventory.filter((feature) => feature.area === area);
  const covered = inArea.filter((feature) => coveredBy.has(feature.id)).length;
  const excluded = inArea.filter(
    (feature) => excludedIds.has(feature.id) && !coveredBy.has(feature.id),
  ).length;
  const uncoveredCount = inArea.length - covered - excluded;
  totalTotal += inArea.length;
  totalCovered += covered;
  totalUncovered += uncoveredCount;
  totalExcluded += excluded;
  console.log(
    area.padEnd(nameWidth) +
      String(inArea.length).padStart(7) +
      String(covered).padStart(9) +
      String(uncoveredCount).padStart(11) +
      String(excluded).padStart(10),
  );
}
console.log(
  'All'.padEnd(nameWidth) +
    String(totalTotal).padStart(7) +
    String(totalCovered).padStart(9) +
    String(totalUncovered).padStart(11) +
    String(totalExcluded).padStart(10),
);
console.log('');

console.log(`Uncovered IDs (rule R2 — no how-to/tutorial/explanation page cites them; ${uncovered.length}):`);
printWrapped(uncovered);
console.log('');
console.log(`Unknown IDs on pages, not in the inventory (${unknown.size}):`);
printUnknown(unknown);
if (missingType.length > 0) {
  console.log('');
  console.log(`Pages without a valid type — overview, tutorial, how-to, explanation, reference (${missingType.length}):`);
  printWrapped(missingType);
}
if (longTitles.length > 0) {
  console.log('');
  console.log(`Titles longer than 40 characters (01-voice-and-vibe.md §6; ${longTitles.length}):`);
  for (const entry of longTitles) console.log(`  ${entry}`);
}
if (emptyFeatures.length > 0) {
  console.log('');
  console.log(`Rule R5 — non-overview pages with an empty features list (${emptyFeatures.length}):`);
  printWrapped(emptyFeatures);
}
if (problems.length > 0) {
  console.log('');
  console.log(`Front-matter problems (${problems.length}):`);
  for (const problem of problems) console.log(`  ${problem}`);
}

// --- staleness report --------------------------------------------------------

const stale = [];
const missingMarker = [];
const unresolvable = [];
for (const page of pagePaths) {
  const frontMatter = parseFrontMatter(readFileSync(join(DOCS_DIR, page), 'utf8'));
  const sha = frontMatter ? parseVerifiedAt(frontMatter) : null;
  if (!sha) {
    missingMarker.push(page);
    continue;
  }
  const iso = commitDate(sha);
  if (!iso) {
    unresolvable.push(`${page} (${sha})`);
    continue;
  }
  const ageDays = Math.floor((Date.now() - Date.parse(iso)) / 86400000);
  if (ageDays > STALE_DAYS) stale.push({ page, sha, date: iso.slice(0, 10), ageDays });
}

console.log('');
console.log(
  `Staleness report — threshold ${STALE_DAYS} days (days, not releases: ` +
    'release tags do not exist yet)',
);
console.log(`  Stale pages (${stale.length}):`);
for (const entry of stale) {
  console.log(`    ${entry.page} — ${entry.sha} (${entry.date}, ${entry.ageDays} days old)`);
}
if (stale.length === 0) console.log('    none');
console.log(`  Pages without a verified_at marker (${missingMarker.length}):`);
printWrapped(missingMarker, '    ');
console.log(`  Markers git could not resolve (${unresolvable.length}):`);
printWrapped(unresolvable, '    ');

// --- exit --------------------------------------------------------------------

if (strict && (uncovered.length > 0 || unknown.size > 0)) {
  console.log('');
  console.log('Strict mode: uncovered or unknown IDs exist. Build blocked.');
  process.exit(1);
}
process.exit(0);
