// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Pure model helpers for the RBAC editor.
//
// These functions translate between the wire format (an array of
// permission objects on an `iam.Roles` document) and the per-doctype-row
// UI state used by the editor. They have no Svelte / DOM dependencies
// and are unit-tested in `rbacModel.spec.ts`.
//
// See `doc/backend/rbac.md` for the permission grammar and scope semantics.

import { humanizeRoleName } from '$lib/authorization/roleMembership.js';

// ── Wire format ───────────────────────────────────────────────────────────

/**
 * A single scope alias as referenced on a permission.
 *
 * Per the backend grammar (`RBAC::Permission`), `scope` is an array of alias
 * strings — each entry is either `$all` (explicit unrestricted — collapses
 * the whole permission to unrestricted) or `$<named_scope>` (a named scope
 * declared on the leaf doctype). The legacy single-string form is accepted
 * on parse but normalised to a one-element array internally. Roles cannot
 * author custom predicates; they only reference named scopes already
 * declared on the target doctype. When multiple aliases are present, they
 * combine with OR at enforcement time.
 */
export type ScopeValue = string;

/** One permission line as stored on `iam.Roles.permissions[]`. */
export interface PermissionRaw {
	action: string;
	on: string;
	/** Array of alias strings; omitted when the permission is unrestricted. */
	scope?: ScopeValue[];
	/**
	 * Concrete `domain.Doctype` paths carved out of the line's reach. Omitted
	 * when the line carries none. The editor has no control for this field —
	 * `loadState` keeps it and `serializeState` emits it unchanged, so an
	 * existing carve-out survives a save (B-350).
	 */
	except?: string[];
}

/** An `iam.Roles` document's content. */
export interface RoleContent {
	name: string;
	description?: string;
	visible_tags?: string[];
	/** Programmatic channels the role may open (mcp / webhook / api / assistant). */
	connectivity?: string[];
	/** Assistant token cap per account over a rolling 30-day window; null = unlimited. */
	assistant_token_budget?: number | null;
	permissions: PermissionRaw[];
}

// ── Doctype registry ─────────────────────────────────────────────────────

/**
 * Minimal view of a doctype definition.
 *
 * Mirrors the `definition.yml` / `core.DocType` shape — we pick only the
 * fields the editor reads. The `MockDataDriver.doctypeDefinitions` map
 * yields `Record<string, unknown>`; use {@link asDoctypeDef} to validate.
 */
export interface DoctypeDef {
	domain: string;
	doctype: string;
	/** Human-readable doctype description (from the definition's top-level `description`). */
	description?: string;
	aggregate_root?: boolean;
	member_of?: string;
	children?: Record<string, { doctype: string; collection?: boolean }>;
	fields?: Record<
		string,
		{ type: string; title?: string; description?: string; operators?: string[] }
	>;
	/**
	 * Named scopes declared on this doctype (`definition.content.scopes`).
	 * Each entry is keyed by its alias (without the leading `$`) and
	 * carries a human-readable description. The editor surfaces these as
	 * the per-action "custom_scope" picker entries.
	 */
	scopes?: Record<string, { description?: string; where?: Record<string, string> }>;
	/**
	 * Custom (named) actions declared on this doctype, e.g. `move_stage`,
	 * `win`, `lose`. The backend's permission grammar is `{action, on, scope}`
	 * where `action` is one of `read/create/update/delete`, `*`, or a named
	 * action declared here. Roles may reference these by their literal
	 * name; the editor renders one picker per declared action.
	 */
	actions?: Record<string, { description?: string; args?: Record<string, unknown> }>;
}

/** Coerce a raw definition record into a {@link DoctypeDef}, ignoring unknown keys. */
export function asDoctypeDef(raw: Record<string, unknown>): DoctypeDef {
	return {
		domain: String(raw.domain ?? ''),
		doctype: String(raw.doctype ?? ''),
		description: typeof raw.description === 'string' ? raw.description : undefined,
		aggregate_root: raw.aggregate_root === true ? true : undefined,
		member_of: typeof raw.member_of === 'string' ? raw.member_of : undefined,
		children: raw.children as DoctypeDef['children'],
		fields: raw.fields as DoctypeDef['fields'],
		scopes: raw.scopes as DoctypeDef['scopes'],
		actions: raw.actions as DoctypeDef['actions']
	};
}

// ── Tree model ──────────────────────────────────────────────────────────

/** A node in the doctype tree, scoped to a single domain. */
export interface DoctypeNode {
	/** Fully-qualified doctype, e.g. `production.Project`. */
	qualified: string;
	domain: string;
	doctype: string;
	/** Doctype path within the domain, e.g. `['Project', 'Task']`. */
	path: string[];
	/** Depth in the tree (root = 0). */
	depth: number;
	/** Direct children, recursively. */
	children: DoctypeNode[];
	/** Definition for this doctype (fields reference). */
	def: DoctypeDef;
}

/** A domain subtree. */
export interface DomainTree {
	domain: string;
	color?: string;
	description?: string;
	roots: DoctypeNode[];
}

/**
 * Build the doctype tree from the global registry.
 *
 * The registry is the `doctypeDefinitions` map on `MockDataDriver`,
 * keyed by `{domain}.{doctype}`. Both spellings of composition are
 * honoured — children declared on the parent (`children:`) and
 * membership declared by the child (`member_of:`).
 *
 * Roots are doctypes whose `aggregate_root === true` or which have
 * no `member_of` but have children (covers edge cases where
 * `aggregate_root` was omitted).
 */
export function buildTree(registry: Map<string, Record<string, unknown>>): DomainTree[] {
	// Partition by domain.
	const byDomain = new Map<string, Map<string, DoctypeDef>>();
	for (const [qualified, raw] of registry.entries()) {
		const def = asDoctypeDef(raw);
		if (!def.domain || !def.doctype) continue;
		if (qualified !== `${def.domain}.${def.doctype}`) continue;
		let bucket = byDomain.get(def.domain);
		if (!bucket) {
			bucket = new Map();
			byDomain.set(def.domain, bucket);
		}
		bucket.set(def.doctype, def);
	}

	const domains: DomainTree[] = [];
	for (const [domain, doctypes] of byDomain.entries()) {
		const roots: DoctypeNode[] = [];
		// Track which doctypes are reachable as children to detect roots.
		const reachableAsChild = new Set<string>();

		// Walk once to collect children reachability via member_of.
		for (const def of doctypes.values()) {
			if (def.member_of) reachableAsChild.add(def.doctype);
		}

		// Roots: aggregate_root or has-no-member_of-but-has-children.
		const rootNames: string[] = [];
		for (const [name, def] of doctypes.entries()) {
			const isRootByAgg = def.aggregate_root === true;
			const isRootByChildren =
				!def.member_of && def.children && Object.keys(def.children).length > 0;
			const isRootByOrphan = !def.member_of && !reachableAsChild.has(name);
			if (isRootByAgg || isRootByChildren || isRootByOrphan) {
				rootNames.push(name);
			}
		}

		for (const name of rootNames.sort()) {
			roots.push(buildNode(doctypes, name, [name], 0));
		}

		domains.push({
			domain,
			roots
		});
	}

	// Stable domain ordering — alphabetical, but `core`, `iam` first
	// (matches how they are seeded and how they are typically browsed).
	domains.sort((a, b) => {
		const order = (d: string) => (d === 'core' ? 0 : d === 'iam' ? 1 : 2);
		const oa = order(a.domain);
		const ob = order(b.domain);
		if (oa !== ob) return oa - ob;
		return a.domain.localeCompare(b.domain);
	});

	return domains;
}

/** Recursively build a doctype node, guarding against cycles. */
function buildNode(
	doctypes: Map<string, DoctypeDef>,
	name: string,
	path: string[],
	depth: number,
	visited: Set<string> = new Set()
): DoctypeNode {
	const def = doctypes.get(name);
	const domain = def?.domain ?? '';
	// `qualified` mirrors the wire-format `on` field: `{domain}.{LeafDoctype}`.
	// The backend matches by prefix over the *registered* doctype path, but
	// the persisted key is always domain-prefixed leaf name — never the full
	// tree path. So `production.Project.Task` is stored as `production.Task`.
	const qualified = [domain, name].join('.');
	const node: DoctypeNode = {
		qualified,
		domain,
		doctype: name,
		path,
		depth,
		children: [],
		def: def ?? { domain, doctype: name }
	};

	if (!def || visited.has(name)) return node;
	visited.add(name);

	// Children from the parent's `children:` declaration.
	const childNames = new Set<string>();
	if (def.children) {
		for (const childDef of Object.values(def.children)) {
			childNames.add(childDef.doctype);
		}
	}
	// Children declared via `member_of` on another doctype (reverse lookup).
	for (const [otherName, otherDef] of doctypes.entries()) {
		if (otherDef.member_of === name) childNames.add(otherName);
	}

	for (const childName of [...childNames].sort()) {
		node.children.push(
			buildNode(doctypes, childName, [...path, childName], depth + 1, new Set(visited))
		);
	}

	return node;
}

// ── UI state ────────────────────────────────────────────────────────────

/**
 * Per-doctype action state in the editor.
 *
 * Each action carries an array of scope aliases on the permission line:
 * - `[]`                       → **None** (no permission line emitted)
 * - `['$all']`                  → **All** (emitted with no `scope` field — explicit unrestricted)
 * - `['$<named_scope>', ...]`   → **custom_scope set** (emitted with `scope`
 *   set to the array; aliases must be declared on the leaf doctype; the
 *   permission matches rows satisfying any (OR) of the listed scopes)
 *
 * The empty array is reserved for "None" (no permission). Loading a wire
 * permission with an absent or `$all` scope yields `['$all']`, never `[]`.
 */
export interface DoctypeActionState {
	read: ScopeValue[];
	create: ScopeValue[];
	update: ScopeValue[];
	delete: ScopeValue[];
	/**
	 * Custom (named) action scopes keyed by their action name, e.g.
	 * `move_stage: ['$mine']`. The canonical four are part of the named slots
	 * above; this index also holds the reserved {@link EXCEPT_PREFIX} keys,
	 * which keep a line's `except` carve-out paths (never rendered; re-emitted
	 * on serialize).
	 */
	[key: string]: ScopeValue[];
}

/**
 * The editor's editable state: a map from qualified path → action state.
 *
 * Keys are the `on` path strings (`production.Project`,
 * `production.Project.Task`). Root doctypes are keyed by the
 * fully-qualified name `{domain}.{Doctype}`.
 */
export type EditorState = Record<string, DoctypeActionState>;

/** Sentinel value for the explicit unrestricted scope (`$all`). */
export const ALL_SCOPE = '$all';

/** Empty-string sentinel for "None" — the action is not granted. */
export const NONE_SCOPE = '';

/**
 * Reserved key prefix under which a row keeps the `except` carve-outs of its
 * permission lines, one entry per action (`$except:read` → path array). A
 * real action name cannot start with `$`, so no key collision can occur.
 * `serializeState` emits these arrays again on the matching line. The scope
 * pickers never read or write them.
 */
const EXCEPT_PREFIX = '$except:';

/** The reserved `DoctypeActionState` key that keeps `action`'s carve-outs. */
function exceptKeyFor(action: string): string {
	return `${EXCEPT_PREFIX}${action}`;
}

/** The four canonical CRUD actions, in display order. */
export const CORE_ACTIONS = ['read', 'create', 'update', 'delete'] as const;

/**
 * Route-gated named actions — actions that gate a Crystal HTTP route but are
 * deliberately not declared on the doctype's `actions:` map. A declared
 * action must export a Lua function of the same name
 * (`src/doctype/script_validator.cr`) and becomes callable as a document
 * action; these gate fixed routes instead (e.g. `POST /Api/iam/mfa/disable`),
 * so a doctype definition cannot carry them.
 *
 * Keyed by qualified doctype. The backend stays the enforcement authority —
 * this table only tells the editor which extra per-action pickers to render.
 * Extend it when a new route-gated action is introduced (see
 * `doc/backend/rbac.md` → Named-action conventions).
 */
export const ROUTE_GATED_ACTIONS: Record<string, Record<string, { description?: string }>> = {
	'iam.Account': {
		provision_credentials: {
			description: 'Mint temporary passwords, send invite links and read credential states.'
		},
		mfa_disable: {
			description: "Disable an account's multi-factor authentication (admin recovery)."
		}
	}
};

/** The wire `on` key for a doctype definition, e.g. `iam.Account`. */
function qualifiedKey(def: Pick<DoctypeDef, 'domain' | 'doctype'>): string {
	return `${def.domain}.${def.doctype}`;
}

/**
 * Ordered list of action names the editor renders as pickers for a doctype.
 *
 * Always returns the four canonical CRUD actions first (in that order),
 * followed by the doctype's grantable named actions (sorted alphabetically):
 * custom actions declared under `def.actions:` and route-gated actions from
 * {@link ROUTE_GATED_ACTIONS}. Both kinds are real permissions in the role's
 * wire format. Declared actions are surfaced even when they declare no
 * `args` — they are still grantable permissions in the role's wire format.
 */
export function actionsFor(def: DoctypeDef): string[] {
	const declared = def.actions ? Object.keys(def.actions) : [];
	const gated = Object.keys(ROUTE_GATED_ACTIONS[qualifiedKey(def)] ?? {});
	const custom = [...new Set([...declared, ...gated])].sort();
	return [...CORE_ACTIONS, ...custom];
}

/**
 * Human-readable description for a named action — from the declared
 * `actions:` entry or the route-gated table. `undefined` for the canonical
 * CRUD actions and for named actions without a description, so callers can
 * render the hint unconditionally.
 */
export function actionDescription(def: DoctypeDef, action: string): string | undefined {
	const declared = def.actions?.[action]?.description;
	if (declared) return declared;
	return ROUTE_GATED_ACTIONS[qualifiedKey(def)]?.[action]?.description;
}

function isAction(value: unknown): value is string {
	return typeof value === 'string' && value.length > 0;
}

/** Build a fresh per-doctype row with every action set to "None" (empty array). */
export function emptyRow(): DoctypeActionState {
	return { read: [], create: [], update: [], delete: [] };
}

/**
 * Normalise a raw scope value from a wire permission into the editor's
 * array model.
 *
 * - `undefined` (no `scope` field on the wire) → `['$all']` (unrestricted)
 * - `'$all'` (legacy single-string sentinel)       → `['$all']`
 * - `'$mine'` (legacy single-string alias)          → `['$mine']`
 * - `['$mine', '$global']` (array form)              → unchanged, unless it
 *   contains `'$all'` (collapses to `['$all']`)
 */
function normalizeScope(raw: ScopeValue | ScopeValue[] | undefined): ScopeValue[] {
	if (raw === undefined || raw === null) return [ALL_SCOPE];
	if (Array.isArray(raw)) {
		return raw.some((v) => v === ALL_SCOPE) ? [ALL_SCOPE] : raw;
	}
	return raw === ALL_SCOPE ? [ALL_SCOPE] : [raw];
}

/**
 * Load editor state from a role's `permissions[]`.
 *
 * Each permission line writes its scope array into the matching path entry.
 * Action names are stored verbatim — the canonical CRUD actions populate
 * their named slots, custom actions land under the string index on
 * {@link DoctypeActionState}. A line's `except` carve-outs are kept per
 * action under the reserved {@link EXCEPT_PREFIX} keys, so `serializeState`
 * can emit them again verbatim (B-350: the editor cannot author carve-outs,
 * but it must not strip the ones a role already carries).
 *
 * The legacy multiple-permission-per-action wire form (kept for backward
 * compatibility) is merged: scope arrays union with OR semantics, and the
 * `except` lists fold to their intersection — a target stays excepted only
 * when every same-action line subtracts it. This mirrors the backend's own
 * per-action fold (`IAM::Helpers.build_permission_manifest`).
 *
 * Wildcard `*.*` lines load like any other line. No tree row matches the
 * `*.*` key, so they render nowhere, but they stay in the state and a save
 * emits them again. This keeps the seeded roles' wildcard grants and their
 * carve-outs alive through an edit (B-350).
 */
export function loadState(role: RoleContent | undefined): EditorState {
	const state: EditorState = {};
	if (!role?.permissions) return state;

	for (const perm of role.permissions) {
		const existing = state[perm.on] ?? emptyRow();
		if (isAction(perm.action)) {
			const incoming = normalizeScope(perm.scope);
			const prior = existing[perm.action] ?? [];
			// Merge by union — preserves every alias the role author attached.
			existing[perm.action] = unionScopes(prior, incoming);
			// Keep the line's `except` carve-outs under the reserved key so a
			// save emits them again (B-350).
			const key = exceptKeyFor(perm.action);
			const folded = foldExcept(existing[key], normalizeExcept(perm.except));
			if (folded.length > 0) existing[key] = folded;
			else delete existing[key];
		}
		state[perm.on] = existing;
	}
	return state;
}

/**
 * Union two scope arrays, dropping duplicates while preserving order.
 * `'$all'` wins (returns `['$all']`) — any unrestricted permission makes
 * the whole action unrestricted (matches the backend's "any unrestricted
 * in the matching set ⇒ All" rule).
 */
function unionScopes(a: ScopeValue[], b: ScopeValue[]): ScopeValue[] {
	if (a.includes(ALL_SCOPE) || b.includes(ALL_SCOPE)) return [ALL_SCOPE];
	const out: ScopeValue[] = [];
	for (const v of [...a, ...b]) {
		if (!out.includes(v)) out.push(v);
	}
	return out;
}

/**
 * Normalise a raw `except` value from a wire permission into a path array.
 * The wire form is an array of strings (`RBAC::Permission.parse_except`
 * raises on anything else); a non-array here means the field is absent.
 */
function normalizeExcept(raw: unknown): string[] {
	if (!Array.isArray(raw)) return [];
	return raw.filter((v): v is string => typeof v === 'string' && v.length > 0);
}

/**
 * Fold one line's `except` list into the per-action fold of its path.
 *
 * Backend grants OR their lines, so a target is truly excepted only when
 * every same-action line on the path subtracts it — the fold is the
 * intersection, the same rule the backend applies per action
 * (`IAM::Helpers.build_permission_manifest`). A line without carve-outs
 * gives an empty list and clears the fold. `undefined` means no line was
 * folded yet; the first list then passes through.
 */
function foldExcept(prior: ScopeValue[] | undefined, incoming: string[]): ScopeValue[] {
	if (prior === undefined) return incoming;
	return prior.filter((p) => incoming.includes(p));
}

/**
 * Serialise editor state back into `permissions[]`.
 *
 * "None" actions emit nothing. "All" actions emit a permission with no
 * `scope` key (matching the wire format — `$all` is the explicit
 * unrestricted sentinel but we omit for compactness). One or more
 * "custom_scope" actions emit a permission carrying the alias array
 * verbatim (multi-alias OR semantics).
 *
 * Permissions are emitted in stable order: by path, then by action. Within
 * a path, the four canonical CRUD actions emit first (in their fixed
 * order), then any custom actions in alphabetical order.
 *
 * Wildcard lines (`on: '*.*'`) are never authored here, but lines the role
 * already carries load under the `*.*` key and emit again verbatim — with
 * their `except` carve-outs. The wildcard `*` action round-trips the same
 * way as a custom action; the editor offers no control for either.
 */
export function serializeState(state: EditorState): PermissionRaw[] {
	const perms: PermissionRaw[] = [];
	const paths = Object.keys(state).sort();
	for (const on of paths) {
		const row = state[on];
		// Canonical CRUD actions first, in fixed order.
		for (const action of CORE_ACTIONS) {
			appendPermission(perms, on, action, row[action] ?? [], row[exceptKeyFor(action)]);
		}
		// Then declared custom actions, alphabetically. Skip the four canonical
		// ones and the reserved `$except:` keys folded above.
		const customs = Object.keys(row)
			.filter(
				(a) =>
					!a.startsWith(EXCEPT_PREFIX) && !CORE_ACTIONS.includes(a as (typeof CORE_ACTIONS)[number])
			)
			.sort();
		for (const action of customs) {
			appendPermission(perms, on, action, row[action] ?? [], row[exceptKeyFor(action)]);
		}
	}
	return perms;
}

function appendPermission(
	perms: PermissionRaw[],
	on: string,
	action: string,
	scope: ScopeValue[],
	except?: ScopeValue[]
): void {
	if (scope.length === 0) return;
	const perm: PermissionRaw = { action, on };
	if (!scope.includes(ALL_SCOPE)) {
		// Non-empty array of named scopes — emit as the canonical multi-alias
		// permission (OR semantics at enforcement time).
		perm.scope = scope;
	}
	if (except && except.length > 0) {
		// Carve-outs pass through verbatim — the editor cannot author them.
		perm.except = except;
	}
	perms.push(perm);
}

/**
 * List the named scopes declared on a doctype, as picker options.
 *
 * Returns `[{value: '$<alias>', label: '$alias — description'}]` for each
 * entry under `def.scopes`. The list may be empty — many doctypes declare
 * no named scopes, in which case the per-action picker offers only
 * None / All.
 */
export function scopeOptionsFor(def: DoctypeDef): { value: string; label: string }[] {
	const out: { value: string; label: string }[] = [];
	if (!def.scopes) return out;
	for (const [alias, scope] of Object.entries(def.scopes)) {
		const desc = scope?.description?.trim();
		out.push({
			value: `$${alias}`,
			label: desc ? `$${alias} — ${desc}` : `$${alias}`
		});
	}
	return out.sort((a, b) => a.value.localeCompare(b.value));
}

/**
 * Build the role-picker options from `iam.Roles` documents.
 *
 * The `value` stays the raw role `name` (it is the picker's identity and is
 * stored/compared as-is); the `label` is humanized for display.
 */
export function roleOptions(
	roles: { data: { name?: string; description?: string } }[]
): { value: string; label: string }[] {
	return roles
		.map((r) => ({
			value: r.data.name ?? '',
			label: r.data.name ? humanizeRoleName(r.data.name) : ''
		}))
		.filter((r) => r.value !== '')
		.sort((a, b) => a.label.localeCompare(b.label));
}

/**
 * Convenience: does a node have any in-tree descendants useful as a
 * cascade hint in the UI? (renders "covers N child type(s)" pill).
 */
export function descendantCount(node: DoctypeNode): number {
	let n = 0;
	for (const child of node.children) {
		n += 1 + descendantCount(child);
	}
	return n;
}

// ── Default-expanded paths ──────────────────────────────────────────────

/**
 * Default-expanded keys for the doctype tree accordion.
 *
 * The editor loads with everything collapsed except the smallest subtree
 * that exposes every doctype the currently-loaded role touches — so with
 * 500+ doctype definitions the user is shown only what's relevant to the
 * role, and can drill into the rest on demand.
 *
 * For each entry in `state`, the entry's own key is expanded (so its row
 * is visible) and every ancestor up to the root is expanded (so the row
 * is reachable). Domains whose touched doctypes are visible stay
 * collapsed themselves; the {@link DomainTree} consumers are responsible
 * for expanding the matching domain containers separately.
 */
export function deriveExpandedKeys(domains: DomainTree[], state: EditorState): Set<string> {
	const touched = new Set(Object.keys(state));
	if (touched.size === 0) return new Set();

	const out = new Set<string>();

	function walk(node: DoctypeNode, ancestorChain: string[]): boolean {
		const chain = [...ancestorChain, node.qualified];
		let anyTouched = touched.has(node.qualified);
		for (const child of node.children) {
			if (walk(child, chain)) anyTouched = true;
		}
		if (anyTouched) {
			// Expand this node (so its touched descendants render) and every
			// ancestor in the chain. Root nodes are themselves expanded if
			// they or any descendant is touched.
			for (const key of chain) out.add(key);
		}
		return anyTouched;
	}

	for (const domain of domains) {
		for (const root of domain.roots) {
			walk(root, []);
		}
	}

	return out;
}

// ── Search filtering ────────────────────────────────────────────────────

/**
 * Test whether a doctype node matches a query.
 *
 * A node matches if the domain, doctype, or qualified path contains the
 * (case-insensitive) query substring.
 */
function nodeMatches(node: DoctypeNode, q: string): boolean {
	if (!q) return true;
	const needle = q.toLowerCase();
	if (node.domain.toLowerCase().includes(needle)) return true;
	if (node.doctype.toLowerCase().includes(needle)) return true;
	if (node.qualified.toLowerCase().includes(needle)) return true;
	// Also match against the leaf-only doctype name (last path segment).
	const leafName = node.path[node.path.length - 1] ?? node.doctype;
	return leafName.toLowerCase().includes(needle);
}

/**
 * Recursively filter a doctype subtree.
 *
 * Inclusion rules (per the editor spec):
 * - A matching node is kept **with all its descendants** intact.
 * - A non-matching node is kept only if any of its descendants matches
 *   (the ancestor acts as scaffolding so the matching descendant renders
 *   in hierarchy). Non-matching leaf nodes are pruned.
 *
 * Returns `undefined` when the subtree has no matching descendant and
 * its root itself doesn't match — used by {@link filterTree} to drop
 * whole branches.
 */
function filterNode(node: DoctypeNode, q: string): DoctypeNode | undefined {
	const selfMatches = nodeMatches(node, q);
	const filteredChildren: DoctypeNode[] = [];
	for (const child of node.children) {
		const filtered = filterNode(child, q);
		if (filtered) filteredChildren.push(filtered);
	}
	if (!selfMatches && filteredChildren.length === 0) return undefined;
	// Keep the original children references when self matches — the user
	// explicitly searched for this node, so its full subtree stays visible.
	const children = selfMatches ? node.children : filteredChildren;
	return { ...node, children };
}

/**
 * Filter the global doctype tree by a search query.
 *
 * A domain is shown when its name matches the query OR any of its
 * doctypes matches. When the query is empty, the input tree is returned
 * unchanged (no copy).
 *
 * Matching doctype subtrees keep their full descendant chain (so
 * searching `Document` shows `Document` plus every child type). Nested
 * non-matching ancestors are kept as scaffolding only when they have a
 * matching descendant somewhere below.
 */
export function filterTree(domains: DomainTree[], query: string): DomainTree[] {
	const q = query.trim();
	if (!q) return domains;
	const out: DomainTree[] = [];
	for (const domain of domains) {
		const domainNameMatches = domain.domain.toLowerCase().includes(q.toLowerCase());
		const filteredRoots: DoctypeNode[] = [];
		for (const root of domain.roots) {
			const filtered = filterNode(root, q);
			if (filtered) filteredRoots.push(filtered);
		}
		if (domainNameMatches && filteredRoots.length === 0) {
			// Domain name matched but no doctype survived the filter —
			// still show the domain with its full root set so the match
			// target is visible.
			out.push({ ...domain, roots: domain.roots });
		} else if (filteredRoots.length > 0) {
			out.push({ ...domain, roots: filteredRoots });
		}
	}
	return out;
}
