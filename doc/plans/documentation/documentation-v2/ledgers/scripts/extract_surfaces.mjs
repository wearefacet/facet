#!/usr/bin/env node
// Surface extraction for the documentation-v2 plan (WP 10, deliverable 2).
// Walks the source registries and prints one markdown table per surface
// kind, so ledgers/surfaces.md maps every user-visible surface to a feature
// ID without hand-listing. Re-run with:
//   node extract_surfaces.mjs > ../surfaces-raw.md
// (run from doc/plans/documentation/documentation-v2/ledgers/scripts/)

import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = process.env.FACET_ROOT ?? '../../../../..';

function walk(dir, ext, base = dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === 'dist') continue;
      walk(full, ext, base, out);
    } else if (entry.name.endsWith(ext)) {
      out.push(relative(base, full).split(sep).join('/'));
    }
  }
  return out;
}

function section(title, body) {
  console.log(`\n## ${title}\n`);
  console.log(body || '(nothing found)');
}

function mdTable(header, rows) {
  return [`| ${header.join(' | ')} |`, `|${header.map(() => '---').join('|')}|`, ...rows].join('\n');
}

// --- 1. HTTP routes ----------------------------------------------------------

const routeRows = [];
for (const file of walk(join(ROOT, 'src'), '.cr', join(ROOT, 'src'))) {
  const text = readFileSync(join(ROOT, 'src', file), 'utf8');
  const re = /\b(get|post|patch|put|delete|ws)\s+"([^"]+)"/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    routeRows.push(`| ${m[1].toUpperCase()} \`${m[2]}\` | src/${file} |`);
  }
}
// dedupe on method+path
const seen = new Set();
const routeRowsUnique = routeRows.filter((r) => {
  const key = r.split('|')[1] + r.split('|')[2];
  if (seen.has(key)) return false;
  seen.add(key);
  return true;
});
section(
  'HTTP routes (src/**)',
  mdTable(['Surface', 'Registered in'], routeRowsUnique.sort()),
);

// --- 2. facet CLI commands ---------------------------------------------------

const cliText = readFileSync(join(ROOT, 'src/cli/commands.cr'), 'utf8');
const cliRows = [];
{
  const re = /command\("([^"]+)",\s*"([^"]+)"/g;
  let m;
  while ((m = re.exec(cliText)) !== null) {
    cliRows.push(`| \`facet ${m[1]}\` | ${m[2].replace(/\|/g, '/')} |`);
  }
}
section('facet CLI commands (src/cli/commands.cr)', mdTable(['Command', 'Description'], cliRows));

// --- 3. @facetapp/cli commands ----------------------------------------------

const npmCmdRows = [];
for (const file of walk(join(ROOT, 'packages/cli/src/commands'), '.ts', join(ROOT, 'packages/cli/src/commands'))) {
  npmCmdRows.push(`| ${file.replace(/\.ts$/, '')} | packages/cli/src/commands/${file} |`);
}
section('@facetapp/cli commands (packages/cli/src/commands/)', mdTable(['Command', 'Source'], npmCmdRows.sort()));

// --- 4. Cron tasks -----------------------------------------------------------

const cronRows = walk(join(ROOT, 'src/cron'), '.cr', join(ROOT, 'src/cron'))
  .map((f) => `| ${f.replace(/\.cr$/, '')} | src/cron/${f} |`);
section('Cron tasks (src/cron/)', mdTable(['Task', 'Source'], cronRows.sort()));

// --- 5. Field types ----------------------------------------------------------

const fieldRows = walk(join(ROOT, 'src/doctype/field_types'), '.cr', join(ROOT, 'src/doctype/field_types'))
  .map((f) => `| ${f.replace(/\.cr$/, '')} | src/doctype/field_types/${f} |`);
section('Field types (src/doctype/field_types/)', mdTable(['Type', 'Source'], fieldRows.sort()));

// --- 6. Agent tools ----------------------------------------------------------

const toolSet = new Map();
for (const file of walk(join(ROOT, 'src/agent_tools'), '.cr', join(ROOT, 'src/agent_tools'))) {
  const text = readFileSync(join(ROOT, 'src/agent_tools', file), 'utf8');
  const re = /name:\s*"([a-z_]+)"/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (!toolSet.has(m[1])) toolSet.set(m[1], `src/agent_tools/${file}`);
  }
}
const toolRows = [...toolSet.entries()]
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([name, file]) => `| \`${name}\` | ${file} |`);
section('Agent tools (src/agent_tools/)', mdTable(['Tool', 'Registered in'], toolRows));

// --- 7. System settings keys -------------------------------------------------

const sysRows = [];
{
  const text = readFileSync(join(ROOT, 'src/system_settings/spec.cr'), 'utf8');
  const re = /"([a-z_]+(?:\.[a-z_]+)+)"/g;
  const keys = new Set();
  let m;
  while ((m = re.exec(text)) !== null) keys.add(m[1]);
  for (const key of [...keys].sort()) sysRows.push(`| \`${key}\` | src/system_settings/spec.cr |`);
}
section('System settings keys (src/system_settings/spec.cr)', mdTable(['Key', 'Source'], sysRows));

// --- 8. Account settings keys ------------------------------------------------

const accRows = [];
{
  const text = readFileSync(join(ROOT, 'src/settings/keys.cr'), 'utf8');
  const re = /"([a-z_]+(?:\.[a-z_]+)+)"/g;
  const keys = new Set();
  let m;
  while ((m = re.exec(text)) !== null) keys.add(m[1]);
  for (const key of [...keys].sort()) accRows.push(`| \`${key}\` | src/settings/keys.cr |`);
}
section('Account settings keys (src/settings/keys.cr)', mdTable(['Key', 'Source'], accRows));

// --- 9. Lua bindings ---------------------------------------------------------

const luaRows = [];
{
  const text = readFileSync(join(ROOT, 'src/lua/sandbox.cr'), 'utf8');
  const re = /"((?:util|document|notification|math|date|os)\.[a-z_]+)"/g;
  const names = new Set();
  let m;
  while ((m = re.exec(text)) !== null) names.add(m[1]);
  for (const name of [...names].sort()) luaRows.push(`| \`${name}\` | src/lua/sandbox.cr |`);
}
section('Lua bindings (src/lua/sandbox.cr, string keys)', mdTable(['Function', 'Source'], luaRows));

// --- 10. Metrics and health names --------------------------------------------

const metricRows = [];
{
  const text = readFileSync(join(ROOT, 'src/metrics.cr'), 'utf8');
  const re = /"((?:facet_|facet\.)[a-z0-9_.]+)"/g;
  const names = new Set();
  let m;
  while ((m = re.exec(text)) !== null) names.add(m[1]);
  for (const name of [...names].sort()) metricRows.push(`| \`${name}\` | src/metrics.cr |`);
}
section('Metric names (src/metrics.cr)', mdTable(['Name', 'Source'], metricRows));

// --- 11. Frontend routes -----------------------------------------------------

const feRows = [];
for (const file of walk(join(ROOT, 'frontend/src/routes'), '+page.svelte', join(ROOT, 'frontend/src/routes'))) {
  const path = file
    .replace(/\/\+page\.svelte$/, '')
    .replace(/\(.*?\)\//g, '')
    .replace(/^$/, '/');
  feRows.push(`| \`/${path}\` | frontend/src/routes/${file} |`);
}
section('Frontend routes (frontend/src/routes/**/+page.svelte)', mdTable(['Route', 'Source'], feRows.sort()));

// --- 12. UI label groups -----------------------------------------------------

const labelRows = [];
{
  const messages = JSON.parse(readFileSync(join(ROOT, 'frontend/messages/en.json'), 'utf8'));
  function countLeaves(obj) {
    if (typeof obj === 'string') return 1;
    return Object.values(obj).reduce((sum, v) => sum + countLeaves(v), 0);
  }
  for (const [group, value] of Object.entries(messages)) {
    if (typeof value === 'object' && value !== null) {
      labelRows.push(`| \`${group}.*\` | ${countLeaves(value)} labels |`);
    } else {
      labelRows.push(`| \`${group}\` | 1 label |`);
    }
  }
}
section('UI label groups (frontend/messages/en.json)', mdTable(['Group', 'Labels'], labelRows.sort()));

console.log('\n---\n');
console.log('Extraction complete. Map each surface to its feature ID in');
console.log('ledgers/surfaces.md; leave the new-page column to the content WPs.');
