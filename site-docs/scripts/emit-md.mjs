#!/usr/bin/env node
// Raw markdown emit for the documentation site.
//
// Runs after `astro build` (see the build script in package.json) and copies
// every content page into dist/ as a byte-for-byte .md twin of its URL:
//
//   src/content/docs/build/designing-doctypes.md -> dist/build/designing-doctypes.md
//   src/content/docs/start/index.md      -> dist/start.md
//   src/content/docs/fr/start/install.md -> dist/fr/start/install.md
//   src/content/docs/index.mdx           -> dist/index.md
//
// A directory index page collapses to a flat <section>.md next to its
// directory — the same URL the built site serves. Files are copied without
// rewriting: the front-matter (audience, features, verified_at) stays, and a
// diagram stays an HTML comment holding its D2 source plus the <img> pair.
// Coding agents read these twins instead of scraping HTML.

import { copyFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { dirname, extname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const DIST_DIR = join(SITE_ROOT, 'dist');

// src/content/docs/<path> -> dist/<url-path>.md, where <url-path> follows the
// page URL: a directory index page maps to the directory itself.
function targetFor(sourceRel) {
  const withoutExt = sourceRel.slice(0, -extname(sourceRel).length);
  const segments = withoutExt.split(sep);
  if (segments[segments.length - 1] === 'index') segments.pop();
  if (segments.length === 0) segments.push('index');
  return join(DIST_DIR, ...segments) + '.md';
}

function collectSources(dir, base = dir) {
  const sources = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      sources.push(...collectSources(full, base));
    } else if (entry.name.endsWith('.md') || entry.name.endsWith('.mdx')) {
      sources.push(relative(base, full));
    }
  }
  return sources;
}

if (!existsSync(DIST_DIR)) {
  console.error('emit-md: dist/ not found. Run "astro build" first.');
  process.exit(2);
}

const sources = collectSources(DOCS_DIR);
const claimed = new Map(); // dist target -> source that maps to it
let emitted = 0;

for (const source of sources) {
  const target = targetFor(source);
  const previous = claimed.get(target);
  if (previous) {
    console.error(`emit-md: ${previous} and ${source} both map to ${target}.`);
    process.exit(1);
  }
  claimed.set(target, source);
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(join(DOCS_DIR, source), target);
  emitted += 1;
}

console.log(`emit-md: copied ${emitted} raw markdown files into dist/ (one .md twin per page).`);
