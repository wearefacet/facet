# Search — cross-doctype record search

The global record-search engine behind the command palette (see [`../frontend/command-palette.md`](../frontend/command-palette.md)), the `@` picker escalation, and any future consumer that must find documents without knowing their doctype first. One term, every readable searchable doctype of a scope, one ranked response.

## Source files

- [`src/search.cr`](../../src/search.cr) — the concern hub (requires the modules below)
- [`src/search/routes.cr`](../../src/search/routes.cr) — `Search::Routes`, the GET + QUERY route pair
- [`src/search/query.cr`](../../src/search/query.cr) — `Search::Query`, contribution enumeration + statement builder + fan-out merge
- [`src/database.cr`](../../src/database.cr) — `Database.group_by_database`, the route-table grouping the fan-out consumes
- [`spec/search/`](../../spec/search/) — the specs (transport pair, RBAC branches, root resolution, fan-out)

## Routes

Two scopes, each in the GET + QUERY pair the list surfaces use — one handler, two transports:

| Method | Route | Scope |
| --- | --- | --- |
| `GET` / `QUERY` | `/Api/:domain/search` | one domain |
| `GET` / `QUERY` | `/Api/search` | the whole application (fan-out) |

- **GET** reads `q` from the query string, merged with a JSON body `{"q": ...}` when present — the query string wins, every other body key is ignored (the list-route merge rule).
- **QUERY** is body-only under the shared `Gates` contract (`Gates.query_body_json`): any query-string parameter → `422`, non-JSON media type → `415`, non-object body → `422`, empty body → defaults. Both forms answer `Accept-Query: application/json`.
- The literal `search` segment takes precedence over the `:doctype` parameter (static-over-param, the same precedence the `Audit` / `Artifacts` routes exercise). `search` sits in the `DomainGate` reserved segments, so the app-wide route is not domain-gated; the domain-scoped route keeps normal domain gating.

## Contract

One parameter today: `q`. A term shorter than 2 characters (after strip), or missing, answers `200` with an empty result — never an error; the client gates the same way before calling. Response caps are server-side module constants, not request parameters:

| Constant | Value | Purpose |
| --- | --- | --- |
| `MIN_TERM_LENGTH` | 2 | shorter terms answer empty |
| `PER_DOCTYPE_CAP` | 5 | matches per doctype branch |
| `OVERALL_CAP` | 25 | hits in the response |
| `MAX_COMPOSITION_DEPTH` | 8 | child → root walk bound |

The response is the standard envelope. `data` holds per-doctype groups in rank order:

```json
{ "data": [ { "domain": "hr", "doctype": "Employee", "hits": [
    { "id": "01J…", "display_name": "Ada Lovelace", "rank": 0.83,
      "root_doctype": "Employee", "root_id": "01J…",
      "root_display_name": "Ada Lovelace", "child_label": null } ] } ],
  "meta": { "q": "ada", "count": 1, "scope": "domain" } }
```

`scope` is `"domain"` or `"app"`. Every hit carries a root anchor; for a hit on a root doctype the anchor is the hit itself and `child_label` is null. The response carries labels only — never document `content` — so no field-maskable value leaves the server and the field-level read mask needs no per-row application here.

## The searchability flag

A doctype joins search only when its definition declares a non-empty `search` template. The template is the opt-in: internal doctypes stay out of every search surface by not declaring one. A template-less doctype contributes no branch on this endpoint and in the agent tools.

A `search` template may use the reserved `{{ display_name }}` variable — the document's display label. A `display_name` template cannot use it: the validator rejects the self-reference at authoring time.

On the raw list API, a doctype with no `search` template keeps a searchable corpus: the write path stages the folded `display_name` through the same whitespace-normalise → accent-fold → truncate pipeline as a rendered template (B-115). `filters[search]` then falls back to a three-arm contains match — the folded corpus, the raw `display_name` column, and the row `id`. The raw column arm covers rows with no staged corpus (definition-less writes via `ProjectionGucs.clear_all`, e.g. `core.Domain`) and lets an accented term match an accented label. See [`doctype-system.md`](doctype-system.md) → `search` and [`http-layer.md`](http-layer.md) → Filters.

## The statement (one per database)

A domain sits on one database, so the domain-scoped search is one SQL statement. For every contributing doctype — the caller holds a read grant and the definition declares a `search` template — one OR-joined branch over `projections`:

```sql
(SELECT …, similarity(search, $term)::float8 AS score
 FROM projections
 WHERE domain = $d AND doc_type = $dt AND deleted_at IS NULL
   AND search ILIKE '%' || $term || '%' ESCAPE '\'
   AND (<ReadEnforcer scope fragments>)
 ORDER BY score DESC LIMIT $per_doctype)
UNION ALL (…)
```

- The term is prepared exactly like the list route's `search` filter (`Util::LikeEscape.escape(Util::DiacriticFold.fold(term))`) and bound once, reused by every branch's ILIKE probe and `similarity()` rank.
- Scope fragments come from `RBAC::ReadEnforcer.list_where_clauses` with placeholder indices threaded across branches; they compile once per `(domain, doctype)` and are cached for reuse by the root scope check. A `1=0` fragment set is kept — fail closed.
- A doctype without a read grant contributes no branch (`AuthContext#can?` pre-filter, mirroring `AgentTools::Read.readable_doctypes`). A preview principal is authorized only inside its bound draft domain; the enforcer narrows rows at query time.
- Branches carry `meta->>'parent_id'` and an `is_child` flag (known at build time from `member_of`).

## Child hits combine with the aggregate root

Composition children (`member_of` set) hold much of an aggregate's searchable text. A child hit must land on a page the app can open — the root's show page — so the statement resolves the root in the same round trip:

1. A recursive CTE seeded by the matched child rows climbs `meta->>'parent_id'` to the first ancestor whose doctype declares no parent. The per-level parent doctype comes from a `VALUES` map built in Crystal from the definitions' `member_of` chains; the map is domain-scoped, so same-named child doctypes of different domains never steer each other's walk.
2. The root's own read scope is enforced on the anchor: for each distinct root doctype, a final-WHERE `EXISTS` branch re-checks the terminal row against that doctype's fragments. A root the caller cannot read, a deleted root, or a broken chain drops the hit — nothing reaches the client (fail closed, mirroring the nested-route rule that the parent's read scope gates its children).
3. The walk carries each node's `display_name`, so the terminal row hands the response the root's label plus the matched child's own label.

The palette shows one entry per root (label = root `display_name`, subtitle = the top-ranked matched child); collapsing per root happens client-side.

## App-wide fan-out

There is no cross-database SQL. `GET /Api/search` groups the readable domains by their routed database (`Database.group_by_database` — the `database.cluster` route table), runs one statement per group, and merges in Crystal: sort by rank desc with a deterministic tie-break (`domain, doc_type, id`), cap to `OVERALL_CAP`, group per doctype in first-hit rank order. Every group carries `domain` and `doctype` — the hits do not repeat them; a client inherits the group values per hit, so it can qualify rows when escalated. Single-pool deployments (no `cluster:` section) resolve to one group.

Enumeration of the doctypes (and of the live, non-draft domains on the app-wide route) runs on the control-plane database that hosts the `core.DocType` / `core.Domain` rows; the statement runs on each target domain's routed entry — the same split `Document::List` uses.

## Non-disclosure

The domain-scoped route answers by the state of the `core.Domain` row and the term:

- **Live domain, matching term** → `200` with the hits the caller may read.
- **Live domain, no match** → `200` with an empty result.
- **Unknown domain** → `404` non-disclosing (the route verifies the `core.Domain` row before it queries).
- **Draft domain** → `200` with an empty result: the existence check sees the `core.Domain` row, and the domain-scoped route does not consult the draft flag (the app-wide fan-out filters drafts through the live-domain check; the domain-scoped route does not).

The status difference between unknown (`404`) and draft (`200`) does disclose that a named domain exists as a draft — that is the present contract; whether drafts should answer `404` like unknowns is a product decision, not an information leak by accident.

A term shorter than `MIN_TERM_LENGTH` answers `200` with an empty result before the domain check runs — a one-character term on an unknown domain answers `200`, not `404`.

- A denied doctype contributes no branch; unsatisfiable scope fragments contribute a `1=0` branch.
- A child hit whose root cannot be proven live and readable never reaches the client.
- Tombstones never match (`deleted_at IS NULL` in every branch and in the walk).
