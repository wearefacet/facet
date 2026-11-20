#!/usr/bin/env node
// Guards the diagram pipeline.
//
// Fails the build when a page still carries a mermaid fence, or a D2 fence the
// renderer has not converted yet. Both would reach readers as a raw code block,
// because no client script renders diagrams any more: scripts/build-diagrams.mjs
// turns every fence into two SVG files at build time.

import { readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');

const FENCE = /^```(mermaid|d2)\s*$/;

function collectPages(dir, base = dir) {
	const pages = [];
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) {
			pages.push(...collectPages(full, base));
		} else if (entry.name.endsWith('.md') || entry.name.endsWith('.mdx')) {
			pages.push(relative(base, full).split(sep).join('/'));
		}
	}
	return pages.sort();
}

const problems = [];
for (const page of collectPages(DOCS_DIR)) {
	const lines = readFileSync(join(DOCS_DIR, page), 'utf8').split('\n');
	lines.forEach((line, index) => {
		const match = line.match(FENCE);
		if (!match) return;
		const hint = match[1] === 'mermaid' ? 'convert it to D2' : 'run "npm run diagrams"';
		problems.push(`${page}:${index + 1}: ${match[1]} fence — ${hint}.`);
	});
}

if (problems.length > 0) {
	console.error('check-diagrams: diagram sources are out of date.');
	for (const problem of problems) console.error(`  ${problem}`);
	process.exit(1);
}

console.log('check-diagrams: every diagram is a built SVG.');
