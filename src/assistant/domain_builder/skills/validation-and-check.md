---
title: Validation and Check
description: What Doctype::Validation enforces at authoring time vs what Doctype::Check surfaces as diagnostics, error message interpretation.
tags: [validation, check, diagnostics]
---

# Validation and Check

Two distinct services govern doctype integrity:

- **`Doctype::Validation`** — runs at create/update time. Hard failures (422).
- **`Doctype::Check`** — runs on demand via `check_doctype`. All issues are warnings; the runtime silently no-ops on broken configs.

## Validation (authoring-time, hard)

`Doctype::Validation.validate` enforces:

- `doctype` is CamelCase and doesn't start with a digit.
- `domain` matches the domain regex (draft mode permits the `_` prefix).
- `schema_version` ≥ 1.
- Field names are valid identifiers.
- Reserved action names are not used.
- The Lua script compiles as a module.
- Every declared action has a matching `export.<name>` function (ScriptValidator).
- Every `data` field has a matching `export.compute_<suffix>` function.
- Replicate declarations are structurally valid (have `via` and `field`).
- Named scopes reference fields that exist on this doctype and known context sets.

In draft mode, `Validation.validate_draft` is used: same checks but version/migration discipline is skipped.

Order matters: **schema validation runs before the Lua validate hook**. A hook cannot rescue schema-invalid input — if `Validation` rejects the payload, the hook never runs. Design the definition to pass schema validation on its own merits.

## Template node paths are 0-based

Template validation errors (on the view tools and `check_doctype`) name the node with a 0-based dot path — `template.children.1` is the **second** child. A trailing segment names a property, not an index: `template.children.2.tabs` points at the `tabs` property of the third child. Read the path right-to-left: index segments count children from 0, name segments name a property of the node at that spot.

## Check (runtime diagnostics, soft)

`Doctype::Check.call` surfaces:

- `:reference` — a `reference` field targets an unregistered doctype.
- `:replication` — a `replicate` declaration has a broken target or grant (mirrors `Replication::Validator`).
- `:children` — a `children` declaration targets an unregistered same-domain doctype.
- `:composition` — the owned-composition graph is inconsistent: (1) a child declaring `member_of` whose parent has no matching `children:` entry; (2) a `reference` field targeting a doctype that is an owned child (the historical `hr.Candidate`-style bug where owned children were modelled as reference fields).

All Check issues are warnings — the runtime silently no-ops on broken configs (empty reference match, no replication pull, child 404).

## How to read validation `details` arrays

When `create_doctype` / `update_doctype` returns `{"ok":false, "error":"...", "details":["...","..."]}`, each detail is a separate validation error. Fix them all, then re-submit.

## In draft

- Version/migration discipline is lifted — destructive same-version edits are allowed without `$force`.
- `check_doctype` is still the source of truth for cross-doctype integrity.
- The iteration target is "no Check issues at publish time" — drafts may legitimately show Check issues mid-iteration (e.g. unregistered reference targets).
