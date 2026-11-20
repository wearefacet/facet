# WP 16 — Tested tutorials in CI

Phase 2 (whole-doc §7: "CI coverage check enforced, tutorials auto-tested") · Depends on: WP 05 and WP 06 complete; container infrastructure from `doc/ops/container-images.md` and the container-release plan · Write scope: `scripts/` (repo root, new tutorial check scripts), CI workflow file for the docs job, `doc/site-docs.md`.

Source: [`whole-doc.md`](whole-doc.md) §5. "Tested tutorials: T1–T6 are scripted against a fresh container in CI (later also by an agent run)."

## Goal

A tutorial that stops working fails the build. T1–T6 run as scripts against a fresh container on every docs-affecting change.

## Deliverables

### 1. Tutorial check scripts

One script per tutorial under `scripts/tutorial_checks/` (shell or Crystal, matching repo conventions):

- `t1.sh` — start the container stack fresh (per `doc/ops/first-deployment.md`), wait for health, seed the first admin, sign in via the API, assert the session works.
- `t2.sh` — from the T1 state, create the Inventory domain via the API/CLI exactly as the tutorial's steps do; assert the published doctypes exist.
- `t3.sh` — the assistant path (needs a configured LLM endpoint; skip with a clear message when the environment lacks one).
- `t4.sh` — create the Sales role, scopes, and tag; assert a scoped user sees the restricted view.
- `t5.sh` — register an app, run the OAuth + SDK call sequence from the tutorial, assert the deployed app responds.
- `t6.sh` — MCP handshake plus one read and one write under a delegated role.

Rules:

- Each script mirrors the tutorial's steps — same commands, same order. A divergence means either the script or the page is wrong; fix both sides in one change.
- Each script prints the step name before it runs, so CI logs point at the failing step.
- A runner without containers or an LLM endpoint skips cleanly with an explicit "SKIPPED (no <requirement>)" line — never a silent pass.

### 2. CI wiring

One job (or stage) in the existing workflow: fresh container → `scripts/tutorial_checks/run_all.sh` → site build. Record the job name and trigger in `doc/site-docs.md`. Coordinate with the container-release plan owner if the workflow file is contested — CI files are outside every other WP's write scope, so take the lock.

### 3. Agent-run variant (later)

Whole-doc §5 mentions a later agent-run variant: an agent executes each tutorial like a reader would and reports divergences. Design for it here (scripts print steps, tutorial pages have checkpoints), but do not build the agent runner in this WP.

## Definition of done

- [ ] Six scripts run green against a fresh container locally.
- [ ] `run_all.sh` reports PASS / FAIL / SKIPPED per tutorial with step-level output.
- [ ] CI job wired and green; `doc/site-docs.md` documents it.
- [ ] Any product bug found while scripting is filed, not written around.
