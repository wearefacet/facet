// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd
//
// Generates site-docs/src/content/docs/reference/cli-npm.md from the
// @facetapp/cli package's own help output. Run: make gen-docs-npm-cli
//
// Mechanism: the page embeds what the CLI itself prints. The script derives
// the run entry from packages/cli/package.json (`bin.facet-cli` -> dist
// entry), refuses to run when dist/ is older than src/ (stale capture), then
// executes `--help` on the entry and on every subcommand, strips ANSI codes,
// and parses the blocks with anchored patterns. Any help shape it does not
// recognize stops the generation instead of silently dropping a command.
//
// Capture note: at first capture the package's dist/ was stale against src/,
// so `pnpm build` was run in packages/cli before generating (see report).
//
// Columns: Command, Options and Purpose are parsed from the captured help
// output — those cells stay verbatim English in both locales. Nothing is
// hand-written. The French page under fr/reference/ takes its prose from
// scripts/gen_docs/fr_overlay/cli-npm.json.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const PKG_DIR = path.join(REPO_ROOT, 'packages', 'cli');
const PAGE_PATHS = {
  en: path.join(REPO_ROOT, 'site-docs', 'src', 'content', 'docs', 'reference', 'cli-npm.md'),
  fr: path.join(REPO_ROOT, 'site-docs', 'src', 'content', 'docs', 'fr', 'reference', 'cli-npm.md'),
};
// The commit where the page content was last verified; both locales pin it.
const VERIFIED_AT = 'f1409cdc';
// French prose for the fr page.
const ov = JSON.parse(fs.readFileSync(new URL('./fr_overlay/cli-npm.json', import.meta.url), 'utf8'));

function fail(message) {
  console.error(`gen_docs/npm_cli: ${message}`);
  process.exit(1);
}

function stripAnsi(text) {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\x1B\[[0-9;]*[A-Za-z]/g, '');
}

function runCapture(args) {
  const result = spawnSync('node', args, { cwd: REPO_ROOT, encoding: 'utf8' });
  if (result.error) fail(`cannot run node ${args.join(' ')}: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`node ${args.join(' ')} exited ${result.status}: ${stripAnsi(result.stderr).trim()}`);
  }
  return stripAnsi(result.stdout);
}

// ── Package facts ───────────────────────────────────────────────────────

const pkg = JSON.parse(fs.readFileSync(path.join(PKG_DIR, 'package.json'), 'utf8'));
const binRel = pkg.bin && pkg.bin['facet-cli'];
if (!binRel) fail('packages/cli/package.json has no bin.facet-cli entry');
const entry = path.join(PKG_DIR, binRel);
if (!fs.existsSync(entry)) fail(`dist entry ${binRel} does not exist — run pnpm build in packages/cli`);

const nodeEngines = pkg.engines && pkg.engines.node;
if (!nodeEngines) fail('packages/cli/package.json has no engines.node value');
const nodeMin = nodeEngines.startsWith('>=') ? nodeEngines.slice(2) : nodeEngines;

// Freshness gate: a stale dist/ would capture help that no longer matches src/.
const distMtime = fs.statSync(entry).mtimeMs;
let newestSrc = 0;
const walk = (dir) => {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) walk(p);
    else if (name.endsWith('.ts')) newestSrc = Math.max(newestSrc, st.mtimeMs);
  }
};
walk(path.join(PKG_DIR, 'src'));
if (newestSrc > distMtime) {
  fail('packages/cli dist/ is stale against src/ — run `pnpm build` in packages/cli first');
}

// ── Capture ─────────────────────────────────────────────────────────────

const topHelp = runCapture([entry, '--help']);

// Parse the top-level Commands block. Commander wraps long descriptions at
// the terminal width; a wrapped continuation is an indented line that does
// not start a new entry, so the parser re-joins it and stays independent of
// the wrap width. Every non-continuation line must match; `help` is the
// commander built-in and gets no sub-help capture.
const commands = [];
let inCommands = false;
for (const line of topHelp.split('\n')) {
  if (line.startsWith('Commands:')) {
    inCommands = true;
    continue;
  }
  if (!inCommands) continue;
  if (line.trim() === '') break;
  const m = line.match(/^  (\S+(?: \[[^\]]+\])?(?: <[^>]+>)?)\s{2,}(.+)$/);
  if (m) {
    commands.push({ spec: m[1], purpose: m[2].trim() });
  } else if (commands.length > 0 && /^\s{2,}\S/.test(line)) {
    commands[commands.length - 1].purpose += ' ' + line.trim();
  } else {
    fail(`unrecognized top-level Commands line: ${JSON.stringify(line)}`);
  }
}
if (commands.length === 0) fail('top-level help carries no Commands block');

for (const cmd of commands) {
  cmd.name = cmd.spec.split(' ')[0];
  cmd.args = cmd.spec.slice(cmd.name.length).trim();
  if (cmd.name === 'help') {
    cmd.builtin = true;
  } else {
    cmd.help = runCapture([entry, cmd.name, '--help']);
  }
}

// Parse one subcommand help block into { description, options }.
function parseSubHelp(text) {
  const lines = text.split('\n');
  const usage = lines.findIndex((l) => l.startsWith('Usage:'));
  if (usage !== 0) fail(`subcommand help does not start with a Usage line: ${JSON.stringify(lines[0])}`);
  let i = usage + 1;
  while (i < lines.length && lines[i].trim() === '') i += 1;
  if (i >= lines.length) fail('subcommand help has no description line');
  const description = lines[i].trim();
  i += 1;
  const options = [];
  let inOptions = false;
  for (; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.startsWith('Options:')) {
      inOptions = true;
      continue;
    }
    if (!inOptions) continue;
    if (line.trim() === '') break;
    const m = line.match(/^  (-\S+(?:, -\S+)?(?: <[^>]+>)?)\s{2,}(.+)$/);
    if (m) {
      if (m[1].startsWith('-h')) continue; // help flag is documented once at the top level
      options.push(m[1]);
    } else if (options.length > 0 && /^\s{2,}\S/.test(line)) {
      // Wrapped continuation of the previous option description; only the
      // flags are used, so the text is dropped.
    } else {
      fail(`unrecognized option line: ${JSON.stringify(line)}`);
    }
  }
  return { description, options };
}

for (const cmd of commands) {
  if (cmd.builtin) continue;
  const parsed = parseSubHelp(cmd.help);
  cmd.description = parsed.description;
  cmd.options = parsed.options;
  // The subcommand description must agree with the top-level listing.
  if (cmd.description !== cmd.purpose) {
    fail(`help description drift for ${cmd.name}: top level says ${JSON.stringify(cmd.purpose)}, sub help says ${JSON.stringify(cmd.description)}`);
  }
}

// ── Emit ────────────────────────────────────────────────────────────────

const esc = (s) => s.replace(/\|/g, '\\|');

const fm = [
  '---',
  'title: Facet app CLI',
  'description: Commands and options of the @facetapp/cli developer tool.',
  'audience: [developer]',
  'type: reference',
  'features: [APP-09]',
  `verified_at: ${VERIFIED_AT}`,
  '---',
].join('\n');

const parts = [];
parts.push(fm);
parts.push('> Generated from `packages/cli` by `make gen-docs-npm-cli`. Do not edit this file by hand.');
parts.push(
  'The `@facetapp/cli` npm package deploys a static build folder as a new ' +
    'revision of a Facet app. It lists and activates revisions and manages ' +
    'sign-in against a Facet instance. No install step is required: run the ' +
    'commands through `pnpx @facetapp/cli`. The package needs Node ' + nodeMin + ' or newer. ' +
    'Commands read `facet.config.json` from the working directory; `init` writes it.'
);
parts.push('## Commands');
const commandRows = [];
for (const cmd of commands) {
  const args = cmd.args.replace(/\[options\]\s*/, '').trim();
  const name = args ? `\`${esc(cmd.name)} ${esc(args)}\`` : `\`${esc(cmd.name)}\``;
  const options = cmd.builtin || cmd.options.length === 0 ? '—' : cmd.options.map((o) => `\`${esc(o)}\``).join(', ');
  commandRows.push(`| ${name} | ${options} | ${esc(cmd.purpose)} |`);
}
parts.push(['| Command | Options | Purpose |', '| --- | --- | --- |', ...commandRows].join('\n'));
parts.push('## Help output');
parts.push('The blocks below are the captured help texts of the package.');
parts.push(['### `facet-cli`', '```text', topHelp.trimEnd(), '```'].join('\n'));
for (const cmd of commands) {
  if (cmd.builtin) continue; // the top-level block already lists the built-in help command
  parts.push([`### \`facet-cli ${esc(cmd.name)}\``, '```text', cmd.help.trimEnd(), '```'].join('\n'));
}
parts.push('## Related');
parts.push(
  [
    '- [Quickstart: the dev CLI](/apps/quickstart-dev-cli/) — install-free first deploy.',
    '- [Hosting and deploying apps](/apps/hosting-deploy/) — what a deployment is and how activation works.',
  ].join('\n')
);

// ── French twin ────────────────────────────────────────────────────────────

const frParts = [];
frParts.push(
  [
    '---',
    'title: CLI des apps Facet',
    `description: ${ov.description}`,
    'audience: [developer]',
    'type: reference',
    'features: [APP-09]',
    `verified_at: ${VERIFIED_AT}`,
    '---',
  ].join('\n')
);
frParts.push(ov.generated_note);
frParts.push(ov.intro);
frParts.push(ov.commands_heading);
frParts.push([`| ${ov.col_command} | ${ov.col_options} | ${ov.col_purpose} |`, '| --- | --- | --- |', ...commandRows].join('\n'));
frParts.push(ov.help_heading);
frParts.push(ov.help_intro);
frParts.push(['### `facet-cli`', '```text', topHelp.trimEnd(), '```'].join('\n'));
for (const cmd of commands) {
  if (cmd.builtin) continue;
  frParts.push([`### \`facet-cli ${esc(cmd.name)}\``, '```text', cmd.help.trimEnd(), '```'].join('\n'));
}
frParts.push(`## ${ov.related_heading}`);
frParts.push([ov.related_quickstart, ov.related_hosting].join('\n'));

for (const [locale, text] of Object.entries({ en: parts.join('\n\n') + '\n', fr: frParts.join('\n\n') + '\n' })) {
  const target = PAGE_PATHS[locale];
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, text);
}
console.log('gen_docs/npm_cli: wrote reference/cli-npm.md + fr twin (' + commands.length + ' commands)');
