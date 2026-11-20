// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { load as yamlLoad, YAML11_SCHEMA, defineScalarTag, type Schema } from 'js-yaml';
import { MockDataDriver } from './MockDriver.js';
import type { FixtureEntity } from './MockDriver.js';

// ── Path resolution ─────────────────────────────────────────────────────────
//
// Seeds live at `data/seeds/` in the legacy per-doctype directory format
// (`{domain}.{Doctype}/definition.yml` + documents files). Fixtures live at
// `data/fixtures/` as portable-domain bundles (`{domain}.facet-domain/`) —
// the same format produced by `facet domain:export --with-documents`. Both
// are relative to the project root (the parent of `frontend/`).
//
// A portable-domain bundle has the layout:
//   {domain}.facet-domain/
//     bundle.yml                       # format_version, source_domain, exported_at
//     domain.yml                       # { content, meta } — core.Domain document
//     doctypes/{Qualified}.yml         # { content, meta } — one per doctype (content IS the definition)
//     views/{qualified}/
//       document_views/{key}.yml        # { content, meta } — core.DocumentView children
//       collection_views/{slug}.yml     # { content, meta } — core.CollectionView children (general)
//     documents/{qualified}/{doc_id}.yml  # { content, meta } — one per user document
//
// The loader flattens a bundle into the same `FixtureEntity[]` shape the seed
// loader emits: one entity per user doctype (definition + documents), plus
// aggregate `core.Domain`, `core.DocumentView`, and `core.CollectionView`
// entities assembled from the bundle's `domain.yml` and `views/` tree.
//
// `import.meta.glob` resolves the YAML files at transform time so the same
// loader works in every Vite-powered context (Storybook, vitest `client` and
// `server` projects, the dev server). Paths are anchored from the project
// root (`/`) so the glob reaches `../data/...` regardless of where this
// module is imported from.

// ── Seeds (legacy per-doctype directory format, unchanged) ──────────────────

const seedDefs = import.meta.glob('/../data/seeds/*/definition.yml', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;
const seedDocs = import.meta.glob('/../data/seeds/*/*.{yml,yaml,json}', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;
// Seed entries of the view meta-doctypes (`core.DocumentView`,
// `core.CollectionView`) carry `meta.parent_id` — `rewriteSeedChildIds`
// maps them onto the mock driver's `{parent}.{rel}.*` child-id convention.
const seedScripts = import.meta.glob('/../data/seeds/*/script.lua', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;

// ── Fixtures (portable-domain bundles) ──────────────────────────────────────
//
// Four glob tiers cover every YAML entry in every bundle. The bundle root is
// `data/fixtures/{domain}.facet-domain/`; the presence of `domain.yml` (one
// per bundle root) is the canonical "this directory is a bundle" signal —
// `facet domain:export` always writes it first, and a non-bundle directory
// under `data/fixtures/` with no `domain.yml` is silently ignored.

const fixtureDomainEntries = import.meta.glob('/../data/fixtures/*/domain.yml', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;
const fixtureDoctypesDir = import.meta.glob('/../data/fixtures/*/doctypes/*.yml', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;
const fixtureDocumentViews = import.meta.glob('/../data/fixtures/*/views/*/document_views/*.yml', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;
const fixtureCollectionViews = import.meta.glob(
	'/../data/fixtures/*/views/*/collection_views/*.yml',
	{ query: '?raw', import: 'default', eager: true }
) as Record<string, string>;
const fixtureDocuments = import.meta.glob('/../data/fixtures/*/documents/*/*.yml', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;

// Lua sidecars that doctype definitions reference with `!read_file`. The bundle
// format externalizes a doctype's lifecycle `script` to a co-located
// `doctypes/{Qualified}.lua` file and references it instead of inlining it.
// The backend reader `Facet::Util::YamlInclude` expands these on import; the
// frontend mock loader mirrors that here so `MockDataDriver` sees the same
// expanded definition. Every `!read_file` target lives under a bundle's
// `doctypes/` directory (see `doc/shared/fixtures.md`).
const fixtureLuaSidecars = import.meta.glob('/../data/fixtures/*/doctypes/*.lua', {
	query: '?raw',
	import: 'default',
	eager: true
}) as Record<string, string>;

// ── Fixture/seed descriptor map ─────────────────────────────────────────────

interface DirDescriptor {
	domain: string;
	doctype: string;
	/** Raw YAML content of the definition file. Omit for core doctypes defined in seeds. */
	defRaw?: string;
	/** Raw YAML content of each documents file in the directory, in glob order. */
	docsRawList: string[];
	/** Concatenated documents parse across every documents file in the directory. */
	documents: { id: string; content: Record<string, unknown> }[];
	scriptRaw?: string;
}

/** Extract definition and documents from a descriptor, treating missing defRaw as no-definition. */
function toFixtureEntity(d: DirDescriptor): FixtureEntity {
	const definition: Record<string, unknown> | undefined = d.defRaw
		? parseDefinition(d.defRaw)
		: undefined;

	// Inject co-located script.lua content into the definition's `script` field.
	// This mirrors the backend's Seed.inject_script behaviour.
	if (definition && d.scriptRaw) {
		definition['script'] = d.scriptRaw;
	}

	return {
		domain: d.domain,
		doctype: d.doctype,
		definition,
		documents: d.documents
	};
}

/**
 * Build the fixture descriptor list from the globbed raw imports.
 *
 * Each glob key looks like `../data/fixtures/<dir>/definition.yml` or
 * `../data/fixtures/<dir>/documents.yml` (or any other `*.yml`/`*.yaml`/`*.json`
 * documents file in the directory). We derive the `{domain}.{Doctype}` directory
 * name from the path, split it into domain + doctype, and accumulate every
 * documents file's parsed entries into one `documents` array on the descriptor.
 */
function collect(
	defGlob: Record<string, string>,
	docsGlob: Record<string, string>,
	scriptsGlob: Record<string, string>,
	requireDefinition: boolean
): DirDescriptor[] {
	const out: Map<string, DirDescriptor> = new Map();

	for (const [path, raw] of Object.entries(defGlob)) {
		const parsed = parseDirName(path);
		if (!parsed) continue;
		out.set(parsed.key, {
			domain: parsed.domain,
			doctype: parsed.doctype,
			defRaw: raw,
			docsRawList: [],
			documents: []
		});
	}

	for (const [path, raw] of Object.entries(docsGlob).sort(([a], [b]) => a.localeCompare(b))) {
		const parsed = parseDirName(path);
		if (!parsed) continue;
		// Skip definition files and Lua scripts — they take separate glob paths.
		if (!isDocumentsFile(path, parsed.key)) continue;
		let existing = out.get(parsed.key);
		if (!existing) {
			if (requireDefinition) continue;
			existing = {
				domain: parsed.domain,
				doctype: parsed.doctype,
				docsRawList: [],
				documents: []
			};
			out.set(parsed.key, existing);
		}
		existing.docsRawList.push(raw);
		existing.documents.push(...rewriteSeedChildIds(parseDocuments(raw), parsed.doctype));
	}

	for (const [path, raw] of Object.entries(scriptsGlob)) {
		const parsed = parseDirName(path);
		if (!parsed) continue;
		const existing = out.get(parsed.key);
		if (existing) {
			existing.scriptRaw = raw;
		} else {
			// Script without a definition — shouldn't normally happen but be lenient
			out.set(parsed.key, {
				domain: parsed.domain,
				doctype: parsed.doctype,
				docsRawList: [],
				documents: [],
				scriptRaw: raw
			});
		}
	}

	return [...out.values()];
}

/**
 * Returns true if `path` is a documents file (not a definition file or script).
 * `path` looks like `../data/fixtures/<dir>/<file>.yml`.
 */
function isDocumentsFile(path: string, _dirKey: string): boolean {
	const file = path.slice(path.lastIndexOf('/') + 1);
	if (file === 'script.lua') return false;
	if (file.startsWith('definition.')) return false;
	const ext = file.slice(file.lastIndexOf('.') + 1);
	return ext === 'yml' || ext === 'yaml' || ext === 'json';
}

/** Parse `../data/<kind>/<domain>.<Doctype>/<file>.yml` or `../data/<kind>/<domain>.<Doctype>/<file>.lua` into its parts. */
function parseDirName(path: string): { key: string; domain: string; doctype: string } | null {
	const m = path.match(/\/data\/(?:fixtures|seeds)\/([^/]+)\/[^/]+\.(?:yml|yaml|json|lua)$/);
	if (!m) return null;
	const dir = m[1];
	const dot = dir.indexOf('.');
	if (dot < 1 || dot === dir.length - 1) return null;
	return { key: dir, domain: dir.slice(0, dot), doctype: dir.slice(dot + 1) };
}

// ── Portable-domain bundle loading ─────────────────────────────────────────
//
// The bundle layout is documented at the top of this file. The loader does not
// need `bundle.yml` to enumerate bundles — the presence of `domain.yml` (one
// per bundle root) is the canonical "this directory is a bundle" signal, and
// `facet domain:export` always writes `domain.yml` first. A non-bundle
// directory under `data/fixtures/` with no `domain.yml` is silently ignored.
//
// Id reconstruction: the bundle entry files never embed the projection id in
// `content` or `meta` (the backend import mints fresh ULIDs for view children).
// The frontend mock driver, however, resolves children by id-prefix convention
// (e.g. `crm.Deal.document_view.*`), so the loader reconstructs the legacy
// stable ids from the bundle's file paths:
//
//   - `doctypes/{Qualified}.yml`         → id = filename stem (`crm.Deal`)
//   - `documents/{Qualified}/{doc_id}.yml` → id = filename stem (`crm.Deal.1`)
//   - `views/{Q}/collection_views/{slug}.yml` → id = filename stem (the slug
//     is the full id, e.g. `crm.Deal.collection_view.all`)
//   - `views/{Q}/document_views/{kind}.yml`  → id = `{Q}.document_view.{kind}`
//     (the bundle stores only `kind` as the filename; the frontend child-prefix
//     convention requires the full qualified id)
//   - `domain.yml`                        → id = bundle's source domain name

/** A raw entry paired with the id reconstructed from its path. */
interface IdEntry {
	id: string;
	/** Glob path of the source YAML file (e.g. `../data/fixtures/.../doctypes/crm.Deal.yml`), used as the `!read_file` jail root. */
	path: string;
	raw: string;
}

interface BundleEntry {
	/** The bundle's source domain (also the `core.Domain` id). */
	domain: string;
	/** Glob path of the bundle's `domain.yml` (the `!read_file` jail root for that entry). */
	domainPath: string;
	/** Raw `domain.yml` content (the `core.Domain` document `{content, meta}`). */
	domainYml: string;
	/** Doctype entries keyed by qualified id (`{domain}.{Doctype}`). */
	doctypes: Map<string, IdEntry>;
	/** Document-view entries keyed by parent qualified doctype. */
	documentViews: Map<string, IdEntry[]>;
	/** Collection-view entries keyed by parent qualified doctype. */
	collectionViews: Map<string, IdEntry[]>;
	/** User documents keyed by qualified doctype. */
	documents: Map<string, IdEntry[]>;
}

/**
 * Collect every portable-domain bundle under `data/fixtures/` into an
 * in-memory model. A directory is treated as a bundle when it contains a
 * `domain.yml`; the `bundle.yml` marker is not consulted (its only fields are
 * `format_version`, `source_domain`, `exported_at`, `facet_version`, none of
 * which the frontend mock driver needs).
 */
function collectBundles(): BundleEntry[] {
	const byDomain = new Map<string, BundleEntry>();

	// 1. Seed one BundleEntry per `domain.yml` found.
	for (const path of Object.keys(fixtureDomainEntries)) {
		const domain = bundleDomainOf(path);
		if (!domain) continue;
		byDomain.set(domain, {
			domain,
			domainPath: path,
			domainYml: fixtureDomainEntries[path],
			doctypes: new Map(),
			documentViews: new Map(),
			collectionViews: new Map(),
			documents: new Map()
		});
	}

	// 2. Attach doctypes. The filename stem is the qualified doctype id.
	for (const [path, raw] of Object.entries(fixtureDoctypesDir)) {
		const domain = bundleDomainOf(path);
		const qualified = basenameWithoutExt(path);
		if (!domain || !qualified) continue;
		byDomain.get(domain)?.doctypes.set(qualified, { id: qualified, path, raw });
	}

	// 3. Attach document views. The filename stem is the `kind`; the frontend
	//    child-prefix convention requires the full id `{parent}.document_view.{kind}`.
	for (const [path, raw] of Object.entries(fixtureDocumentViews)) {
		const { domain, parent } = bundleViewParentOf(path) ?? {};
		const kind = basenameWithoutExt(path);
		if (!domain || !parent || !kind) continue;
		const entry = byDomain.get(domain);
		if (!entry) continue;
		const id = `${parent}.document_view.${kind}`;
		const list = entry.documentViews.get(parent) ?? [];
		list.push({ id, path, raw });
		entry.documentViews.set(parent, list);
	}

	// 4. Attach collection views. The filename stem IS the full id (the export
	//    sanitises the slug from the projection id, so it round-trips).
	for (const [path, raw] of Object.entries(fixtureCollectionViews)) {
		const { domain, parent } = bundleViewParentOf(path) ?? {};
		const id = basenameWithoutExt(path);
		if (!domain || !parent || !id) continue;
		const entry = byDomain.get(domain);
		if (!entry) continue;
		const list = entry.collectionViews.get(parent) ?? [];
		list.push({ id, path, raw });
		entry.collectionViews.set(parent, list);
	}

	// 5. Attach user documents. The filename stem is the document id.
	for (const [path, raw] of Object.entries(fixtureDocuments)) {
		const { domain, qualified } = bundleDocumentDoctypeOf(path) ?? {};
		const id = basenameWithoutExt(path);
		if (!domain || !qualified || !id) continue;
		const entry = byDomain.get(domain);
		if (!entry) continue;
		const list = entry.documents.get(qualified) ?? [];
		list.push({ id, path, raw });
		entry.documents.set(qualified, list);
	}

	return [...byDomain.values()];
}

/** Extract the bundle's domain name from a glob path whose first segment under `data/fixtures/` is `{domain}.facet-domain`. */
function bundleDomainOf(path: string): string | null {
	const m = path.match(/\/data\/fixtures\/([^/]+)\.facet-domain\//);
	return m ? m[1] : null;
}

/** Parse a `views/<parent>/document_views|collection_views/<file>.yml` path into its bundle domain and parent qualified doctype. */
function bundleViewParentOf(path: string): { domain: string; parent: string } | null {
	const m = path.match(
		/\/data\/fixtures\/([^/]+)\.facet-domain\/views\/([^/]+)\/(?:document_views|collection_views)\//
	);
	if (!m) return null;
	return { domain: m[1], parent: m[2] };
}

/** Parse a `documents/<qualified>/<doc_id>.yml` path into its bundle domain and qualified doctype. */
function bundleDocumentDoctypeOf(path: string): { domain: string; qualified: string } | null {
	const m = path.match(/\/data\/fixtures\/([^/]+)\.facet-domain\/documents\/([^/]+)\//);
	if (!m) return null;
	return { domain: m[1], qualified: m[2] };
}

/** Strip the directory and `.yml` extension from a path. */
function basenameWithoutExt(path: string): string | null {
	const slash = path.lastIndexOf('/');
	const file = slash >= 0 ? path.slice(slash + 1) : path;
	const dot = file.lastIndexOf('.');
	if (dot <= 0) return null;
	return file.slice(0, dot);
}

/**
 * Flatten every collected bundle into the `FixtureEntity[]` shape consumed by
 * `applyFixtures`. One entity per user doctype (definition + documents), plus
 * three aggregate entities assembled across all bundles:
 *
 * - `core.Domain` — one document per bundle's `domain.yml`.
 * - `core.DocumentView` — every `document_views/*.yml` entry across bundles.
 * - `core.CollectionView` — every `collection_views/*.yml` entry across bundles.
 *
 * The aggregate entities carry no `definition` (the seed loader provides the
 * core-doctype definitions), matching the legacy fixture format.
 */
function bundlesToEntities(bundles: BundleEntry[]): FixtureEntity[] {
	const entities: FixtureEntity[] = [];
	const domainDocs: { id: string; content: Record<string, unknown> }[] = [];
	const documentViewDocs: { id: string; content: Record<string, unknown> }[] = [];
	const collectionViewDocs: { id: string; content: Record<string, unknown> }[] = [];

	for (const bundle of bundles) {
		// core.Domain document — the bundle's `domain.yml` is a single
		// `{ content, meta }` entry whose projection id is the domain name.
		const domainContent = parseEntryContent(bundle.domainYml, bundle.domainPath);
		if (domainContent) {
			domainDocs.push({ id: bundle.domain, content: domainContent });
		}

		// One FixtureEntity per user doctype. The doctype entry's `content` IS
		// the doctype definition (the same record the backend's
		// `DoctypeDefinition.from_json` parses); its `meta.parent_id` is the
		// owning domain. Documents under `documents/<qualified>/` are the
		// doctype's seed rows.
		for (const [qualified, entry] of bundle.doctypes) {
			const dot = qualified.indexOf('.');
			if (dot < 1) continue;
			const domain = qualified.slice(0, dot);
			const doctype = qualified.slice(dot + 1);

			const definition = parseEntryContent(entry.raw, entry.path);
			if (!definition) continue;

			const docEntries = bundle.documents.get(qualified) ?? [];
			const documents = docEntries
				.map((d) => {
					const content = parseEntryContent(d.raw, d.path);
					return content ? { id: d.id, content } : null;
				})
				.filter((d): d is { id: string; content: Record<string, unknown> } => d !== null);

			entities.push({ domain, doctype, definition, documents });
		}

		// Aggregate `core.DocumentView` entries from every bundle's views tree.
		for (const list of bundle.documentViews.values()) {
			for (const entry of list) {
				const content = parseEntryContent(entry.raw, entry.path);
				if (content) documentViewDocs.push({ id: entry.id, content });
			}
		}

		// Aggregate `core.CollectionView` entries likewise.
		for (const list of bundle.collectionViews.values()) {
			for (const entry of list) {
				const content = parseEntryContent(entry.raw, entry.path);
				if (content) collectionViewDocs.push({ id: entry.id, content });
			}
		}
	}

	// The three aggregate entities are appended after the per-doctype entities.
	// Order does not matter to `applyFixtures` — it registers definitions and
	// seeds documents per entity; cross-entity references resolve at read time.
	if (domainDocs.length > 0) {
		entities.push({ domain: 'core', doctype: 'Domain', documents: domainDocs });
	}
	if (documentViewDocs.length > 0) {
		entities.push({ domain: 'core', doctype: 'DocumentView', documents: documentViewDocs });
	}
	if (collectionViewDocs.length > 0) {
		entities.push({
			domain: 'core',
			doctype: 'CollectionView',
			documents: collectionViewDocs
		});
	}

	return entities;
}

// ── Entry parsing ─────────────────────────────────────────────────────────

/**
 * Build a `js-yaml` schema whose `!read_file` tag handler expands a scalar to
 * the literal contents of the file it references. *sourcePath* is the glob
 * path of the YAML file currently being parsed (e.g.
 * `../data/fixtures/crm.facet-domain/doctypes/crm.Activity.yml`); it is the
 * jail root for the reference, mirroring `Facet::Util::YamlInclude`.
 *
 * The referenced file must live inside the YAML file's own directory or one of
 * its descendants (no `..` segment). The contents are resolved through the
 * `fixtureLuaSidecars` glob map — Vite transforms bundle files at build time,
 * so there is no runtime `fs` access (the mock loader must work in the browser
 * and under Storybook/vitest). A reference to a file the glob did not capture
 * is rejected with the same `not found` message as the backend.
 */
function readFileSchema(sourcePath: string): Schema {
	// Normalise the jail root: the YAML file's directory, with no trailing slash,
	// so a prefix check unambiguously matches descendants and rejects siblings.
	// The glob keys are POSIX-style relative paths starting with `../`.
	const sep = '/';
	const lastSlash = sourcePath.lastIndexOf(sep);
	const jailDir = lastSlash < 0 ? '' : sourcePath.slice(0, lastSlash);
	const jailPrefix = jailDir === '' ? '' : jailDir + sep;

	const readFileTag = defineScalarTag('!read_file', {
		resolve: (ref: string) => {
			if (ref === '') {
				throw new Error(`${sourcePath}: !read_file referenced an empty path`);
			}
			// Layer 1 — lexical rejection of any `..` segment, mirroring the
			// backend's strict jail rule (a `..` segment is forbidden outright,
			// even when it would otherwise resolve inside the bundle).
			const parts = ref.split('/');
			if (parts.includes('..')) {
				throw new Error(
					`${sourcePath}: !read_file '${ref}' escapes the YAML directory (contains '..')`
				);
			}
			// Layer 2 — resolve relative to the YAML file's directory and confirm
			// the result stays inside the jail. Absolute refs are rejected because
			// they would bypass the relative-to-`jailDir` semantics.
			if (ref.startsWith('/')) {
				throw new Error(
					`${sourcePath}: !read_file '${ref}' is absolute — only relative paths are allowed`
				);
			}
			const target = jailDir === '' ? ref : `${jailDir}${sep}${ref}`;
			if (!target.startsWith(jailPrefix) && target !== jailDir) {
				throw new Error(`${sourcePath}: !read_file '${ref}' escapes the YAML directory ${jailDir}`);
			}
			const contents = fixtureLuaSidecars[target];
			if (contents === undefined) {
				throw new Error(`${sourcePath}: !read_file '${ref}' not found (resolved to ${target})`);
			}
			return contents;
		}
	});

	return YAML11_SCHEMA.withTags(readFileTag);
}

/**
 * Parse a single bundle entry file's `content` mapping. Every entry file is a
 * YAML mapping with `content` and `meta` keys; only `content` is needed by the
 * frontend mock driver (the id is reconstructed from the file path by the
 * caller). *sourcePath* is the glob path of the entry file, used as the jail
 * root for `!read_file` expansion (see `readFileSchema`). Returns null when the
 * entry is malformed.
 */
function parseEntryContent(raw: string, sourcePath: string): Record<string, unknown> | null {
	const parsed = yamlLoad(raw, { schema: readFileSchema(sourcePath) }) as {
		content?: Record<string, unknown>;
	} | null;
	if (!parsed || !parsed.content) return null;
	return parsed.content;
}

/**
 * Seed directories of the two view meta-doctypes hold *child* rows — entries
 * with `meta.parent_id` linking them to their parent `core.DocType` row (the
 * backend seeds them as ordinary documents with the meta override). The mock
 * driver resolves child collections by the `{parent}.{rel}.*` id-prefix
 * convention, so the loader rewrites each entry's id to
 * `{parent}.{rel}.{key}` and drops the now-inert meta bag — the same
 * reconstruction `bundlesToEntities` performs for portable bundles.
 */
const VIEW_META_DOCTYPE_RELS: Record<string, string> = {
	DocumentView: 'document_view',
	CollectionView: 'collection_view'
};

const SEEDS: DirDescriptor[] = collect(seedDefs, seedDocs, seedScripts, false);

// ── Loaders ─────────────────────────────────────────────────────────────────

/**
 * Parse a raw YAML string into a Record.
 */
function parseDefinition(raw: string): Record<string, unknown> {
	return yamlLoad(raw) as Record<string, unknown>;
}

/**
 * Parse a raw YAML documents string into an array of `{ id, content }` entries.
 *
 * Returns an empty array if no documents were provided.
 */
function parseDocuments(raw?: string): { id: string; content: Record<string, unknown> }[] {
	if (!raw) return [];
	const parsed = yamlLoad(raw) as { id: string; content: Record<string, unknown> }[];
	return parsed ?? [];
}

function rewriteSeedChildIds(
	docs: { id: string; content: Record<string, unknown> }[],
	doctype: string
): { id: string; content: Record<string, unknown> }[] {
	const rel = VIEW_META_DOCTYPE_RELS[doctype];
	if (!rel) return docs;
	// The parsed entries may carry the raw `meta` bag alongside `id`/`content`.
	return docs.map((entry) => {
		const e = entry as {
			id: string;
			content: Record<string, unknown>;
			meta?: Record<string, unknown>;
		};
		const parent = e.meta?.['parent_id'];
		if (typeof parent !== 'string' || parent === '') return { id: e.id, content: e.content };
		const key = e.id.startsWith(parent + '.') ? e.id.slice(parent.length + 1) : e.id;
		return { id: `${parent}.${rel}.${key}`, content: e.content };
	});
}

/**
 * Load all fixture entities from `data/fixtures/*.facet-domain/` bundles.
 */
export function loadFixtures(): FixtureEntity[] {
	return bundlesToEntities(collectBundles());
}

/**
 * Load all seed entities from `data/seeds/`.
 */
export function loadSeeds(): FixtureEntity[] {
	return SEEDS.map(toFixtureEntity);
}

// ── Seed helper ─────────────────────────────────────────────────────────────

/**
 * Apply an array of fixture entities to a MockDataDriver.
 *
 * For each entity:
 * 1. Register the doctype definition (if provided).
 * 2. Seed documents (if any) into the appropriate domain/doctype DataSource.
 */
export function applyFixtures(driver: MockDataDriver, entities: FixtureEntity[]): void {
	for (const entity of entities) {
		// Register the definition if present (absent for core doctypes defined in seeds)
		if (entity.definition) {
			driver.registerDoctype(entity.domain, entity.doctype, entity.definition);
		}

		// Skip if there are no documents to seed
		if (entity.documents.length === 0) continue;

		// Seed documents. The second argument is the seed data — it will only
		// be applied on the first call to doctype() because MockDomain caches.
		driver.domain(entity.domain).doctype(
			entity.doctype,
			entity.documents.map((d) => ({ id: d.id, ...d.content }))
		);
	}
}
