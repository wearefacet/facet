// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Parses a doctype Lua script and returns the functions exported on the
 * module's export table — i.e. the callable hooks the script actually
 * defines.
 *
 * The module pattern is documented in `doc/backend/lua-engine.md`:
 *
 * ```lua
 * local export = {}
 * function export.create(ctx) ... end
 * function export.deal_weighted_value(ctx) ... end
 * return export
 * ```
 *
 * Only symbols that exist in the returned table are listed. We do NOT invent
 * symbols from the doctype definition (computed-field names, action keys, or
 * lifecycle hooks) — the panel is a reflection of the script, not a helper for
 * adding methods. The {@link ExportedFn.kind} field merely *labels* each
 * exported name by matching it back against the doctype definition.
 */

import luaparse from 'luaparse';
import type { DoctypeDef } from './types.js';

export type ExportedKind = 'compute' | 'action' | 'lifecycle' | 'function';

export interface ExportedFn {
	name: string;
	kind: ExportedKind;
	/** Human-readable binding (e.g. the field key a compute fn targets). */
	bound?: string;
}

const LIFECYCLE_HOOKS = new Set(['create', 'update', 'delete']);
const COMPUTE_PREFIX = 'compute_';

/**
 * Extract the names of functions exported on the module's returned table.
 *
 * Returns an empty array when the script is empty, does not parse, does not
 * follow the module pattern, or exports no functions.
 */
export function parseExportedSymbols(script: string, def: DoctypeDef | undefined): ExportedFn[] {
	const trimmed = script?.trim();
	if (!trimmed) return [];

	let ast;
	try {
		ast = luaparse.parse(trimmed, { luaVersion: '5.3' });
	} catch {
		// Syntax errors are surfaced by the backend ScriptValidator at
		// registration time; here we just have nothing to show.
		return [];
	}

	const body = (ast.body ?? []) as unknown as Record<string, unknown>[];

	// The exported table is whatever identifier the final `return <id>`
	// statement yields. Defaults to the documented `export` name.
	const exportName = resolveExportName(body);

	const names = new Set<string>();
	for (const stmt of body) {
		collectFromStatement(stmt, exportName, names);
	}

	if (names.size === 0) return [];

	return [...names].sort((a, b) => a.localeCompare(b)).map((name) => classify(name, def));
}

// ── Internals ───────────────────────────────────────────────────────────────

function resolveExportName(body: Record<string, unknown>[]): string {
	// Walk backwards: the trailing `return export` is conventionally last.
	for (let i = body.length - 1; i >= 0; i--) {
		const stmt = body[i];
		if (stmt['type'] !== 'ReturnStatement') continue;
		const arg = (stmt['arguments'] as Record<string, unknown>[] | undefined)?.[0];
		if (arg && arg['type'] === 'Identifier' && typeof arg['name'] === 'string') {
			return arg['name'];
		}
		break;
	}
	return 'export';
}

function collectFromStatement(
	stmt: Record<string, unknown>,
	exportName: string,
	out: Set<string>
): void {
	// `function export.NAME(...)` — a named function declaration on the
	// export table.
	if (stmt['type'] === 'FunctionDeclaration') {
		const id = stmt['identifier'] as Record<string, unknown> | undefined;
		const name = memberName(id, exportName);
		if (name) out.add(name);
		return;
	}

	// `export.NAME = function(...)` / `export["NAME"] = function(...)`
	if (stmt['type'] === 'AssignmentStatement') {
		const vars = stmt['variables'] as Record<string, unknown>[] | undefined;
		const init = (stmt['init'] as Record<string, unknown>[] | undefined)?.[0];
		const variable = vars?.[0];
		if (!variable || !init) return;
		// Only consider assignments whose value is a function. Non-function
		// exports (constants, table aliases) are not callable hooks.
		if (!isFunctionNode(init)) return;
		const name = accessName(variable, exportName);
		if (name) out.add(name);
		return;
	}
}

function isFunctionNode(node: Record<string, unknown>): boolean {
	// luaparse types both `function name()` declarations and anonymous
	// `function() end` expressions as `FunctionDeclaration`; the latter has
	// no `identifier`. Either way it's a callable.
	return node['type'] === 'FunctionDeclaration';
}

/**
 * Returns the property name when `node` is `export.NAME` or `export["NAME"]`
 * on the resolved export table, else `undefined`.
 */
function accessName(
	node: Record<string, unknown> | undefined,
	exportName: string
): string | undefined {
	if (!node) return undefined;

	if (node['type'] === 'MemberExpression') {
		const base = node['base'] as Record<string, unknown> | undefined;
		if (base?.['type'] !== 'Identifier' || base['name'] !== exportName) return undefined;
		if (node['indexer'] !== '.') return undefined;
		const id = node['identifier'] as Record<string, unknown> | undefined;
		return typeof id?.['name'] === 'string' ? (id['name'] as string) : undefined;
	}

	if (node['type'] === 'IndexExpression') {
		const base = node['base'] as Record<string, unknown> | undefined;
		if (base?.['type'] !== 'Identifier' || base['name'] !== exportName) return undefined;
		const idx = node['index'] as Record<string, unknown> | undefined;
		return stringLiteralValue(idx);
	}

	return undefined;
}

/** Backwards-compat alias for FunctionDeclaration's `identifier` field. */
function memberName(
	id: Record<string, unknown> | undefined,
	exportName: string
): string | undefined {
	return accessName(id, exportName);
}

function stringLiteralValue(node: Record<string, unknown> | undefined): string | undefined {
	if (!node || node['type'] !== 'StringLiteral') return undefined;
	// luaparse may leave `value` null for some strings; fall back to `raw`
	// (the source token including quotes) and strip the surrounding quotes.
	const value = node['value'];
	if (typeof value === 'string') return value;
	const raw = node['raw'];
	if (typeof raw === 'string' && raw.length >= 2) {
		return raw.slice(1, -1);
	}
	return undefined;
}

function classify(name: string, def: DoctypeDef | undefined): ExportedFn {
	if (def) {
		// compute_{suffix} matches a `type: data` field whose `compute` value
		// equals the suffix. The backend requires `compute_{compute_name}`.
		if (name.startsWith(COMPUTE_PREFIX)) {
			const suffix = name.slice(COMPUTE_PREFIX.length);
			const field = def.fields.find((f) => f.compute === suffix);
			if (field) {
				return { name, kind: 'compute', bound: field.key };
			}
		}
		// Action hooks: `export.{action_key}(ctx, args)`.
		if (def.actions.some((a) => a.key === name)) {
			return { name, kind: 'action' };
		}
	}
	if (LIFECYCLE_HOOKS.has(name)) {
		return { name, kind: 'lifecycle' };
	}
	return { name, kind: 'function' };
}
