// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Minimal Jinja2-subset renderer for client-side templates, coherent with
 * the backend `Templating` engine (Crinja, `src/templating.cr`) that renders
 * the `display_name` / `search` templates:
 *
 * - `{{ path }}` placeholders; dotted paths walk nested objects
 *   (`{{ address.postal_code }}`), like the backend's top-level field
 *   bindings.
 * - The `content.` prefix walks the raw document tree
 *   (`{{ content.address.postal_code }}`), mirroring the backend's reserved
 *   `content` variable.
 * - A field missing from the data renders empty — an absent optional field
 *   is a normal state, never an error.
 * - A money object (`{value, currency}` pair of strings) renders as
 *   `"<currency> <value>"` instead of a JSON dump, the same shape-based
 *   formatting the backend applies.
 * - Plain text is kept verbatim.
 *
 * Unsupported Jinja — filters (`{{ name | upper }}`), `{% %}` blocks,
 * `{# #}` comments — matches no placeholder and therefore renders verbatim.
 * Authored templates stay visible in the output instead of failing silently.
 */

const TOKEN_RE = /\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/g;

/** A money object: the stored `{value, currency}` pair of strings. */
interface MoneyShape {
	value: unknown;
	currency: unknown;
}

/** Renders one resolved value the way the backend template context prints it. */
function renderValue(v: unknown): string {
	if (v == null) return '';
	if (typeof v === 'string') return v;
	if (typeof v === 'number' || typeof v === 'boolean') return String(v);
	if (isMoney(v)) return `${v.currency} ${v.value}`;
	if (Array.isArray(v)) return v.map((e) => renderValue(e)).join(', ');
	// A plain object printed as a leaf renders empty — the same behaviour a
	// walkable backend node has when it is not money-shaped.
	return '';
}

/** Shape-based money detection — the same rule the backend context uses. */
function isMoney(v: unknown): v is MoneyShape {
	if (typeof v !== 'object' || v === null || Array.isArray(v)) return false;
	const { value, currency } = v as Record<string, unknown>;
	return (
		typeof value === 'string' &&
		value.length > 0 &&
		typeof currency === 'string' &&
		currency.length > 0
	);
}

/** Walks a dotted path from the data root; a miss resolves to `undefined`. */
function lookup(data: Record<string, unknown>, path: string): unknown {
	let cur: unknown = data;
	for (const part of path.split('.')) {
		if (cur == null || typeof cur !== 'object' || Array.isArray(cur)) return undefined;
		cur = (cur as Record<string, unknown>)[part];
	}
	return cur;
}

/**
 * Render `template` against `data`. Unknown placeholders and Jinja syntax
 * outside the supported subset pass through verbatim.
 */
export function renderTemplate(template: string, data: Record<string, unknown>): string {
	return template.replace(TOKEN_RE, (_, path: string) => {
		// The reserved `content` root walks the raw tree, mirroring the
		// backend's reserved variable.
		const resolved = path.startsWith('content.')
			? lookup(data, path.slice('content.'.length))
			: lookup(data, path);
		return renderValue(resolved);
	});
}
