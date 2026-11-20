# WP 05 — Tutorials, core (T1, T2, T4)

Phase 0 · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/tutorials/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.2. "Each tutorial is linear, tested on every release, and ends with a working result."

## Tutorial skeleton

Tutorials replace the WP 00 page skeleton with this one:

```markdown
---
<front-matter>
---

## What you need
## Step 1 — <verb phrase>
(### Checkpoint: what you see when the step worked)
## Step N — ...
## Result
## Troubleshooting
## Next steps
```

Rules: every step is one command or one UI action, with the expected output. Every step has a checkpoint. Screenshots are optional; expected terminal output is not.

## Tutorials

### T1 — `tutorials/t1-run-facet.md` — "Run Facet in 15 minutes"

- `audience: [evaluator, operator]`, `features: [PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24]`
- Outcome (whole-doc): containers up, first admin seeded, logged in, welcome tour seen.
- Sources: `doc/ops/first-deployment.md`, `doc/ops/container-images.md`, `doc/backend/config.md`, `doc/backend/cli.md` (bootstrap and seed commands — IAM-12, DOM-24).

### T2 — `tutorials/t2-first-domain.md` — "Build your first domain"

- `audience: [author]`, `features: [DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03]`
- Outcome: a small "Inventory" domain: draft, doctypes, fields, refs, publish, list + kanban view.
- Sources: `doc/ops/build-a-domain.md`, `doc/backend/doctype-system.md`, `doc/backend/draft-domains.md`, `doc/backend/collection-view.md`, `doc/frontend/kanban.md`.
- Continues from T1's instance. Say so in "What you need".

### T4 — `tutorials/t4-team-access.md` — "Give your team access"

- `audience: [admin]`, `features: [IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11]`
- Outcome: invite users, create a "Sales" role with a row scope and a hidden field tag.
- Sources: `doc/backend/iam.md`, `doc/backend/rbac.md`, `doc/frontend/access-assignments.md`, `doc/frontend/access-accounts.md`.
- Continues from T2's domain. The "Sales" role scopes the Inventory data.

Numbering: the files use `t1`, `t2`, `t4` so the sidebar order matches tutorial numbers; T3, T5, T6 arrive with WP 06. Mention this in `tutorials/index.md` only if the gap confuses a reader — otherwise say nothing about missing tutorials (no future-talk).

## Testing requirement

A tutorial that was never run is not done. For each tutorial:

1. Execute every step on a real instance (containers for T1; `./scripts/dev` or the T1 containers for T2/T4).
2. Capture the real output for each checkpoint and paste it into the page.
3. Fix any step that does not match reality. If a product bug blocks a step, stop and report it — do not write around a bug.

If your environment cannot run the stack, stop before writing and report it. Do not ship untested steps.

## Definition of done

- [ ] Three tutorials, skeleton above, front-matter per WP 00.
- [ ] Every step executed; outputs match the page.
- [ ] `cd site-docs && npm run build` passes.
- [ ] `tutorials/index.md` lists the three tutorials with outcomes.
