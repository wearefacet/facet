# Domain grants: IAM configure page hides existing grants; publish report contradicts the active state

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H07XD7MGA8YKX8SD4MM348ST` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (configure domains, publish dialog) + backend (grants) |
| Verdict | Claim 3 confirmed. Claims 1 and 2 partial — corrections below |

## Summary

Three reported gaps in the grant flow. Investigation result:

1. Publish warning "misleading" — partial. Publish does create the grant. The
   pre-publish warning already discloses the auto-filing. The genuine defect is
   in the post-publish report: for an admin publish it shows "Active" and
   "acceptance is needed" at the same time.
2. "No place to see and accept/reject grants" — partial. A full management UI
   exists on the grants tab (activate/deactivate, delete, edit, create). In the
   reported scenario it was blinded on the producer side (item 3), and the held
   side is read-only by design.
3. "Grants missing from the configure/domain page" — confirmed. The IAM domain
   page hides all grants behind a system-domain guard, while the grant
   iam → quality-assurance exists under producer iam.

## Evidence

Claim 3 — CONFIRMED:

- `frontend/src/lib/components/features/configure/DomainEditor.svelte`
  L294-304 — `loadGrants` early-returns for system domains:
  `if (isSystemDomain(domain)) { issuedGrants = []; heldGrants = []; ...return; }`.
- `frontend/src/lib/systemDomains.ts` L10-13 —
  `SYSTEM_DOMAINS = ['core', 'iam', 'app']`. So `/Configure/domains/iam`
  renders the empty state "No issued grants..." with a `0` badge
  (`DomainEditorHeader.svelte` L106-109) — while the grant exists.
- The guard encodes a wrong assumption. The publish ticket flow files grants
  into any live producer: `src/grants/publish_tickets.cr` L96
  (`next unless live_domain?(db, producer)`; `live_domain?` L218-230 has no
  system-domain exclusion), L100-104 (create when no row exists). The validator
  refuses only self-grants (`src/grants/validator.cr` L60-72). The queries
  themselves are correct — had `loadGrants` run, the grant would appear as
  issued.

Claim 1 — PARTIAL:

- Publish creates the grant: `src/domain/publish.cr` L230-244 →
  `Grants::PublishTickets.file`; an admin holding `activate` files it active
  (D11, `publish.cr` L378-390).
- The pre-publish warning (`src/replication/validator.cr` L328-330) already
  discloses the auto-filing ("the consumer's publish files a ticket, or the
  producer creates one by hand") — not misleading as such.
- The genuine defect: `PublishDialog.svelte` L242-246 picks the report text by
  `ticket.filed` alone — "New grant filed — the producer's acceptance is needed
  before data flows." — while the state chip (L240, L205-207) shows "Active"
  for the same admin publish. The dialog contradicts itself.

Claim 2 — PARTIAL:

- The grants tab manages grants: activate/deactivate on issued cards
  (`DomainGrantsTab.svelte` L288-307, `toggleActive` L176-181 → the
  `activate`/`deactivate` named actions), delete (L309-319), edit, create
  (L87-92 gate the buttons).
- Backend support: dedicated routes
  `POST /Api/core/DomainGrant/:id/activate|deactivate` (`src/grants/routes.cr`
  L26-32; reentrant write of the `read_only` flag L71-89; `active` is
  `read_only: true` with named actions — `data/seeds/core.DomainGrant/
  definition.yml` L40-50). No separate "rejected" state — reject = deactivate
  or delete.
- In the reported scenario the producer tab was blinded (claim 3), and the
  held side is read-only by design (D5; held cards L410-442 render no actions)
  — so the admin had nowhere to act on that specific grant.
- Note: `AppGrantsEditor.svelte` is unrelated (app-token permissions; a naming
  collision only).

## Root cause

A frontend system-domain guard (`SYSTEM_DOMAINS` early return in `loadGrants`)
written under the assumption that system domains never hold grants —
contradicted by the publish ticket flow. Secondary: the publish report text
ignores the D11 active state.

## Fix direction

1. `DomainEditor.svelte` `loadGrants` (L294-304) — drop or narrow the
   `isSystemDomain` early return so issued/held lists load for `core`, `iam`,
   and `app`. The create guard (`canCreate`, `DomainGrantsTab.svelte` L87) can
   stay as a product choice.
2. `PublishDialog.svelte` L242-246 + `frontend/messages/*.json` — make the
   ticket text state-dependent (active: "filed and accepted — data can flow";
   inactive: current text).
3. The pre-publish check message needs no change.
