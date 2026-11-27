#!/usr/bin/env node
// Copies the committed screenshots into public/screens/ so Astro serves them
// at the URL the pages use.
//
// The capture pipeline (scripts/screens/capture.mjs) writes PNGs to
// src/assets/screens/. Pages embed them with an absolute URL such as
// /screens/build/first-domain-1.png. Astro serves public/ at the site root,
// so the PNGs must appear under public/screens/ to resolve — the copy keeps
// the source files the single committed copy. public/screens/ is gitignored
// (generated, like public/diagrams/).
//
// The URL deliberately lives at the site root, not under /assets/screens/:
// a first path segment of build/, admin/ or reference/ collides with a
// Starlight topic route, and `astro dev` returns 404 for the image because
// the router matches the page prefix before the static handler runs.
// public/ is only served by the static build (astro build/preview), so the
// root path is the safe, collision-free choice. See doc/site-docs.md.
//
// Runs before both `astro build` and `astro dev` — see package.json.

import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const SOURCE = join(SITE_ROOT, 'src', 'assets', 'screens');
const TARGET = join(SITE_ROOT, 'public', 'screens');

if (!existsSync(SOURCE)) {
	console.log('screens: no src/assets/screens/ — nothing to copy.');
	process.exit(0);
}

// Replace, do not merge: a deleted shot must not linger in public/.
rmSync(TARGET, { recursive: true, force: true });
mkdirSync(TARGET, { recursive: true });
cpSync(SOURCE, TARGET, { recursive: true });

console.log('screens: copied src/assets/screens/ -> public/screens/.');
