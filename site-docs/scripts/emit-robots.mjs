#!/usr/bin/env node
// Postbuild step: emits dist/robots.txt from the site URL in astro.config.mjs.
//
// The robots.txt lives in dist, not public/, so the domain is declared once
// (scripts/site-url.mjs) and cannot drift from the sitemap and canonical
// URLs. The build runs it after emit-md — see package.json → scripts.build.
// It does not import astro.config.mjs directly: the config's plugin chain
// ships TypeScript files that plain Node cannot load.

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SITE_URL } from './site-url.mjs';

const DIST = join(fileURLToPath(new URL('..', import.meta.url)), 'dist');

writeFileSync(
	join(DIST, 'robots.txt'),
	[
		'User-agent: *',
		'Allow: /',
		'',
		`Sitemap: ${SITE_URL}/sitemap-index.xml`,
		'',
	].join('\n'),
);
console.log(`robots: dist/robots.txt — sitemap at ${SITE_URL}/sitemap-index.xml.`);
