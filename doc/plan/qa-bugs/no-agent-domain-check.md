# No agent-reachable domain-level check (`check_doctype` is per-doctype only)

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H080EMP488B4WX5WRGPBT77V` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | backend (assistant domain-builder tools, doctype/domain check) |
| Verdict | Core claim confirmed. One sub-claim refuted |

## Summary

Agents can run only the per-doctype `check_doctype` diagnostic. The domain-level
check exists behind an HTTP route, but no agent surface exposes it. The
schema-version-bump diagnostic lives only inside that unreachable domain check,
so the reported miss (a doctype edit without a version bump passes every check
the agent can run) follows from the code.

Refuted sub-claim: `check_doctype` DOES validate collection views. The real gap
there is the tool description, which does not say so.

## Evidence

- `check_doctype` is a domain-builder assistant tool:
  `src/assistant/domain_builder/tools/read_tools.cr` L331-341, calling
  `Doctype::Check.call` (`src/doctype/check.cr` L104-121). Strictly
  per-doctype.
- The domain check exists only as an HTTP route:
  `src/domain/routes.cr` L44-46, L113-118 → `Domain::Check.call`
  (`src/domain/check.cr` L78-152). Exactly two callers exist in the repo: this
  route and the dev watcher (`src/dev/domain_watcher.cr` L587).
- No agent surface exposes it. The MCP catalogue
  (`src/agent_tools/registry.cr` L155-158) has no check tool; the workspace and
  app assistants have none; the domain-builder tool list
  (`src/assistant/domain_builder/tools.cr` L41-74) has `check_doctype` only —
  no `check_domain`. The closest affordance is `go_to_page(page: "check")`,
  which navigates the human's builder UI.
- Schema version bump: `check_doctype` can never report it —
  `src/doctype/check.cr` contains no version logic at all. Live domains enforce
  the bump at write time as a hard 422 (`src/doctype/update.cr` L290-305,
  `DefinitionGate.version_violations`; same-version guards L354-378). Drafts
  judge it at publish (`src/domain/publish_gate.cr` L78-88) and surface it as a
  `:publish_gate` diagnostic only inside `Domain::Check`
  (`src/domain/check.cr` L241-288 — drafts with a `source_domain` only). So the
  only readable bump diagnostic sits in the check agents cannot run.

Refuted sub-claim — collection views:

- `src/doctype/check.cr` L674 → `check_collection_views` (L682-709) runs every
  `core.CollectionView` child through `Document::CollectionViewGate.validate`
  and reports `:view` warnings. The manual sweep in the report was unnecessary.
- The actual gap: the tool description (`read_tools.cr` L332-334) mentions only
  DocumentView templates, so an agent cannot know that CollectionViews are
  covered.

## Root cause

The diagnostic layer was built for the human builder surface (HTTP routes plus
dev watcher); the agent toolset received only the per-doctype slice. No
registrar mounts `Domain::Check`.

## Fix direction

1. `src/assistant/domain_builder/tools/read_tools.cr` — add `check_domain`,
   mirroring `register_check_doctype`: call `Domain::Check.call(db, domain)`
   and return `{domain, domain_issues, doctypes}`. Add `"check_domain"` to
   `TOOL_NAMES` (`tools.cr` L41-74).
2. Patch the `check_doctype` description to say it also validates CollectionView
   configs.
3. Exposing a check tool to MCP agents is a larger decision — the route
   authorizes through `WriteEnforcer.authorize_update` on `core.Domain`. The
   builder surface is the natural first home.
