#!/usr/bin/env node
// One-off generator for public/og.png — the default Open Graph image.
//
// The social-card canvas is the dark theme surface with the dark lockup
// centered on it. Re-run by hand when the brand art changes; the result is
// committed, so the build never depends on sharp rendering:
//
//   node scripts/build-og-image.mjs
//
// See doc/site-docs.md → Social card.

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const OUTPUT = join(SITE_ROOT, 'public', 'og.png');

const WIDTH = 1200;
const HEIGHT = 630;
const BG = '#11151c'; // [data-theme='dark'] --surface

// The lockup is a wide gem + wordmark; scale it to about half the canvas
// width and center it.
const lockup = readFileSync(join(SITE_ROOT, 'src/assets/facet-lockup-dark.svg'), 'utf8');
const viewBox = lockup.match(/viewBox="([\d.\s]+)"/)[1].split(/\s+/).map(Number);
const scale = 560 / viewBox[2];

const canvas = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">
<rect width="${WIDTH}" height="${HEIGHT}" fill="${BG}"/>
<g transform="translate(${(WIDTH - 560) / 2}, ${(HEIGHT - viewBox[3] * scale) / 2}) scale(${scale})">
${lockup.replace(/<\?xml[^>]*\?>/, '').replace(/<svg[^>]*>/, '').replace('</svg>', '')}
</g>
</svg>`;

const png = await sharp(Buffer.from(canvas)).png().toBuffer();
writeFileSync(OUTPUT, png);

const metadata = await sharp(png).metadata();
console.log(`og-image: ${OUTPUT} — ${metadata.width}x${metadata.height}, ${Math.round(png.length / 1024)} KiB.`);
