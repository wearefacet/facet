// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Setup-time role usability check for backend (confidential) apps.
 *
 * Pure port of the backend resolution engine — `src/rbac/grant_resolver.cr`
 * (`role_usable?` / `missing_required_actions`), `src/rbac/grant.cr`
 * (`Grant#covers?`, the `write` alias) and `src/rbac/permission.cr`
 * (`matches_action?`, the `except` carve-out). The two implementations must
 * agree: a role this module reports as usable is exactly a role the runtime
 * enforcer accepts, and every gap named here is one the runtime would 401
 * on.
 *
 * Row-level `scope` does not take part in the check — by design, the same
 * way the backend gate ignores it: the grant asks for action coverage, and
 * the app inherits the service account's row scope. An `except` carve-out
 * on a role line does take part: for a concrete grant target, a line whose
 * carve-out covers the target does not satisfy a required action.
 */

/** One action declaration inside a grant entry (`app.App.grants[].actions[]`). */
export type GrantActionInput = {
	/** `read`, `write`, `delete`, or a named action declared on the target doctype. */
	name: string;
	/** Required actions reject a role that lacks them. Absent reads as `false`. */
	required?: boolean;
};

/** One grant entry (`app.App.grants[]`). */
export type GrantInput = {
	/** `domain.Doctype` or `domain.*`. The global `*.*` form is not a valid target. */
	target: string;
	actions: GrantActionInput[];
};

/** One permission line (`iam.Roles` content `permissions[]`). */
export type RolePermissionInput = {
	/** `create`, `update`, `delete`, `read`, `*`, or a named action. */
	action: string;
	/** `domain.Doctype`, a descendant path, `domain.*`, or `*.*`. */
	on: string;
	/** Concrete `domain.Doctype` paths carved out of the line's reach. */
	except?: string[];
};

const WILDCARD = '*';

/** The grant-side alias `write` expands into these two role-side actions. */
const WRITE_EXPANSION = ['create', 'update'];

type ParsedPath = { domain: string; path: string[] };

type ParsedPermission = ParsedPath & { action: string; except: string[] };

type ParsedAction = { name: string; required: boolean };

/** Split `domain.Doctype[.Child…]` into its domain and doctype path. */
function parsePath(value: string): ParsedPath | null {
	const parts = value.split('.');
	if (parts.length < 2) return null;
	return { domain: parts[0], path: parts.slice(1) };
}

/**
 * Canonical grant actions: `write` expands into `create` + `update`, and a
 * name declared twice keeps its first `required` flag. Mirrors the backend
 * parse-time expansion in `Grant.from_json`.
 */
function expandActions(actions: GrantActionInput[]): ParsedAction[] {
	const out: ParsedAction[] = [];
	const seen = new Set<string>();
	for (const action of actions ?? []) {
		if (!action || typeof action.name !== 'string') continue;
		const names = action.name === 'write' ? WRITE_EXPANSION : [action.name];
		for (const name of names) {
			if (seen.has(name)) continue;
			seen.add(name);
			out.push({ name, required: action.required === true });
		}
	}
	return out;
}

function matchesAction(permissionAction: string, targetAction: string): boolean {
	return permissionAction === WILDCARD || permissionAction === targetAction;
}

/**
 * True when the grant covers the permission's `(domain, path)`.
 *
 * - A `domain.*` grant covers every doctype in the domain.
 * - A `domain.Doctype` grant covers a permission on that doctype or on a
 *   descendant path.
 * - A permission with the wildcard domain `*` (`*.*`) matches every grant
 *   target; a permission with the wildcard doctype leaf matches any grant
 *   path in its domain.
 */
function grantCovers(grant: ParsedPath, permission: ParsedPath): boolean {
	if (grant.domain !== permission.domain && permission.domain !== WILDCARD) return false;
	if (grant.path.length === 1 && grant.path[0] === WILDCARD) return true;
	if (permission.path.length === 1 && permission.path[0] === WILDCARD) return true;
	return (
		grant.path.length <= permission.path.length &&
		grant.path.every((segment, i) => segment === permission.path[i])
	);
}

function parsePermissionLine(line: RolePermissionInput): ParsedPermission | null {
	if (!line || typeof line.action !== 'string' || typeof line.on !== 'string') return null;
	const parsed = parsePath(line.on);
	if (!parsed) return null;
	const except = Array.isArray(line.except)
		? line.except.filter((e): e is string => typeof e === 'string')
		: [];
	return { ...parsed, action: line.action, except };
}

/**
 * True when an `except` entry prefix-covers the grant target — the same
 * rule enforcement applies (`Permission#matches_except?`): an entry on
 * `core.DocType` also carves `core.DocType.Comment`.
 */
function exceptCoversTarget(entry: string, grant: ParsedPath): boolean {
	const parsed = parsePath(entry);
	if (!parsed) return false;
	return (
		parsed.domain === grant.domain &&
		parsed.path.length <= grant.path.length &&
		parsed.path.every((segment, i) => segment === grant.path[i])
	);
}

/**
 * A line whose `except` carve-out covers a concrete grant target does not
 * reach it — enforcement refuses the path outright, so the gate refuses it
 * too. A wildcard grant target (`domain.*`) keeps the lenient reading: the
 * line qualifies when at least one doctype in the domain survives. (The
 * authoring gate refuses wildcard targets on app grants; this port stays
 * tolerant of content that reaches it without the gate.)
 */
function lineReachesTarget(permission: ParsedPermission, grant: ParsedPath): boolean {
	if (grant.path.length === 1 && grant.path[0] === WILDCARD) return true;
	return permission.except.every((entry) => !exceptCoversTarget(entry, grant));
}

/**
 * The required grant actions the role does not cover, one entry per required
 * action per grant target, in declaration order — e.g. `["update on
 * fin.Invoice"]`. Optional actions never appear. An empty result means the
 * role satisfies every required action.
 */
export function missingRequiredActions(
	grants: GrantInput[],
	rolePermissions: RolePermissionInput[]
): string[] {
	const permissions = (rolePermissions ?? [])
		.map((line) => parsePermissionLine(line))
		.filter((p) => p !== null);

	const missing: string[] = [];
	for (const grant of grants ?? []) {
		if (!grant || typeof grant.target !== 'string') continue;
		const target = parsePath(grant.target);
		// Grants are validated upstream; a malformed target cannot be checked.
		if (!target) continue;
		for (const action of expandActions(grant.actions ?? [])) {
			if (!action.required) continue;
			const label = `${action.name} on ${grant.target}`;
			if (missing.includes(label)) continue;
			const covered = permissions.some(
				(p) =>
					grantCovers(target, p) &&
					matchesAction(p.action, action.name) &&
					lineReachesTarget(p, target)
			);
			if (!covered) missing.push(label);
		}
	}
	return missing;
}

/**
 * True when the role covers every required action across every grant entry —
 * the exact gate the runtime applies before a backend app's key is usable.
 */
export function roleUsable(grants: GrantInput[], rolePermissions: RolePermissionInput[]): boolean {
	return missingRequiredActions(grants, rolePermissions).length === 0;
}

/**
 * Extracts the permission lines from a loaded `iam.Roles` document content.
 * Lines without a string `action` and `on` are dropped — a line the module
 * cannot parse must not count as coverage.
 */
export function rolePermissionsFromContent(content: unknown): RolePermissionInput[] {
	if (!content || typeof content !== 'object') return [];
	const raw = (content as { permissions?: unknown }).permissions;
	if (!Array.isArray(raw)) return [];
	return raw.filter(
		(line): line is RolePermissionInput =>
			!!line &&
			typeof line === 'object' &&
			typeof (line as RolePermissionInput).action === 'string' &&
			typeof (line as RolePermissionInput).on === 'string'
	);
}
