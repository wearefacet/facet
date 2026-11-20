# Fixtures

**Directory:** `data/fixtures/`

Fixtures store **doctype definitions** and **seed documents** for use by both the backend test suite and the frontend Storybook/component tests. They are stored as **portable-domain bundles** — the same format produced by `facet domain:export --with-documents`. Each bundle is one domain.

The dev database is populated by importing these bundles with `domain:import` (see [Backend (dev database)](#backend-dev-database)). The same on-disk tree is read directly by specs and by the frontend mock driver — the data is never copied.

---

## Format

A fixture bundle is a directory `data/fixtures/{domain}.facet-domain/` with this layout:

```
{domain}.facet-domain/
  bundle.yml                       # Format metadata (format_version, source_domain, exported_at, facet_version)
  domain.yml                       # { content, meta } — the core.Domain document for this domain
  doctypes/{Qualified}.yml         # { content, meta } — one per user doctype; content IS the definition
  views/{qualified}/
    document_views/{kind}.yml      # { content, meta } — core.DocumentView children (one per kind)
    collection_views/{slug}.yml    # { content, meta } — general core.CollectionView children
  documents/{qualified}/{doc_id}.yml  # { content, meta } — one per user document
```

### Entry file shape

Every `*.yml` entry file (except `bundle.yml`) is a YAML mapping with two keys:

| Key | Description |
|---|---|
| `content` | The document's JSON content (a YAML mapping that parses to the same JSON the HTTP API would return in `data`). For a doctype entry, this IS the doctype definition (including any embedded Lua `script`). |
| `meta` | The document's meta. For composition children (`core.DocType`, `core.DocumentView`, `core.CollectionView`, etc.) this carries `parent_id`. |

### Document ids

The bundle does **not** embed the document id inside the entry's `content` or `meta`. Instead, the id is the **filename stem** of the entry file:

| Entry path | Document id |
|---|---|
| `documents/{Qualified}/{doc_id}.yml` | `{doc_id}` |
| `doctypes/{Qualified}.yml` | `{Qualified}` |
| `views/{Q}/collection_views/{slug}.yml` | `{slug}` (the full id — export sanitises the slug from the id) |
| `views/{Q}/document_views/{kind}.yml` | `{Q}.document_view.{kind}` (reconstructed — the bundle stores only `kind`) |
| `domain.yml` | the bundle's `{source_domain}` name |

`DocumentView` ids follow the `{parentQualifiedId}.document_view.{kind}` convention so the frontend mock driver can resolve them as composition children by id-prefix (`{parentId}.document_view.`).

### The `!read_file` directive

Entry YAML files may pull a value from a separate file with the `!read_file` tag. The most common use is a doctype's Lua `script`: instead of inlining the lifecycle script as a YAML literal block inside `doctypes/{Qualified}.yml`, the script lives in a co-located `doctypes/{Qualified}.lua` file and the doctype entry references it:

```yaml
content:
  doctype: Deal
  domain: crm
  fields: { ... }
  script: !read_file crm.Deal.lua
meta:
  parent_id: crm
```

Resolution rules:

- **Text substitution, not composition.** The referenced file's literal bytes become the scalar value. The file is *never* parsed as YAML — so a Lua script containing `:` or `-` survives verbatim.
- **Path semantics.** The reference is interpreted relative to the directory of the YAML file that declares `!read_file`.
- **Jail.** Every resolved target must stay inside the **YAML file's own directory** or one of its descendants. Any reference that escapes — via a `..` segment, an absolute path, or a symlink pointing outside — is rejected with `Util::YamlInclude::IncludeError`. This is stricter than a "stay inside the bundle" rule: a `doctypes/crm.Deal.yml` may `!read_file crm.Deal.lua` (a sibling) or `!read_file fragments/x.lua` (a descendant), but never `!read_file ../scripts/anything.lua`.
- **Reader coverage.** The directive is honoured by every code path that parses a bundle entry file: the production `Facet::Domain::Portable::Archive` reader (used by `domain:import`), and the spec helpers `parse_bundle_entry` / `load_doctype_schema`. `DoctypeDefinition.from_yaml(string)` does **not** expand `!read_file` — it has no file context.
- **Exports externalize scripts.** The export writer (`facet domain:export`) emits `!read_file` references for definition scripts instead of inlining them: a doctype's lifecycle `script` becomes a co-located `doctypes/{Qualified}.lua` sidecar, and each domain hook's `script` becomes a `hooks/{i}-{hook_id}.lua` sidecar. The reader expands these back to the file contents on import, so the round-trip is lossless. Document and view content stays inline — only definition scripts externalize.

The implementation lives in `src/util/yaml_include.cr` (`Facet::Util::YamlInclude`).

### The `!env` tag

The same module also resolves the `!env NAME` tag, which expands a scalar to the value of the environment variable *NAME*. It is used by `Facet::Config.load` for `config.{env}.yml` — **not** by fixture bundles. `parse_file` rejects `!env` outright in bundle YAML: bundle content is untrusted authoring input, and env expansion there would let an imported bundle exfiltrate secrets. A missing variable raises `Util::YamlInclude::IncludeError` at parse time. See [`backend/config.md`](backend/config.md) for the full contract.

### Why the bundle format (not the legacy `{domain}.{Doctype}/` tree)

Previous versions stored fixtures as one directory per doctype (`{domain}.{Doctype}/{definition.yml, documents.yml, script.lua}`). This was a bespoke format that diverged from the production import/export tool: a fixture could only be loaded by `Doctype::FixtureSeed`, not by `domain:import`, and the two code paths could drift. The bundle format is identical to what `facet domain:export --with-documents` produces for a live database, so fixtures are round-trippable with production data and loaded by the same importer.

---

## Fixture inventory

### `hr` — Recruiting

| Doctype | Documents |
|---|---|
| `hr.Candidate` | 1 candidate (Amara Okonkwo) with rich edge cases: nulls, emoji, nested objects, markdown, `$ref`-style references, cross-doctype links |
| `hr.CandidateExperience` | 3 work experiences |
| `hr.CandidateEducation` | 1 education entry |
| `hr.CandidateSkill` | 5 skills (languages, tools, soft skills) |
| `hr.InterviewFeedback` | 2 interview feedbacks |
| `hr.Employee` | 2 employees with manager hierarchy and computed field schemas |
| `hr.CareerEvent` | 4 career events across 2 employees |

### `identity`

| Doctype | Documents |
|---|---|
| `identity.Person` | 2 person records (referenced by Employee) |

### `crm` — Customer relationship management

| Doctype | Documents |
|---|---|
| `crm.Company` | 3 companies (Acme Corp, Globex Inc, Initech) |
| `crm.Contact` | 3 contacts across companies |
| `crm.Deal` | 3 deals in various pipeline stages |
| `crm.Activity` | 3 activities (meeting, email, call) |
| `crm.Customer` | 1 customer (Acme Corp) |
| `crm.PipelineStage` | 6 pipeline stages (Prospecting → Closed Won/Lost) |
| `crm.Prospect` | 1 prospect (Initech) |

### `production`

| Doctype | Documents |
|---|---|
| `production.Team` | 2 teams (Platform, Growth) — aggregate root for `TeamMember` children |
| `production.TeamMember` | 4 memberships linking accounts to teams (child of `Team`) |
| `production.Project` | 4 projects across the two teams — carries the `tasks` children collection and a `create` lifecycle script that demonstrates `ctx.actor` (forces `owner_id` to the caller when the create permission is scoped `$mine`) |
| `production.Task` | 4 tasks across projects (child of `Project`) |

The `production` domain entry in `core.Domain` defines a `my_teams` RBAC context set: it resolves the teams a caller belongs to by selecting `$parent_id` from `production.TeamMember` rows where `account = $self`. See [`doc/backend/rbac.md`](backend/rbac.md) for the full scoping mechanism.

### `ops`

| Doctype | Documents |
|---|---|
| `ops.MaintenanceTask` | Maintenance tasks (demo doctype for the calendar / ops surfaces) |

### `iam`

| Doctype | Documents |
|---|---|
| `iam.Account` | 4 fixture accounts (Kim Nguyen, Dao Chen, Alex Okafor, Sam Rivers) — the dev admin is NOT in the bundle (see [Regenerating the bundles](#regenerating-the-bundles)) |
| `iam.Roles` | 4 role documents (`admin`, `editor`, `viewer` — wildcard permissions — and `production_editor`, whose permissions carry `$mine` scopes on `production.*` doctypes). The `production` bundle must import before `iam` — see [Backend (dev database)](#backend-dev-database). |

### Core documents carried per bundle

Every bundle carries these `core.*` documents as part of its domain definition — they are not separate fixtures:

| Doctype | Where in the bundle |
|---|---|
| `core.Domain` | `domain.yml` (the bundle's own domain row) |
| `core.DocType` | `doctypes/{Qualified}.yml` (one per user doctype in this domain) |
| `core.DocumentView` | `views/{qualified}/document_views/{kind}.yml` (the standard set per doctype: `view`, `form`, `quickView`, `card`, plus `inline` for child doctypes) |
| `core.CollectionView` | `views/{qualified}/collection_views/{slug}.yml` (general shared views) |

---

## Usage

### Frontend (Storybook / component tests)

The frontend reads fixture bundles directly — no copy is made into a separate mock store. The mock data source's loader parses `data/fixtures/*.facet-domain/`, reconstructs document ids from the entry-file paths (see [Document ids](#document-ids)), and registers every doctype definition + document in an in-memory driver. Production frontend code never touches fixtures; only the mock data source (used by Storybook and Vitest component specs) does.

```ts
import { createMockDriver } from '$lib/datasource/mock-seed.js';

const driver = createMockDriver();

// Doctype definitions are registered — look up schema metadata:
const def = driver.getDoctypeDefinition('hr.Candidate');

// Documents are seeded in the usual domain/doctype DataSources:
const candidates = driver.domain('hr').doctype('Candidate');
const list = await candidates.list();
```

The global driver is also available in Storybook via `mockDriver` export from `.storybook/preview.ts`.

### Backend (Crystal specs)

Specs read bundle entries via helpers in [`spec/support/fixture_helper.cr`](../../spec/support/fixture_helper.cr):

```crystal
require "../support/fixture_helper"

# Load a doctype definition from a fixture bundle.
defn = load_fixture_definition("hr", "Candidate")
defn.fields.keys # => ["full_name", "email", "status", ...]

# Load every document of a fixture doctype. Each entry's id is taken
# from the bundle filename stem (the content does not embed it).
docs = load_fixture_documents("hr", "Candidate")
docs.first[:id]      # => "cand_01HZX9Q2"
docs.first[:content] # => JSON string

# Cross-bundle aggregates:
load_fixture_domains              # every core.Domain row (one per bundle)
load_fixture_document_views      # every core.DocumentView entry across all bundles
load_fixture_collection_views    # every core.CollectionView entry across all bundles

# Seed helpers (legacy per-doctype directory format) are unchanged:
core_defn = load_seed_definition("core", "DocType")
```

### Backend (dev database)

The dev database is bootstrapped by `db_reset` + `seed:dev` (which creates the dev admin), then the fixture bundles are imported:

```bash
# Full dev bootstrap (migrations + core seeds + dev admin + fixtures):
scripts/facet db_reset seed:dev
scripts/import-fixtures
```

`scripts/import-fixtures` imports the bundles in a fixed dependency order — `crm`, `hr`, `identity`, `ops`, `production`, `iam` — in one `facet domain:import` call with `--merge`. The order is load-bearing: the import authoring gate (B-277) validates every bundled `iam.Roles` row's scope aliases against the registered doctypes, and `iam.Roles.production_editor` scopes on `production.*`. A missing target domain (every domain except `iam` after the bootstrap chain) is created fresh — a new `core.Domain` + its doctypes + its documents. An existing target (`iam`, pre-created by `seed:dev`'s admin bootstrap) is merged: every doctype is version-gated (unchanged since identical), `DocumentView` / `CollectionView` children are reconciled, and documents that already exist on `(domain, doc_type, id)` are skipped. The script errors on a bundle directory missing from the order list — adding a bundle means adding it to `$ordered` in the script.

The dev admin (`admin@example.tld` / `admin`, no MFA) is NOT in the `iam` bundle — `seed:dev` creates it (`db_reset` alone creates no account). See [Regenerating the bundles](#regenerating-the-bundles) for why.

Import is idempotent: re-running `scripts/import-fixtures` is a no-op on rows that already match.

---

## Regenerating the bundles

The bundles in `data/fixtures/` are checked-in artifacts. To regenerate them after changing fixture data:

```bash
# 1. Reset the database and import the current bundles (so the live DB
#    reflects the fixture set you want to re-export).
scripts/facet db_reset seed:dev
scripts/import-fixtures

# 2. The bootstrap chain ends with the dev admin (seed:dev creates
#    admin@example.tld). The iam bundle MUST NOT carry the admin — it would
#    collide with the admin that every fresh `db_reset seed:dev` re-creates. Delete it:
psql $DATABASE_URL -c "DELETE FROM projections WHERE domain='iam' AND doc_type='Account' AND content->>'email' = 'admin@example.tld';"

# 3. Re-export every fixture domain into data/fixtures/.
scripts/facet domain:export crm,hr,identity,ops,production,iam --with-documents --output-dir data/fixtures
```

Step 2 is mandatory: the bootstrap chain always ends with the dev admin (`seed:dev` creates it in `src/iam/seed.cr`). Exporting iam without deleting the admin first would either collide on the unique `email` index (when imported into a fresh DB that already has the admin) or duplicate the admin without its `auth_secrets` row.

After regeneration, run `scripts/facet db_reset seed:dev && scripts/import-fixtures` against a fresh DB and verify the dev admin can still log in.

---

## Fixture validation

All fixture documents are validated against their doctype definitions by the spec at `spec/fixtures_spec.cr`. This spec:

1. Loads every fixture definition and its documents (via the bundle helpers in `spec/support/fixture_helper.cr`).
2. Validates each document using `Document::Validation` (required fields, types, enum values, unknown fields).
3. For core-only fixtures (those without a fixture doctype definition — `core.Domain`, `core.DocumentView`, `core.CollectionView`, `iam.Account`), validates against the seed definition from `data/seeds/`.

This catches schema drift — if a fixture document gains a field not in the definition, or a required field is removed, the spec fails.

Run it with:

```bash
crystal spec spec/fixtures_spec.cr
```

### Composition consistency (frontend)

The frontend spec at `frontend/src/lib/datasource/fixtures.composition.spec.ts` validates the composition graph across both `data/fixtures/` and `data/seeds/` definitions (loaded together via `createMockDriver()`). It enforces two rules:

1. **member_of reciprocity** — a child declaring `member_of` must have the parent declare a matching `children:` entry (same domain). The reverse is not required: the children-only spelling (parent declares `children:`, child has no `member_of`, e.g. `crm.Contact`) is a valid pattern, so a `children:` entry with a member_of-less child is not flagged.
2. **No parent→child reference fields** — a doctype must not declare a `reference` (or array-of-reference) field whose target is one of its own composition children; such relationships should be modelled via `children:` instead. Child→parent back-references (e.g. `Contact.company_id` → `crm.Company`) are allowed.

Run it with:

```bash
cd frontend && pnpm exec vitest run src/lib/datasource/fixtures.composition.spec.ts
```

---

## Relationship to `data/seeds/`

- **`data/seeds/`** — core system doctypes needed for bootstrapping (e.g. `core.DocType`, `core.Domain`, `iam.Roles`). Stored as per-doctype directories (`{domain}.{Doctype}/` with `definition.yml`, optional `script.lua`, optional `documents.yml`). Seeded into the database on `db_reset` by `Facet::Doctype::Seed`.
- **`data/fixtures/`** — test/dev data with rich schemas and realistic documents. Stored as portable-domain bundles. Loaded by specs and Storybook directly from the bundle tree; loaded into the dev database by `scripts/import-fixtures`. **Not** seeded automatically during `db_reset`.

The two use different on-disk formats (seeds keep the per-doctype directory layout for the bootstrapper; fixtures use the portable-domain bundle so they round-trip with `domain:export`/`domain:import`). The spec helpers in `spec/support/fixture_helper.cr` know how to read both.
