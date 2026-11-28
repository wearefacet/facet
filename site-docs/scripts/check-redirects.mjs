// WP 11 redirect gate: every URL from the pre-restructure sitemap must still
// answer. A URL either serves a page (unchanged path) or serves Astro's
// static redirect (meta refresh) / a 3xx to its new path. Usage:
// node scripts/check-redirects.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const lines = readFileSync(
	path.join(root, 'doc/plans/documentation/documentation-v2/ledgers/old-sitemap-urls.txt'),
	'utf8',
)
	.split('\n')
	.filter((l) => l.startsWith('http'));

const base = 'http://localhost:4321';
const failures = [];
let redirected = 0;
let direct = 0;

for (const url of lines) {
	const pathname = new URL(url).pathname;
	let res;
	try {
		res = await fetch(base + pathname, { redirect: 'manual' });
	} catch (err) {
		failures.push(`${pathname} — fetch failed: ${err.message}`);
		continue;
	}
	if ([301, 302, 308].includes(res.status)) {
		redirected++;
		continue;
	}
	const body = await res.text();
	if (res.status === 200) {
		if (/http-equiv=["']refresh["']/i.test(body) || /Moved Permanently/i.test(body)) {
			redirected++;
		} else {
			// A real page answers with its own Starlight title ("… | Facet").
			// Pages may legitimately mention "404" in their body (error
			// references), so the decision reads the title, not the body.
			const title = (body.match(/<title>([^<]*)<\/title>/)?.[1] ?? '').trim();
			if (/^(404|Page not found)\b/i.test(title)) {
				failures.push(`${pathname} — served the 404 page with HTTP 200`);
			} else {
				direct++;
			}
		}
	} else {
		failures.push(`${pathname} — HTTP ${res.status}`);
	}
}

console.log(`Checked ${lines.length} old URLs: ${direct} serve directly, ${redirected} redirect, ${failures.length} failed.`);
for (const failure of failures.slice(0, 20)) console.log(`  ${failure}`);
process.exit(failures.length > 0 ? 1 : 0);
