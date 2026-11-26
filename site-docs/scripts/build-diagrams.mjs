#!/usr/bin/env node
// Build-time D2 rendering for the documentation site.
//
// Every ```d2 fence in src/content/docs/** becomes two SVG files under
// public/diagrams/ — one per theme — and the fence is replaced by an <img>
// pair that CSS toggles with [data-theme]. Nothing renders in the browser: the
// D2 engine stays a build dependency and readers download only the finished
// diagrams.
//
// Source pages are edited in place. The script is idempotent: it renders a
// diagram only when its SVG files are missing, and it deletes an SVG that no
// page references any more.
//
// A fence that does not compile fails the build, with the page and the line,
// so a typo never ships as a raw code block.
//
// See doc/site-docs.md → Diagrams.

import { D2 } from '@terrastruct/d2';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DARK_TOKENS, EDGE_LABEL_COLOR, LIGHT_TOKENS, RENDER_OPTIONS, styleSource } from './diagram-theme.mjs';

const SITE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const DOCS_DIR = join(SITE_ROOT, 'src', 'content', 'docs');
const OUTPUT_DIR = join(SITE_ROOT, 'public', 'diagrams');
// The <img> src: public/ is served at the site root.
const OUTPUT_URL = '/diagrams';

const FENCE_OPEN = /^```d2\s*$/;
const FENCE_CLOSE = /^```\s*$/;
const CAPTION = /^\*([^*].*)\*$/;
// `--force` re-renders every diagram, for a change to the house style.
const FORCE = process.argv.includes('--force');

const d2 = new D2();

function collectPages(dir, base = dir) {
	const pages = [];
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) {
			pages.push(...collectPages(full, base));
		} else if (entry.name.endsWith('.md') || entry.name.endsWith('.mdx')) {
			pages.push(relative(base, full));
		}
	}
	return pages.sort();
}

// The id derives from the source alone, so an unchanged diagram keeps its file
// and the page diff stays empty.
function diagramId(source) {
	return createHash('sha256').update(source).digest('hex').slice(0, 8);
}

function attribute(text) {
	return text.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// The image block carries its own D2 source. On `.md` pages it rides in an
// HTML comment; on `.mdx` pages the same comment is invalid JSX, so the
// source rides in a JSX comment instead. The page
// keeps a readable, copyable source for readers and agents, and the build
// can regenerate the SVG without a separate source file.
function imageBlock(page, id, alt, source) {
	const label = attribute(alt);
	const open = page.endsWith('.mdx') ? '{/* d2' : '<!-- d2';
	const close = page.endsWith('.mdx') ? '*/}' : '-->';
	return [
		`${open}\n${source}\n${close}`,
		`<div class="d2-diagram">`,
		`<img class="d2-diagram__img d2-diagram__light" src="${OUTPUT_URL}/${id}-light.svg" alt="${label}" loading="lazy" />`,
		`<img class="d2-diagram__img d2-diagram__dark" src="${OUTPUT_URL}/${id}-dark.svg" alt="${label}" loading="lazy" />`,
		`</div>`,
	].join('\n');
}

// Both comment forms carry the same payload; the id regex is shared.
const EMBEDDED_MD = /<!-- d2\n([\s\S]*?)\n-->\n<div class="d2-diagram">\n<img[^>]*\/([0-9a-f]{8})-light\.svg/g;
const EMBEDDED_MDX = /\{\/\* d2\n([\s\S]*?)\n\*\/\}\n<div class="d2-diagram">\n<img[^>]*\/([0-9a-f]{8})-light\.svg/g;

// Source blocks already rendered on a page, keyed by diagram id.
function embeddedSources(text) {
	const sources = new Map();
	for (const re of [EMBEDDED_MD, EMBEDDED_MDX]) {
		for (const match of text.matchAll(re)) sources.set(match[2], match[1]);
	}
	return sources;
}

// `.mdx` pages cannot carry the HTML-comment form; migrate any block an
// older build wrote before the extension-aware form existed.
function migrateMdxBlocks(page, text) {
	if (!page.endsWith('.mdx') || !text.includes('<!-- d2')) return text;
	return text.replace(EMBEDDED_MD, (whole, source) => {
		const rest = whole.slice(whole.indexOf('-->') + 3);
		return `{/* d2\n${source}\n*/}${rest}`;
	});
}

// The alt text comes from an italic caption line above the fence, else from
// the first quoted label in the source, so a diagram is never unlabelled.
function altTextFor(lines, fenceIndex, source) {
	const previous = fenceIndex > 0 ? lines[fenceIndex - 1].trim() : '';
	const caption = previous.match(CAPTION);
	if (caption) return caption[1].trim();
	const firstLabel = source.match(/"([^"]+)"/);
	if (firstLabel) return firstLabel[1].split('\\n')[0].trim();
	return 'Diagram';
}

// One compile per theme: each palette is the BASE override, because D2 emits
// `dark-theme-overrides` inside a prefers-color-scheme media block, which a
// data-theme page never triggers.
async function renderTheme(source, tokens) {
	const compiled = await d2.compile(styleSource(source, tokens), RENDER_OPTIONS);
	// A connection label carries a palette code; the muted ink reads best.
	for (const connection of compiled.diagram.connections) {
		if (connection.label) connection.color = EDGE_LABEL_COLOR;
	}
	return d2.render(compiled.diagram, compiled.renderOptions);
}

async function renderPair(source, page) {
	try {
		return {
			light: await renderTheme(source, LIGHT_TOKENS),
			dark: await renderTheme(source, DARK_TOKENS),
		};
	} catch (error) {
		throw new Error(`${page}: a D2 diagram does not compile.\n${error.message}`);
	}
}

async function ensureRendered(id, source, page, counters) {
	const lightPath = join(OUTPUT_DIR, `${id}-light.svg`);
	const darkPath = join(OUTPUT_DIR, `${id}-dark.svg`);
	if (!FORCE && existsSync(lightPath) && existsSync(darkPath)) return;
	const pair = await renderPair(source, page);
	writeFileSync(lightPath, pair.light);
	writeFileSync(darkPath, pair.dark);
	counters.rendered += 1;
}

// Ids and sources of the diagrams a page already carries. After the first run
// a page holds image blocks, not fences, so this is where the build reads the
// source back from.
function referencedIds(text) {
	return new Set([...text.matchAll(/\/diagrams\/([0-9a-f]{8})-(?:light|dark)\.svg/g)].map((m) => m[1]));
}

async function processPage(page, counters) {
	const path = join(DOCS_DIR, page);
	let text = readFileSync(path, 'utf8');
	const migrated = migrateMdxBlocks(page, text);
	if (migrated !== text) {
		writeFileSync(path, migrated);
		text = migrated;
		counters.migrated = (counters.migrated ?? 0) + 1;
	}
	const lines = text.split('\n');
	const output = [];
	const used = referencedIds(text);
	const embedded = embeddedSources(text);

	// Regenerate every diagram the page already carries, so an edited or
	// missing SVG never ships stale.
	for (const [id, source] of embedded) {
		await ensureRendered(id, source, page, counters);
	}

	for (let index = 0; index < lines.length; index += 1) {
		if (!FENCE_OPEN.test(lines[index])) {
			output.push(lines[index]);
			continue;
		}

		let end = index + 1;
		while (end < lines.length && !FENCE_CLOSE.test(lines[end])) end += 1;
		if (end === lines.length) {
			throw new Error(`${page}:${index + 1}: the D2 fence has no closing \`\`\`.`);
		}

		const source = lines.slice(index + 1, end).join('\n');
		const id = diagramId(source);
		used.add(id);
		await ensureRendered(id, source, page, counters);

		// The image carries the caption as its alt text, so drop the line above.
		if (lines[index - 1]?.trim().match(CAPTION)) output.pop();

		output.push(imageBlock(page, id, altTextFor(lines, index, source), source));
		index = end;
	}

	const next = output.join('\n');
	if (next !== text) writeFileSync(path, next);
	return used;
}

async function main() {
	mkdirSync(OUTPUT_DIR, { recursive: true });
	const pages = collectPages(DOCS_DIR);
	const counters = { rendered: 0, removed: 0 };
	const referenced = new Set();

	for (const page of pages) {
		for (const id of await processPage(page, counters)) referenced.add(id);
	}

	for (const entry of readdirSync(OUTPUT_DIR)) {
		if (!entry.endsWith('.svg')) continue;
		const id = entry.replace(/-(light|dark)\.svg$/, '');
		if (referenced.has(id)) continue;
		rmSync(join(OUTPUT_DIR, entry));
		counters.removed += 1;
	}

	console.log(
		`diagrams: ${referenced.size} diagrams on ${pages.length} pages — ` +
			`${counters.rendered} rendered, ${counters.removed} stale files removed.`,
	);
}

main()
	.then(() => {
		// The D2 engine runs in a worker thread that never stops on its own, so
		// the process would hang after printing. Exit once the work is done.
		process.exit(0);
	})
	.catch((error) => {
		console.error(`diagrams: ${error.message}`);
		process.exit(1);
	});
