// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reactive RBAC permission store for the frontend.
 *
 * The backend ships a `PermissionManifest` — a `Record<string, string[]>` —
 * in every `/Api/iam/me`, login, and token-refresh response. The layout load and the
 * `facet:permissions-update` event both feed this store so that any component that
 * depends on it re-renders when the active role's permissions change.
 *
 * ## What this is — and what it is not
 *
 * `<Can>` and `can()` are **UI hints**. They hide affordances the user lacks permission
 * for. They are **not** a security boundary — the backend `WriteEnforcer` / `ReadEnforcer`
 * re-checks every action on the server. Never rely on `<Can>` alone to prevent a request.
 *
 * ## Matching semantics
 *
 * - The manifest is keyed by exact `"domain.Doctype"` (e.g. `"core.DocType"`).
 *   An explicit key grants when its action list holds the action name or `"*"`.
 *   An explicit key grant always wins — it is never suppressed by the wildcard
 *   carve-outs, mirroring the backend `except` arithmetic (pure path
 *   subtraction, not a deny system).
 * - The domain-wildcard key `"{domain}.*"` (e.g. `"hr.*"`) carries a
 *   domain-wide grant — it makes every doctype in that domain actionable. The
 *   check consults it when the exact key does not grant, before the `"*.*"`
 *   fallback, and it is never suppressed by `"*.*.except"` carve-outs (those
 *   belong to the `"*.*"` line).
 * - The reserved keys `"*.*.except.<action>"` carry the wildcard `*.*` lines'
 *   `except` carve-outs, folded per action — the intersection of that action's
 *   wildcard lines' except lists (the backend emits a key only when non-empty).
 *   Per-action keys keep the carve-outs exact when the lines except different
 *   doctypes per action (B-85: the seeded editor creates `core.Webhook`
 *   through its wildcard but reads/edits/deletes only its own). No reserved
 *   key ever names a doctype; nothing may iterate manifest keys to render one.
 * - `actions.includes(action)` grants the specific action name (`read`, `create`,
 *   `update`, `delete`, `*`, or a named action like `promote`). No aliases: `write`
 *   is not honoured; callers use the actual action name from the doctype definition.
 * - `"*.*" → ["*"]` is the admin wildcard and short-circuits to `true` for every check.
 * - Wildcard fallback: when the exact key is absent or lacks the action, the check
 *   consults the `"*.*"` action list. The fallback grants only when the doctype is
 *   NOT excepted — no `"*.*.except"` entry equals the doctype or is a path prefix of
 *   it (`core.DocType` also excludes `core.DocType.Comment`) — and the wildcard
 *   action list holds the action or `"*"`. This is what makes a wildcard-with-except
 *   role (e.g. the seeded `editor`) render its affordances.
 * - No manifest loaded → `false` (fail-closed, matching `AuthContext.denied` backend-side).
 */

import type { PermissionManifest } from './navModel';
import type { ScopeManifest } from './navModel';
import { isPreviewActive } from './previewSession.svelte';

let permissions: PermissionManifest | null = $state(null);
let scopes: ScopeManifest | null = $state(null);
let visibleTags: string[] | null = $state(null);

export function setPermissions(manifest: PermissionManifest | null | undefined): void {
	permissions = manifest ?? null;
}

export function getPermissions(): PermissionManifest | null {
	return permissions;
}

export function setScopes(scopeManifest: ScopeManifest | null | undefined): void {
	scopes = scopeManifest ?? null;
}

export function getScopes(): ScopeManifest | null {
	return scopes;
}

/**
 * The active role's `visible_tags` — the field-tag visibility set the
 * backend read mask applies. Served by `GET /Api/iam/me` and the
 * login/refresh emits. Null when not hydrated (or the role projection is
 * missing): the field-visibility filter then applies nothing.
 */
export function setVisibleTags(tags: string[] | null | undefined): void {
	visibleTags = tags ?? null;
}

export function getVisibleTags(): string[] | null {
	return visibleTags;
}

/**
 * The pure predicate behind `fieldVisible` — mirrors the backend
 * `RBAC::FieldVisibility.field_visible?`: a field is visible when every one
 * of its tags sits in the active role's `visible_tags`. Untagged fields
 * resolve to `['default']`; the `*` tag sees everything.
 *
 * `visible` null or undefined means "no filter known" — the check passes.
 * This is an affordance filter only: it hides inputs the caller can never
 * save (the write guard refuses invisible-field writes with 403). It must
 * never hide data — the read mask already omitted it server-side.
 */
export function fieldVisibleInTags(
	fieldTags: string[] | undefined,
	visible: string[] | null | undefined
): boolean {
	if (!visible) return true;
	if (visible.includes('*')) return true;
	const required = fieldTags && fieldTags.length > 0 ? fieldTags : ['default'];
	return required.every((tag) => visible.includes(tag));
}

/**
 * Returns `true` when the active role can see the given field (B-176).
 *
 * Preview overlay: when a preview capability token is active, every check
 * returns `true` — the preview principal sees the draft's fields raw, the
 * same carve-out `can()` applies.
 */
export function fieldVisible(field: { tags?: string[] }): boolean {
	if (isPreviewActive()) return true;
	return fieldVisibleInTags(field.tags, visibleTags);
}

/**
 * Reserved-key prefix for the wildcard carve-outs, suffixed with the action —
 * e.g. `"*.*.except.create"`. The value holds the intersection of that
 * action's wildcard lines' `except` lists.
 */
const WILDCARD_EXCEPT_PREFIX = '*.*.except.';

/**
 * True when `doctype` sits inside one of the manifest's wildcard carve-outs
 * for `action`. Entries prefix-match like the backend `except` grammar: an
 * entry on `core.DocType` also excludes `core.DocType.Comment`. Absent
 * reserved key → nothing is excepted for that action.
 */
function isExceptedByWildcard(
	manifest: PermissionManifest,
	doctype: string,
	action: string
): boolean {
	const except = manifest[WILDCARD_EXCEPT_PREFIX + action];
	if (!Array.isArray(except)) return false;
	return except.some((entry) => doctype === entry || doctype.startsWith(entry + '.'));
}

/**
 * The domain-wildcard manifest key for a qualified doctype — `"hr.*"` for
 * `"hr.Request"`. Returns `null` when `doctype` is not qualified (no domain
 * segment), so the caller skips the domain-wildcard tier.
 */
function domainWildcardKey(doctype: string): string | null {
	const dot = doctype.indexOf('.');
	if (dot <= 0) return null;
	return doctype.slice(0, dot) + '.*';
}

/**
 * The pure matcher behind `can()` — no store access, no preview overlay.
 *
 * Grant order:
 * 1. Admin short-circuit — `"*.*" → ["*"]` grants everything.
 * 2. Exact key — `manifest[doctype]` grants when it holds `action` or `"*"`.
 * 3. Domain-wildcard key — `manifest["{domain}.*"]` grants when it holds
 *    `action` or `"*"` (a domain-wide grant). Never suppressed by carve-outs.
 * 4. Wildcard fallback — the `"*.*"` action list grants when the doctype is
 *    not excepted (see `isExceptedByWildcard`) and the list holds `action`.
 *
 * @param manifest The manifest from the auth response, or null/undefined (fail-closed).
 * @param doctype  Qualified doctype key, e.g. `"core.DocType"`.
 * @param action   Action name: `read`, `create`, `update`, `delete`, `*`,
 *                 or a custom action declared on the doctype (e.g. `promote`).
 */
export function canInManifest(
	manifest: PermissionManifest | null | undefined,
	doctype: string,
	action: string
): boolean {
	if (!manifest) return false;

	const wildcard = manifest['*.*'];
	if (Array.isArray(wildcard) && wildcard.includes('*')) return true;

	const actions = manifest[doctype];
	if (Array.isArray(actions) && (actions.includes(action) || actions.includes('*'))) {
		return true;
	}

	// Domain-wildcard fallback — a domain-wide grant makes every doctype in
	// the domain actionable. It sits between the exact key and the `*.*`
	// fallback and is never suppressed by `*.*.except` carve-outs (those
	// belong to the `*.*` line).
	const domainKey = domainWildcardKey(doctype);
	const domainActions = domainKey ? manifest[domainKey] : undefined;
	if (
		Array.isArray(domainActions) &&
		(domainActions.includes(action) || domainActions.includes('*'))
	) {
		return true;
	}

	// Wildcard fallback — the exact key is absent or lacks the action.
	if (!Array.isArray(wildcard)) return false;
	if (isExceptedByWildcard(manifest, doctype, action)) return false;
	return wildcard.includes(action) || wildcard.includes('*');
}

/**
 * Returns `true` when the active role holds `action` on `doctype`.
 *
 * Preview overlay: when a preview capability token is active, every check
 * returns `true` — the bound draft's doctypes permit every CRUD action (see
 * `RBAC::PreviewEnforcer`). The drafter sees every affordance the live
 * application would offer against a published domain. Other domains are
 * gated by the user's real role, but the live UI typically renders only the
 * bound draft during preview.
 *
 * @param doctype Qualified doctype key, e.g. `"core.DocType"`.
 * @param action  Action name: one of `read`, `create`, `update`, `delete`, `*`,
 *                or a custom action declared on the doctype (e.g. `promote`).
 */
export function can(doctype: string, action: string): boolean {
	if (isPreviewActive()) return true;
	return canInManifest(permissions, doctype, action);
}

/**
 * Outcome of an RBAC scope query — mirrors the backend `CanResult` variants:
 * - `'unrestricted'` — action granted with no scope restriction (the Lua
 *   `ctx.actor.scope` would be `nil`). The caller may act across all rows /
 *   create a general (shared) resource.
 * - `'denied'` — no matching permission at all.
 * - `string[]` — action granted but scoped to the returned alias names (bare,
 *   no leading `$`), e.g. `['mine']`. The backend enforcer restricts rows and,
 *   for CollectionView `create`, the Lua hook force-binds `owner_id`.
 */
export type ScopeResult = 'unrestricted' | 'denied' | string[];

/**
 * Returns the scope of the `action` permission held by the active role on
 * `doctype`. Mirrors the Lua `ctx.actor.scopes` so the frontend can decide
 * affordances the action-name-only `can()` cannot (e.g. general vs personal
 * CollectionView creation).
 *
 * Grant resolution mirrors `canInManifest`: the exact key first, then the
 * domain-wildcard key (`"{domain}.*"`, a domain-wide grant), then the
 * wildcard fallback (excepted doctypes never resolve through it). When the
 * grant comes from the domain-wildcard key, the scope reads from
 * `scopes["{domain}.*"]`; when it comes from the fallback, from
 * `scopes["*.*"]` — the backend merges each line's scopes under its own key.
 *
 * @param doctype Qualified doctype key, e.g. `"core.CollectionView"`.
 * @param action  Action name, e.g. `"create"`.
 */
export function canScope(doctype: string, action: string): ScopeResult {
	if (isPreviewActive()) return 'unrestricted';

	const manifest = permissions;
	if (!manifest) return 'denied';

	const wildcard = manifest['*.*'];
	if (Array.isArray(wildcard) && wildcard.includes('*')) return 'unrestricted';

	// Grant via the exact key, else the domain-wildcard key, else the
	// wildcard fallback.
	const exact = manifest[doctype];
	const viaExact = Array.isArray(exact) && (exact.includes(action) || exact.includes('*'));

	const domainKey = domainWildcardKey(doctype);
	const domainActions = domainKey ? manifest[domainKey] : undefined;
	const viaDomain =
		!viaExact &&
		Array.isArray(domainActions) &&
		(domainActions.includes(action) || domainActions.includes('*'));

	let viaWildcard = false;
	if (!viaExact && !viaDomain && Array.isArray(wildcard)) {
		viaWildcard =
			!isExceptedByWildcard(manifest, doctype, action) &&
			(wildcard.includes(action) || wildcard.includes('*'));
	}
	if (!viaExact && !viaDomain && !viaWildcard) return 'denied';

	const scopeMap = scopes;
	if (!scopeMap) return 'unrestricted';

	const scopeKey = viaExact ? doctype : viaDomain ? domainKey! : '*.*';
	const actionScopes = scopeMap[scopeKey]?.[action];
	if (actionScopes === undefined) return 'unrestricted';
	return actionScopes;
}
