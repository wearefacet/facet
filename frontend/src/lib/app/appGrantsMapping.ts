// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure helpers that translate between the plain-language access levels
 * shown in the grants picker UI and the raw `{actions: [{name, required}]}`
 * shape stored on an `app.App` document.
 *
 * The stored vocabulary is the backend's canonical one: `read`, `create`,
 * `update`, `delete` (`src/rbac/grant.cr`). `write` is an authoring-only
 * alias the backend expands to `{create, update}` at parse time, so the
 * picker writes the expanded pair directly — a saved grant reads back
 * identically, and grants authored outside the editor (API, MCP, external
 * builders) classify the same way.
 *
 * These functions are pure (no Svelte, no state) so they can be unit-tested
 * in the Vitest `server` project. The grants editor component imports them to
 * keep its mutation handlers thin.
 *
 * See `doc/frontend/app-configure.md` for the full mapping table.
 */

import type { AppGrant, AppGrantAction, DoctypeCatalogueEntry } from './appTypes';
import * as m from '$lib/paraglide/messages';

/**
 * The four plain-language access levels the segmented control exposes. They
 * map deterministically to a set of action names; the per-action `required`
 * flag is owned by the caller (it is policy, not access level).
 *
 * - `none`  — no grant entry for this doctype.
 * - `read`  — "Read": read only.
 * - `write` — "Create and edit": read + create + update. `write` is the
 *             display alias that stands for the canonical create/update
 *             pair, so a separate "add" level is not needed.
 * - `full`  — "Full access": read + write + delete.
 *
 * The levels are ordered `none < read < write < full`. This ordering is the
 * basis for the parent/child clamp: a child's level cannot exceed its parent's.
 */
export type PlainLevel = 'none' | 'read' | 'write' | 'full';

/**
 * The ordered levels excluding `none`, used for the clamp comparison and for
 * mapping a level to its action-name set.
 */
const ORDERED_LEVELS: Exclude<PlainLevel, 'none'>[] = ['read', 'write', 'full'];

/**
 * Index of each non-`none` level in {@link ORDERED_LEVELS}. Higher index
 * means broader access. `none` is treated as `-1` (narrower than every
 * non-`none` level).
 */
const LEVEL_RANK: Record<PlainLevel, number> = {
	none: -1,
	read: 0,
	write: 1,
	full: 2
};

/**
 * The segments shown in the segmented control, in display order. The first
 * entry is always `none` so the "No access" segment is leftmost. Labels come
 * from `levelLabel` at render time so they render through the catalogue.
 */
export const PLAIN_LEVEL_OPTIONS: { value: PlainLevel }[] = [
	{ value: 'none' },
	{ value: 'read' },
	{ value: 'write' },
	{ value: 'full' }
];

/** Catalogue label for a plain access level (segment buttons, child tags). */
export function levelLabel(level: PlainLevel): string {
	switch (level) {
		case 'none':
			return m.apps_grants_level_none();
		case 'read':
			return m.apps_grants_level_read();
		case 'write':
			return m.apps_grants_level_write();
		case 'full':
			return m.apps_grants_level_full();
	}
}

/**
 * The action names each non-`none` level writes, in the backend's canonical
 * vocabulary. `write` is never persisted: the backend would expand it to the
 * same pair (`src/rbac/grant.cr` → `Grant.expand_action`), so the picker
 * writes `create`/`update` directly and a saved grant reads back identically.
 */
const LEVEL_ACTIONS: Record<Exclude<PlainLevel, 'none'>, string[]> = {
	read: ['read'],
	write: ['read', 'create', 'update'],
	full: ['read', 'create', 'update', 'delete']
};

/**
 * The action names the required-flag row renders for a level, in display
 * order. `write` is the display alias that stands for the canonical
 * `{create, update}` pair — one pill, one flag (see {@link effectiveRequireds}).
 */
const LEVEL_DISPLAY_ACTIONS: Record<Exclude<PlainLevel, 'none'>, string[]> = {
	read: ['read'],
	write: ['read', 'write'],
	full: ['read', 'write', 'delete']
};

/**
 * Build the `actions[]` array for a grant from a plain level and the
 * per-action `required` flags the caller has chosen.
 *
 * `requireds` keys are the display action names — `read`, `write` (the alias
 * that stands for the `{create, update}` pair), `delete` — plus any named
 * action names; missing keys default to `false`. The write pair is emitted
 * canonically: both `create` and `update` carry the `write` flag, so the
 * stored shape matches what the backend resolver expands.
 *
 * `level = 'none'` returns an empty array — the caller removes the grant
 * entry entirely rather than persisting an empty one.
 */
export function levelToActions(
	level: PlainLevel,
	requireds: Record<string, boolean> = {}
): AppGrantAction[] {
	if (level === 'none') return [];
	return LEVEL_ACTIONS[level].map((name) => ({
		name,
		required: Boolean(requireds[requiredFlagKey(name)] ?? false)
	}));
}

/**
 * The display flag a canonical core action reads its `required` value from:
 * the `create`/`update` pair shares the single `write` pill.
 */
function requiredFlagKey(name: string): string {
	return name === 'create' || name === 'update' ? 'write' : name;
}

/**
 * The action names a plain level grants, in display order (read, write,
 * delete) — the names the required-flag row renders. `none` yields an empty
 * array. The level owns membership; the per-action `required` flag is the
 * caller's business.
 */
export function levelActionNames(level: PlainLevel): string[] {
	if (level === 'none') return [];
	return [...LEVEL_DISPLAY_ACTIONS[level]];
}

/**
 * The canonical core action names a grant can carry after the backend parse:
 * `read`, `create`, `update`, `delete` (`src/rbac/grant.cr`). Anything else
 * is a doctype-declared named action.
 */
const CORE_ACTION_NAMES: ReadonlySet<string> = new Set(['read', 'create', 'update', 'delete']);

/**
 * True for the core action names — the canonical four plus the `write`
 * alias, which grants saved by earlier editor builds can still carry. Drives
 * the editor's named-action filter: a core name or the alias must never leak
 * into the "Extra abilities" pills.
 */
export function isCoreActionName(name: string): boolean {
	return name === 'write' || CORE_ACTION_NAMES.has(name);
}

/**
 * Expand a stored `actions[]` into the backend's canonical form: the `write`
 * alias becomes separate `create` + `update` declarations, and a name
 * declared twice keeps its first `required` flag — the same rules
 * `Grant.from_json` applies at parse time (`src/rbac/grant.cr`). Grants
 * authored outside the editor (API, MCP, external builders) arrive in this
 * canonical shape; grants saved by earlier editor builds arrive with the
 * alias. Fails safe on a non-array input.
 */
export function canonicalActions(actions: AppGrantAction[]): AppGrantAction[] {
	const out: AppGrantAction[] = [];
	const seen = new Set<string>();
	for (const action of Array.isArray(actions) ? actions : []) {
		if (!action || typeof action.name !== 'string') continue;
		const names = action.name === 'write' ? ['create', 'update'] : [action.name];
		for (const name of names) {
			if (seen.has(name)) continue;
			seen.add(name);
			out.push({ name, required: Boolean(action.required) });
		}
	}
	return out;
}

function hasAll(set: Set<string>, names: string[]): boolean {
	return names.every((name) => set.has(name));
}

/**
 * Recover the plain level from a stored `actions[]` array.
 *
 * The input is canonicalised first (see {@link canonicalActions}), then
 * classified by subset over the canonical core names: `full` when the entry
 * covers `read` + `create` + `update` + `delete`, `write` when it covers
 * `read` + `create` + `update`, `read` when it covers `read`. A partial set
 * degrades to the highest level it fully covers — `{read, delete}` displays
 * as `read` — so a grant authored outside the picker never renders as no
 * access; the consent summary lists every action regardless. A grant with no
 * `read` at all (only `create`/`update`, or only named actions) reads as
 * `'none'`.
 */
export function actionsToLevel(actions: AppGrantAction[]): PlainLevel {
	const names = new Set(canonicalActions(actions).map((a) => a.name));
	if (hasAll(names, LEVEL_ACTIONS.full)) return 'full';
	if (hasAll(names, LEVEL_ACTIONS.write)) return 'write';
	if (names.has('read')) return 'read';
	return 'none';
}

/**
 * Resolve the **effective** level of a doctype as the picker displays it:
 * the doctype's own grant if it has one, otherwise its parent's effective
 * level (inheritance), otherwise `none`.
 *
 * Inheritance is computed by walking the `parentTarget` chain on the
 * catalogue. A doctype whose `parentTarget` is undefined is a root and
 * never inherits. The walk is bounded by the catalogue size and guards
 * against cycles by tracking visited targets.
 *
 * This is pure and carries no editor state. The editor's save step
 * materialises inherited levels into explicit grant entries for every child
 * that displays a non-`none` level — see `materialiseInherited`.
 */
export function resolveEffectiveLevel(
	grants: AppGrant[],
	target: string,
	catalogue: DoctypeCatalogueEntry[]
): PlainLevel {
	const byTarget = new Map(catalogue.map((e) => [e.target, e]));
	const visited = new Set<string>();
	let current: string | undefined = target;
	while (current) {
		if (visited.has(current)) break; // defensive: cycle guard
		visited.add(current);
		const grant = grants.find((g) => g.target === current);
		if (grant && grant.actions.length > 0) {
			const level = actionsToLevel(grant.actions);
			// A grant whose core action subset is empty (only named actions)
			// has no base level of its own — keep walking up to find one so
			// the picker can display the named-action pills on top of an
			// inherited base level.
			if (level !== 'none') return level;
		}
		const entry = byTarget.get(current);
		current = entry?.parentTarget;
	}
	return 'none';
}

/**
 * The required flags backing a doctype's **effective** level: the flags of
 * the grant the level walk resolves to — the doctype's own entry when it has
 * one, otherwise the nearest ancestor's (inheritance). Mirrors
 * {@link resolveEffectiveLevel}'s walk, including the rule that skips
 * entries with no core level of their own.
 *
 * The returned map keys the **display** action names: `read`, `write`,
 * `delete`, plus any named actions on the resolved entry. The canonical
 * `create`/`update` pair collapses into the single `write` flag — required
 * only when both declarations are required, because the picker shows one
 * pill for the pair and flipping it sets both. An empty map means no grant
 * backs the doctype — every flag defaults to `false` (optional).
 */
export function effectiveRequireds(
	grants: AppGrant[],
	target: string,
	catalogue: DoctypeCatalogueEntry[]
): Record<string, boolean> {
	const byTarget = new Map(catalogue.map((e) => [e.target, e] as const));
	const visited = new Set<string>();
	let current: string | undefined = target;
	while (current) {
		if (visited.has(current)) break; // defensive: cycle guard
		visited.add(current);
		const grant = grants.find((g) => g.target === current);
		if (grant && actionsToLevel(grant.actions) !== 'none') {
			const requireds: Record<string, boolean> = {};
			for (const action of canonicalActions(grant.actions)) {
				if (action.name === 'create' || action.name === 'update') {
					requireds['write'] = (requireds['write'] ?? true) && action.required;
				} else {
					requireds[action.name] = action.required;
				}
			}
			return requireds;
		}
		const entry = byTarget.get(current);
		current = entry?.parentTarget;
	}
	return {};
}

/**
 * Returns `true` when a grant exists for `target` and is non-empty. Used by
 * the editor to distinguish "inherited" (no own grant) from "overridden"
 * (own grant present) for the child's label.
 */
export function hasExplicitGrant(grants: AppGrant[], target: string): boolean {
	const grant = grants.find((g) => g.target === target);
	return Boolean(grant && grant.actions.length > 0);
}

/**
 * Clamp a desired child level so it never exceeds its parent's level. Levels
 * are ordered `none < read < write < full`. The clamp returns
 * `min(desired, parentLevel)`.
 *
 * The editor uses this both when the user picks a child level above the
 * parent (the pick is held at the parent's ceiling) and when the parent's
 * level drops (existing explicit child grants are clamped down, or cleared
 * to inherited — see {@link clearChildrenExceedingParent} for the clear
 * behaviour the editor applies on save-time parent drops).
 */
export function clampChildLevel(desired: PlainLevel, parentLevel: PlainLevel): PlainLevel {
	if (LEVEL_RANK[desired] <= LEVEL_RANK[parentLevel]) return desired;
	return parentLevel;
}

/**
 * Remove explicit child grant entries whose level now exceeds the parent's,
 * clearing them to the inherited state. Returns the new grants array (the
 * input is not mutated).
 *
 * Used when a parent's level drops. Clearing to inherited (rather than
 * clamping the explicit value down) keeps the stored grants minimal and
 * matches the common intent: dropping a parent means "this app should do
 * less." Children the user explicitly overrode are abandoned, not silently
 * rewritten.
 *
 * Only the direct children of `parentTarget` are considered; deeper
 * descendants are reached by calling this for each parent after its level
 * settles.
 */
export function clearChildrenExceedingParent(
	grants: AppGrant[],
	parentTarget: string,
	catalogue: DoctypeCatalogueEntry[]
): AppGrant[] {
	const parentLevel = resolveEffectiveLevel(grants, parentTarget, catalogue);
	const childEntries = catalogue.filter((e) => e.parentTarget === parentTarget);
	const next = grants.filter((grant) => {
		const isChild = childEntries.some((e) => e.target === grant.target);
		if (!isChild) return true;
		const childLevel = actionsToLevel(grant.actions);
		return LEVEL_RANK[childLevel] <= LEVEL_RANK[parentLevel];
	});
	return next;
}

// ── Consent summary (grouped by verb) ──────────────────────────────────────

/**
 * One grouped line of the consent copy. Multiple grants that share a verb are
 * folded into a single group ("Read your companies, contacts, and activities").
 *
 * - `kind` is `'core'` for the read/write/delete verbs (which take a noun list)
 *   or `'named'` for a doctype-declared named action whose label already embeds
 *   the noun (e.g. "Merge and convert companies"). Named groups render their
 *   `verb` verbatim and ignore `targets`.
 * - `verb` is the human verb phrase. For core groups: "Read",
 *   "Create and edit", "Delete". For named groups: the doctype-declared label.
 * - `targets` is the list of plural nouns the verb applies to. Empty for
 *   named groups (the noun is part of the verb label).
 * - `optional` is `true` only when every action in the group is optional
 *   (`required: false`). Mixed groups stay required; the consent footer
 *   carries the "you can decline any of these" line that applies globally.
 */
export type ConsentGroup = {
	kind: 'core' | 'named';
	verb: string;
	targets: string[];
	optional: boolean;
};

/**
 * Group a grants array into {@link ConsentGroup}s, grouped by verb.
 *
 * The verb mapping:
 * - `read` → "Read"
 * - `write` → "Create and edit" (write covers create + update)
 * - `delete` → "Delete"
 * - named actions → the doctype-declared action label
 *
 * The doctype plural noun comes from the catalogue entry's `pluralLabel`
 * (sourced from `core.DocType.plural_label`), with a fallback to a naive
 * pluraliser so existing seeds that omit `plural_label` still render.
 *
 * Defensive coercion: `app.App.grants` is array-typed on the doctype, but an
 * empty array can round-trip from the Lua lifecycle hook as a non-iterable
 * JSON shape (e.g. `{}`). Callers that only guard with `?? []` would still
 * pass that shape through, so this function fails safe and treats any
 * non-array as no grants.
 */
export function summarizeGrants(
	grants: AppGrant[],
	catalogue: DoctypeCatalogueEntry[]
): ConsentGroup[] {
	const arr = Array.isArray(grants) ? (grants as AppGrant[]) : ([] as AppGrant[]);
	const byTarget = new Map(catalogue.map((e) => [e.target, e] as const));

	// Bucket key is `${kind}:${verb}` so two different named actions on the
	// same target land in separate buckets, while the core read/create/update/
	// delete actions on multiple targets collapse into one bucket per verb
	// (create and update share the "Create and edit" verb).
	type Bucket = ConsentGroup & { actionNames: Set<string>; order: number };
	const buckets = new Map<string, Bucket>();
	let seq = 0;
	for (const grant of arr) {
		const entry = byTarget.get(grant.target);
		const noun = entry ? entry.pluralLabel : fallbackPlural(grant.target);
		for (const action of canonicalActions(grant.actions)) {
			const isCore = CORE_ACTION_NAMES.has(action.name);
			const verb = verbFor(action.name, entry);
			const key = `${isCore ? 'core' : 'named'}:${verb}`;
			let bucket = buckets.get(key);
			if (!bucket) {
				bucket = {
					kind: isCore ? 'core' : 'named',
					verb,
					targets: [],
					optional: true,
					actionNames: new Set(),
					order: seq++
				};
				buckets.set(key, bucket);
			}
			// Named-action labels already embed the noun (e.g. "Merge and
			// convert companies"), so the target list would duplicate it. Only
			// core groups collect nouns.
			if (isCore && !bucket.targets.includes(noun)) bucket.targets.push(noun);
			bucket.actionNames.add(action.name);
			if (action.required) bucket.optional = false;
		}
	}

	// Core groups sort by the read → create-and-edit → delete verb order;
	// named groups come after, in their first-seen order, so toggling a named
	// action on does not reshuffle the core copy. The bucket's verb is the
	// sort key — create and update share one bucket, so name-set size says
	// nothing about which verb it carries.
	const coreVerbs: string[] = [
		m.apps_grants_verb_read(),
		m.apps_grants_verb_write(),
		m.apps_grants_verb_delete()
	];
	const groups = [...buckets.values()];
	groups.sort((a, b) => {
		const ai = a.kind === 'core' ? coreVerbs.indexOf(a.verb) : -1;
		const bi = b.kind === 'core' ? coreVerbs.indexOf(b.verb) : -1;
		if (ai !== -1 && bi !== -1) return ai - bi;
		if (ai !== -1) return -1;
		if (bi !== -1) return 1;
		return a.order - b.order;
	});
	return groups.map(({ kind, verb, targets, optional }) => ({ kind, verb, targets, optional }));
}

/**
 * The display verb for a core action name ("Read", "Create and edit",
 * "Delete") — the same wording the consent summary uses, so the
 * required-flag row and the consent copy agree word for word.
 */
export function coreActionVerb(name: string): string {
	return verbFor(name);
}

/**
 * Map a single action name to the display verb used in the grouped consent
 * copy. `write` (the display alias) and the canonical `create`/`update` pair
 * read as "Create and edit"; named actions read as their doctype-declared
 * label, or fall back to the raw action name when no label is set.
 */
function verbFor(name: string, entry?: DoctypeCatalogueEntry): string {
	switch (name) {
		case 'read':
			return m.apps_grants_verb_read();
		case 'write':
		case 'create':
		case 'update':
			return m.apps_grants_verb_write();
		case 'delete':
			return m.apps_grants_verb_delete();
		default: {
			const declared = entry?.namedActions?.find((na) => na.name === name);
			return declared?.label ?? name;
		}
	}
}

/**
 * Returns `true` when at least one granted doctype is flagged sensitive on
 * the catalogue. Drives the "Contact data includes fields marked sensitive —
 * access is logged" footnote on the consent preview.
 */
export function anySensitiveGranted(
	grants: AppGrant[],
	catalogue: DoctypeCatalogueEntry[]
): boolean {
	const set = new Set(catalogue.filter((e) => e.sensitive).map((e) => e.target));
	const arr = Array.isArray(grants) ? (grants as AppGrant[]) : ([] as AppGrant[]);
	return arr.some((g) => set.has(g.target));
}

/**
 * Materialise inherited levels into explicit grant entries before save, so
 * the stored grants array matches the picker's displayed effective levels.
 *
 * The backend `AppScope` / `GrantResolver` does **not** implement
 * inheritance: a child with no grant entry has no effective permission
 * through the app token, even if the parent has `write`. To keep the
 * displayed permission aligned with the issued token, the editor writes an
 * explicit grant for every child that displays a non-`none` level — copying
 * the parent's effective level — unless the child already has its own
 * explicit grant.
 *
 * Named actions layered by the user on top of an inherited child are
 * preserved: when the child has named-action grants but no core read/write/
 * delete action, the materialisation also copies the parent's core level so
 * the named actions sit on a base level.
 *
 * Returns a new array; the input is not mutated. Helpers used for
 * classification (`LEVEL_ACTIONS`) are reused so the materialised grants
 * round-trip through {@link actionsToLevel}.
 */
export function materialiseInherited(
	grants: AppGrant[],
	catalogue: DoctypeCatalogueEntry[]
): AppGrant[] {
	const next: AppGrant[] = grants.map((g) => ({ ...g, actions: g.actions.map((a) => ({ ...a })) }));
	const byTarget = new Map(catalogue.map((e) => [e.target, e] as const));
	const roots = catalogue.filter((e) => e.parentTarget === undefined);

	for (const root of roots) {
		walkMaterialise(root, next, catalogue, byTarget);
	}
	return next;
}

function walkMaterialise(
	entry: DoctypeCatalogueEntry,
	grants: AppGrant[],
	catalogue: DoctypeCatalogueEntry[],
	byTarget: Map<string, DoctypeCatalogueEntry>
): void {
	const effective = resolveEffectiveLevel(grants, entry.target, catalogue);
	const explicit = grants.find((g) => g.target === entry.target);
	if (effective !== 'none' && !explicit) {
		// Inherited and non-none: write the parent's effective level as an
		// explicit grant so the backend treats the child as granted. The
		// parent's required flags ride along — what the picker displays is
		// what persists.
		const requireds = effectiveRequireds(grants, entry.target, catalogue);
		grants.push({ target: entry.target, actions: levelToActions(effective, requireds) });
	} else if (explicit && actionsToLevel(explicit.actions) === 'none' && effective !== 'none') {
		// The child has no readable core level of its own; layer the inherited
		// core level under its own actions, with the parent's flags. The merge
		// is canonicalised so a degenerate entry that already carries the
		// create/update pair keeps one declaration per action name — the
		// inherited flags win, matching what the picker displays.
		const requireds = effectiveRequireds(grants, entry.target, catalogue);
		explicit.actions = canonicalActions([
			...levelToActions(effective, requireds),
			...explicit.actions
		]);
	}
	const children = catalogue.filter((e) => e.parentTarget === entry.target);
	for (const child of children) {
		walkMaterialise(child, grants, catalogue, byTarget);
	}
}

// ── Plural fallback ────────────────────────────────────────────────────────

/**
 * Naive English pluralisation used as a fallback when a doctype has no
 * `plural_label` set. Good enough for most CamelCase doctype names; the
 * `plural_label` field exists so seeds can override it for the irregular
 * cases (`CompanyMembership` → "company memberships").
 *
 * The input is the qualified target (`crm.Contact`) or the doctype name; the
 * output is the plural noun (`"contacts"`).
 */
export function fallbackPlural(target: string): string {
	const dot = target.lastIndexOf('.');
	const bare = dot === -1 ? target : target.slice(dot + 1);
	const lower = bare.toLowerCase();
	if (lower.endsWith('s') || lower.endsWith('x') || lower.endsWith('ch')) {
		return `${lower}es`;
	}
	if (lower.endsWith('y') && !/(?:[aeiou])y$/.test(lower)) {
		return `${lower.slice(0, -1)}ies`;
	}
	return `${lower}s`;
}

/**
 * Exported for tests that need to assert the level ordering used by
 * {@link clampChildLevel}. Not part of the public picker API.
 */
export const __LEVEL_ORDER = ORDERED_LEVELS;
