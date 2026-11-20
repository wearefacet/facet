// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * What the credential may do — the `GET /Api/iam/me` payload and the
 * client-side matchers over its permission manifest.
 *
 * The manifest is advisory. The server re-resolves grant ∩ role on every
 * request and never reads this manifest back; apps use `can` to size
 * affordances (hide a button, skip a panel) so a denied call is the
 * exception, not the plan. The shape follows the credential: a session
 * token answers the active role's manifest; an app token or an app-owned
 * API key answers the resolved grant ∩ role — from the app's perspective a
 * document its grant does not name does not exist, so no `*.*` fallback
 * and no doctype outside the grant appears.
 */

/** The account block of `/Api/iam/me`. */
export interface MeAccount {
	id: string;
	display_name: string;
	email: string;
	mfa_enabled: boolean;
	mfa_enforcement: unknown;
	mfa_type: string | null;
}

/** Assistant availability for the caller — the block `@facetapp/chat` consumers gate on. */
export interface AssistantCapability {
	/** The role's `assistant_access`, ANDed with the app's own flag for app tokens. */
	access: boolean;
	/** The account-wide 30-day token budget; `null` when unlimited. */
	token_budget: number | null;
	/** The configured assistant display name. */
	name: string | null;
}

/** The `GET /Api/iam/me` response. */
export interface Me {
	account: MeAccount;
	/** Qualified role reference, e.g. `iam.Roles.editor`. */
	active_role: string | null;
	available_roles: string[];
	/** Access-token expiry, unix seconds. `null` for a key caller. */
	expires_at: number | null;
	assistant: AssistantCapability;
	/** Programmatic channels the role carries: `mcp`, `webhook`, `api`, `assistant`. */
	connectivity: string[];
	/** `session` for a browser session, `api` for a key or app token. */
	channel: 'session' | 'api';
	/**
	 * Permission manifest: manifest key → action names. Keys are `*.*`,
	 * `domain.*`, or dotted `domain.Doctype` paths; the reserved
	 * `{key}.except.{action}` suffix carries folded carve-outs.
	 */
	permissions?: Record<string, string[]>;
	/** Scope aliases per manifest key and action — `[]` means unrestricted. */
	scopes?: Record<string, Record<string, string[]>>;
	/** The active role's field-visibility tags. */
	visible_tags?: string[];
	settings?: unknown;
}

/** The answer of `facet.can` — mirrors the backend `CanResult`. */
export type CanAnswer = 'all' | 'scoped' | 'denied';

type Manifest = NonNullable<Me['permissions']>;
type ScopeMap = NonNullable<Me['scopes']>;

const EXCEPT_SEP = '.except.';
const WILDCARD = '*';

function exceptKeyFor(key: string, action: string): string {
	return `${key}${EXCEPT_SEP}${action}`;
}

/**
 * True when one `domain.Doctype` carve-out entry covers the target —
 * prefix rule over the doctype segments, mirroring the backend
 * `Permission#matches_except?`: an entry on `crm.Contact` also covers
 * `crm.Contact.Comment`.
 */
function exceptCovers(entry: string, domain: string, doctypePath: string[]): boolean {
	const parts = entry.split('.');
	if (parts[0] !== domain) {
		return false;
	}
	const entryPath = parts.slice(1);
	if (entryPath.length > doctypePath.length) {
		return false;
	}
	return entryPath.every((segment, i) => segment === doctypePath[i]);
}

/** The folded carve-out list of one key and action; `[]` when absent. */
function exceptOf(manifest: Manifest, key: string, action: string): string[] {
	return manifest[exceptKeyFor(key, action)] ?? [];
}

/**
 * The manifest keys that reach `path`: every concrete ancestor (a key on
 * `crm.Contact` reaches `crm.Contact.Comment`), the domain wildcard, and
 * the global wildcard.
 */
function keysForPath(path: string[]): string[] {
	const keys: string[] = [];
	for (let i = 2; i <= path.length; i++) {
		keys.push(path.slice(0, i).join('.'));
	}
	keys.push(`${path[0]!}.*`);
	keys.push('*.*');
	return keys;
}

/**
 * The action names one manifest key holds that reach `action`: the action
 * itself, or the wildcard action.
 */
function grantingActions(actions: string[] | undefined, action: string): string[] {
	if (!actions) {
		return [];
	}
	if (actions.includes(action)) {
		return [action];
	}
	return actions.includes(WILDCARD) ? [WILDCARD] : [];
}

/**
 * The (key, held-action) pairs that grant `action` on `path` — keys that
 * reach the path, grant the action, and whose folded carve-outs miss it.
 * A path with no domain segment reaches nothing: the backend rejects the
 * bare form, so the matcher answers denied.
 */
function grantingKeys(
	permissions: Manifest | undefined,
	action: string,
	path: string[]
): Array<{ key: string; held: string }> {
	if (!permissions || path.length < 2) {
		return [];
	}
	const domain = path[0]!;
	const doctypePath = path.slice(1);
	const pairs: Array<{ key: string; held: string }> = [];
	for (const key of keysForPath(path)) {
		for (const held of grantingActions(permissions[key], action)) {
			// The backend folds carve-outs per granted action; a
			// wildcard-action fold rides the reserved `.except.*` key.
			const carved = [
				...exceptOf(permissions, key, action),
				...exceptOf(permissions, key, WILDCARD)
			].some((entry) => exceptCovers(entry, domain, doctypePath));
			if (!carved) {
				pairs.push({ key, held });
			}
		}
	}
	return pairs;
}

/**
 * Answers `can` for one manifest: `'denied'` when no key reaches the path,
 * `'all'` when a granting key is unrestricted, `'scoped'` when every
 * granting key carries scope aliases.
 */
export function can(
	permissions: Manifest | undefined,
	scopes: ScopeMap | undefined,
	action: string,
	onPath: string
): CanAnswer {
	const pairs = grantingKeys(permissions, action, onPath.split('.'));
	if (pairs.length === 0) {
		return 'denied';
	}
	for (const { key, held } of pairs) {
		const aliases = scopes?.[key]?.[held] ?? scopes?.[key]?.[action];
		if (aliases === undefined || aliases.length === 0) {
			return 'all';
		}
	}
	return 'scoped';
}

/**
 * The scope aliases the manifest holds for `action` on `path` — the union
 * over every granting key. `[]` means unrestricted; the empty union of a
 * denied answer is also `[]`, so callers check `can` first.
 */
export function scopeAliases(
	permissions: Manifest | undefined,
	scopes: ScopeMap | undefined,
	action: string,
	onPath: string
): string[] {
	if (can(permissions, scopes, action, onPath) === 'denied') {
		return [];
	}
	const aliases: string[] = [];
	for (const { key, held } of grantingKeys(permissions, action, onPath.split('.'))) {
		const list = scopes?.[key]?.[held] ?? scopes?.[key]?.[action];
		if (list === undefined) {
			continue;
		}
		if (list.length === 0) {
			return [];
		}
		for (const alias of list) {
			if (!aliases.includes(alias)) {
				aliases.push(alias);
			}
		}
	}
	return aliases;
}
