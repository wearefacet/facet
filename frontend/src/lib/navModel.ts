// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Sidebar navigation model builder.
 *
 * Builds the `NavDomain[]` model consumed by `NavPanel.svelte` by reading
 * domain and doctype data through the DataSource API. When a permission
 * manifest is provided, doctypes and domains the user cannot read are
 * filtered out.
 *
 * This lives in the frontend because navigation is a presentation concern:
 * which domains/doctypes to show, how to label them, and which counts to
 * surface are decisions the sidebar owns. The backend IAM module
 * authenticates and issues tokens; it does not curate the sidebar.
 */

import type { DataDriver } from './datasource/driver.js';
import { DoctypeRegistry } from './datasource/DoctypeRegistry.js';
import type { DoctypeDefinitionRegistry } from './datasource/DoctypeRegistry.js';
import { domainListCache } from './datasource/clientCache.js';
import { canInManifest } from './permissions.svelte.js';
import type { NavDomain, NavDoctype } from './navTypes';
import { getPreviewSession } from './previewSession.svelte.js';
import * as m from '$lib/paraglide/messages';

/** Domain labels for known domains; unknown domains fall back to a capitalized id. */
const DOMAIN_LABELS: Record<string, string> = {
	core: 'Core',
	crm: 'CRM',
	hr: 'Human Resources',
	iam: 'Identity & Access',
	identity: 'Identity',
	production: 'Production'
};

/** Doctype fallback color when no color is declared on the definition. */
const DEFAULT_DOCTYPE_COLOR = '#566688';

/** Domain fallback color when no color is declared on the `core.Domain` document. */
const DEFAULT_DOMAIN_COLOR = '#3F51B5';

/**
 * Converts a `core.Domain` projection response (`{ data, meta }`) into a
 * `NavDomain` entry for the nav panel. Used by `buildNavModel` and by the
 * layout's draft-creation handlers (which receive a fresh projection from
 * the `/draft` or `/:id/draft` endpoints and need to prepend it to the nav).
 *
 * Drafts with no doctypes yet get an empty array — the doctype list is
 * populated on the next nav model rebuild. The one caller that must show the
 * list immediately — the preview dashboard's carve-out in
 * `routes/[domain=notApi]/+page.ts` — fills it right after the conversion
 * with `navDoctypesForDomain`.
 */
export function domainProjectionToNavDomain(resp: {
	data: Record<string, unknown>;
	meta: { id: string; updated_at?: string };
}): NavDomain {
	const data = resp.data;
	const isDraft = data.draft === true;
	// Label precedence: the free-text `label` field, then the id-contract
	// `name`. Both are optional on the document.
	const docLabel = (
		(data.label as string | undefined) ?? (data.name as string | undefined)
	)?.trim();
	let label: string;
	if (isDraft) {
		const source = data.source_domain as string | undefined;
		const sourceLabel =
			docLabel ?? (source ? (DOMAIN_LABELS[source] ?? capitalize(source)) : m.nav_draft_unnamed());
		label = m.nav_draft_label({ name: sourceLabel });
	} else {
		label = docLabel ?? DOMAIN_LABELS[resp.meta.id] ?? capitalize(resp.meta.id);
	}
	return {
		id: resp.meta.id,
		label,
		color: (data.color as string) ?? DEFAULT_DOMAIN_COLOR,
		doctypes: [],
		updatedAt: resp.meta.updated_at
	};
}

/**
 * Nav doctype tree for one domain, read from a registry snapshot.
 *
 * Applies the same visibility rules as `buildNavModel`'s doctype pass (see
 * `buildDomainNavTree`): a definition shows when it names a doctype and passes
 * the optional read-visibility predicate; composition children nest under
 * their parent. No manifest predicate is applied unless one is passed — the
 * preview overlay deliberately suppresses the permission manifest, because
 * the preview principal authorises every read on the bound draft (see
 * `routes/+layout.ts`).
 *
 * Used where a single domain's tree is needed without building the whole
 * model: the preview dashboard carve-out in `routes/[domain=notApi]/+page.ts`.
 */
export function navDoctypesForDomain(
	registry: DoctypeDefinitionRegistry,
	domainId: string,
	visible?: (qualified: string) => boolean
): NavDoctype[] {
	return buildDomainNavTree(registry.doctypeDefinitions, domainId, visible);
}

/**
 * Permission manifest shape — a map of `"domain.Doctype"` → actions.
 * Mirrors the `permissions` field shipped in login/refresh/`/me` responses.
 * The wildcard key `"*.*"` with action `"*"` means "everything". A
 * domain-wide grant is keyed `"{domain}.*"` (e.g. `"hr.*"`) and makes every
 * doctype in that domain actionable. Wildcard lines with `except` carve-outs
 * also carry reserved keys `"*.*.except.<action>"` — per action, the fold of
 * that action's lines' carve-out paths. A reserved key never names a doctype;
 * consumers must not iterate manifest keys to render one. See `canInManifest`
 * in `permissions.svelte.ts` for the matching semantics.
 */
export type PermissionManifest = Record<string, string[]>;

/**
 * Per-(doctype, action) scope manifest — mirrors the `scopes` field shipped
 * alongside `permissions` in login/refresh/`/me` responses.
 *
 * Each entry is an array of bare scope-alias names (no leading `$`) matching
 * the Lua `ctx.actor.scopes` surface. Semantics:
 * - `[]` (empty array) — action granted, unrestricted (e.g. can create a
 *   general/shared CollectionView or edit any row).
 * - `["mine", ...]` — action granted but scoped; the enforcer restricts rows
 *   and (for CollectionView `create`) the Lua hook force-sets `owner_id`.
 * - absent key — action not granted, or granted with no scope information.
 *   The reserved `"*.*"` key holds the wildcard lines' scope unions; the
 *   wildcard fallback in `canScope` consults it. No consumer may iterate
 *   scope keys to render a doctype.
 */
export type ScopeManifest = Record<string, Record<string, string[]>>;

/**
 * Options for `buildNavModel`.
 */
export interface BuildNavModelOptions {
	/**
	 * When `true`, only draft domains (`core.Domain` with `draft: true`) are
	 * included — used by builder mode. When `false` (default), drafts are
	 * filtered out and only live domains are shown.
	 */
	drafts?: boolean;
	/**
	 * Qualified doctype names the user has pinned. Matching doctypes are marked
	 * `pinned: true` so the nav panel can render them in the Pinned section and
	 * omit them from the main Doctypes list.
	 */
	pinnedDoctypes?: Iterable<string>;
}

/**
 * Builds the sidebar navigation model from the DataSource API.
 *
 * 1. Lists `core.Domain` documents for colors.
 * 2. Iterates `driver.doctypeDefinitions` for the doctype tree (skips `core`).
 *    Composition children nest under their parent — see `buildDomainNavTree`.
 * 3. Optionally filters by the user's permission manifest — a doctype is
 *    visible only if the role grants `read` (or `*`) on it through an exact
 *    key, holds the admin wildcard `*.* → ["*"]`, or the grant comes through
 *    the wildcard fallback (`*.*` carries `read`, doctype not excepted).
 * 4. Filters by draft mode: `drafts: true` shows only draft domains,
 *    `drafts: false` (default) hides drafts.
 *
 * Per-doctype document counts are NOT fetched here. `NavDoctype.count` is
 * left `undefined` and the sidebar resolves it lazily via `navCounts.svelte`
 * for the active domain only — see `doc/frontend/workflow.md` → DataSource.
 *
 * @param driver       A DataDriver (real `DocumentDataDriver` or `MockDataDriver`).
 * @param permissions  Optional permission manifest from the auth response.
 * @param options      Optional `{ drafts }` to switch between live and draft view.
 */
export async function buildNavModel(
	driver: DataDriver,
	permissions?: PermissionManifest,
	options?: BuildNavModelOptions
): Promise<NavDomain[]> {
	const isAdmin = isWildcardAdmin(permissions);
	const draftsOnly = options?.drafts === true;
	const pinned = new Set(options?.pinnedDoctypes ?? []);

	// When a preview session is active, its bound draft domain must stay
	// visible on the live nav model — otherwise `routes/[domain=notApi]/+page.ts`
	// cannot resolve `/_abc` from `parentData.domains` and throws a 404 even
	// though `apiFetch` carries the Bearer token authorising the read. We
	// surface the bound draft id here as a per-loop carve-out so the regular
	// `drafts: false` filter still hides everyone else's drafts.
	const previewDraftId = getPreviewSession()?.draftId ?? null;

	// Domain colors live as documents on core.Domain. Browser-side 60s TTL
	// cache so the layout load, the Builder landing load, and the per-route
	// nav rebuilds share one round-trip. SSR bypasses the cache.
	const domainList = (await domainListCache.get(async () => {
		const res = await driver.domain('core').doctype('Domain').list();
		return res.data;
	})) as { data: Record<string, unknown>; meta: { id: string } }[];
	const domainColor = new Map<string, string>();
	const domainLabel = new Map<string, string>();
	const domainUpdatedAt = new Map<string, string>();
	const visibleDomainIds = new Set<string>();
	for (const item of domainList) {
		const isDraft = item.data.draft === true;
		// Preview carve-out: the bound draft domain bypasses the live/draft
		// filter (see `previewDraftId` declaration above for why). All other
		// drafts keep the regular `draftsOnly`-based filtering.
		const isBoundDraft = previewDraftId !== null && item.meta.id === previewDraftId;
		if (!isBoundDraft && isDraft !== draftsOnly) continue;
		visibleDomainIds.add(item.meta.id);
		const color = item.data.color as string | undefined;
		if (color) domainColor.set(item.meta.id, color);

		// Label precedence: the free-text `label` field, then the id-contract
		// `name`. Otherwise drafts (autogenerated `_`-prefixed ids) fall back
		// to a source-derived label.
		const docLabel = (
			(item.data.label as string | undefined) ?? (item.data.name as string | undefined)
		)?.trim();
		if (docLabel) {
			domainLabel.set(item.meta.id, isDraft ? m.nav_draft_label({ name: docLabel }) : docLabel);
		} else if (isDraft) {
			const source = item.data.source_domain as string | undefined;
			const sourceLabel = source
				? (DOMAIN_LABELS[source] ?? capitalize(source))
				: m.nav_draft_unnamed();
			domainLabel.set(item.meta.id, m.nav_draft_label({ name: sourceLabel }));
		}

		// Preserve the updated_at timestamp for the Configure/domains list.
		const updatedAt = (item.meta as { updated_at?: string }).updated_at;
		if (updatedAt) domainUpdatedAt.set(item.meta.id, updatedAt);
	}

	// Build a visibility predicate from the manifest (unless admin). The
	// predicate answers per doctype, so a grant through the wildcard fallback
	// (`*.*` carries `read`, doctype not excepted) makes a doctype visible.
	const visibleDoctypes = isAdmin ? null : computeVisibleDoctypes(permissions);

	// Doctype definitions — `DoctypeRegistry.cached` shares one snapshot
	// (60s TTL on the browser) across all route loads and nav rebuilds. On
	// SSR there is no caching.
	const registry = await DoctypeRegistry.cached(driver);
	const defs = registry.doctypeDefinitions;

	// Seed every visible domain with an empty doctype tree so domains that have
	// no doctypes yet (e.g. a freshly created empty draft) still appear in the
	// nav. In live mode we skip this: a live domain with no visible doctypes
	// (under a non-admin RBAC manifest) stays hidden to avoid empty clutter.
	const byDomain = new Map<string, NavDoctype[]>();

	// Doctype entries are emitted with `count: undefined` — the sidebar fetches
	// counts lazily via `navCounts.svelte` for the active domain only. This
	// keeps `buildNavModel` a pure data-shape pass: no per-doctype round-trips
	// fire for domains the user never opens.
	for (const domainId of visibleDomainIds) {
		if (domainId === 'core') continue;
		const tree = buildDomainNavTree(defs, domainId, visibleDoctypes ?? undefined, pinned);
		if (tree.length === 0 && !draftsOnly) continue;
		byDomain.set(domainId, tree);
	}

	return [...byDomain.entries()].map(([id, doctypes]) => ({
		id,
		label: domainLabel.get(id) ?? DOMAIN_LABELS[id] ?? capitalize(id),
		color: domainColor.get(id) ?? DEFAULT_DOMAIN_COLOR,
		doctypes,
		updatedAt: domainUpdatedAt.get(id)
	}));
}

// ── Internals ──────────────────────────────────────────────────────────────

/** One in-domain doctype definition collected by {@link buildDomainNavTree}. */
interface NavNode {
	qualified: string;
	def: Record<string, unknown>;
	/** True when the definition is a composition child: `member_of` set and
	 *  not an aggregate root. Such children nest under their parent. */
	isChild: boolean;
	/** Passes the optional read-visibility predicate (the manifest matcher). */
	visible: boolean;
}

/**
 * Builds one domain's nav doctype tree from the registry snapshot.
 *
 * Every in-domain definition that names a doctype and passes the optional
 * read-visibility predicate renders. Composition children (`member_of` set,
 * not an aggregate root) nest under their parent's `children`, following the
 * chain up through the domain (a child of a child nests at depth 2). The
 * nesting rule replaces the old flat-opt-in rule: `nav_visible` now matters
 * only when the parent cannot host the child in the tree — the parent's
 * definition is missing, it lives in another domain, or RBAC hides it. In
 * those cases an opted-in child falls back to a flat top-level row (its
 * documented reachability path), and an unopted-in child stays hidden.
 *
 * A composition child always needs its own read grant; nesting never
 * bypasses the manifest. A visible child under a visible parent whose chain
 * loops (malformed `member_of`) is treated as a broken chain — same flat /
 * hidden fallback, no infinite recursion.
 *
 * Order is stable: top-level entries and every `children` array follow the
 * registry iteration order.
 */
function buildDomainNavTree(
	defs: Map<string, Record<string, unknown>>,
	domainId: string,
	visible?: (qualified: string) => boolean,
	pinned?: Set<string>
): NavDoctype[] {
	const nodes = new Map<string, NavNode>();
	for (const [qualified, def] of defs) {
		const dot = qualified.indexOf('.');
		if (qualified.slice(0, dot) !== domainId) continue;
		if (!(def.doctype as string | undefined)) continue;
		const memberOf = def.member_of as string | undefined;
		const aggregateRoot = def.aggregate_root === true;
		nodes.set(qualified, {
			qualified,
			def,
			isChild: Boolean(memberOf) && !aggregateRoot,
			visible: visible ? visible(qualified) : true
		});
	}

	// Memoized chain resolution: `true` when the node itself is visible and
	// every `member_of` ancestor up to a non-child root is too, with every
	// hop resolving inside this domain. Cycles fail without recursing forever.
	const chainOk = new Map<string, boolean>();
	const walking = new Set<string>();
	const parentOf = (node: NavNode): string =>
		`${domainId}.${((node.def.member_of as string | undefined) ?? '').trim()}`;

	const resolves = (qualified: string): boolean => {
		const memo = chainOk.get(qualified);
		if (memo !== undefined) return memo;
		const node = nodes.get(qualified);
		if (!node || !node.visible) return false;
		if (!node.isChild) {
			chainOk.set(qualified, true);
			return true;
		}
		const parent = parentOf(node);
		if (!nodes.has(parent)) {
			chainOk.set(qualified, false);
			return false;
		}
		if (walking.has(qualified)) return false; // member_of cycle
		walking.add(qualified);
		const ok = resolves(parent);
		walking.delete(qualified);
		chainOk.set(qualified, ok);
		return ok;
	};

	// First pass — shape every visible definition into an entry, so a child
	// can attach to a parent defined later in the registry order.
	const entries = new Map<string, NavDoctype>();
	for (const node of nodes.values()) {
		if (!node.visible) continue;
		entries.set(
			node.qualified,
			toNavDoctype(node.def, node.qualified, pinned?.has(node.qualified) ?? false)
		);
	}

	// Second pass — nest children under their chain-resolved parent; roots and
	// flat fallbacks go top-level.
	const topLevel: NavDoctype[] = [];
	for (const node of nodes.values()) {
		if (!node.visible) continue;
		const entry = entries.get(node.qualified)!;
		if (node.isChild && resolves(node.qualified)) {
			const parent = entries.get(parentOf(node))!;
			(parent.children ??= []).push(entry);
		} else if (!node.isChild || node.def.nav_visible === true) {
			topLevel.push(entry);
		}
		// else: composition child with a broken chain and no opt-in — hidden.
	}
	return topLevel;
}

/** Shapes one doctype definition into a `NavDoctype` nav entry. */
function toNavDoctype(
	def: Record<string, unknown>,
	qualified: string,
	pinned: boolean
): NavDoctype {
	const label = (def.label as string | undefined)?.trim() || (def.doctype as string);
	return {
		qualified,
		label,
		color: (def.color as string) || DEFAULT_DOCTYPE_COLOR,
		icon: (def.icon as string | undefined) ?? null,
		pinned
	};
}

/** Returns true when the manifest grants the admin wildcard (`*.* → ["*"]`). */
function isWildcardAdmin(permissions?: PermissionManifest): boolean {
	if (!permissions) return false;
	const wildcard = permissions['*.*'];
	return Array.isArray(wildcard) && wildcard.includes('*');
}

/**
 * Builds the read-visibility predicate for the manifest. A doctype is
 * visible when the role grants `read` (or `*`) on it, through an exact key
 * or through the `*.*` wildcard fallback with the doctype not excepted.
 * Returns `null` when no manifest is provided (no filtering).
 */
function computeVisibleDoctypes(
	permissions?: PermissionManifest
): ((qualified: string) => boolean) | null {
	if (!permissions) return null;
	return (qualified: string) => canInManifest(permissions, qualified, 'read');
}

function capitalize(s: string): string {
	return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1);
}
