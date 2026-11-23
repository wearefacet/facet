# iam.LoginEvent: actioner is always `system`; the subject is not filterable

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0D3E854C2YA2TQRKCB3BV47` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | backend (iam, audit, filter grammar) |
| Verdict | Confirmed (core claim and both consequences). Two sub-claims corrected |

## Summary

`iam.LoginEvent` rows are written with `actioner_id = "system"` and channel
`internal`. The human subject is stored only in the `account_id` content
field, which declares no filter capability. No structured per-account query
exists on any surface. The reported impact — "show me all audit events about
Jean" is inexpressible — is real.

## Evidence

Single writer, uniform actioner:

- `src/iam/helpers.cr` L86-95 — `write_login_event` calls
  `Mutation::Client.create(..., actioner_id: "system")` with no provenance
  argument. The default applies (`src/mutation/client.cr` L101-113;
  `src/mutation/provenance.cr` L72-74) → channel `internal`.
- Every login-related path funnels through this writer, so all LoginEvent rows
  carry `actioner_id = "system"`, `channel = "internal"`.

Subject stored as an unfilterable content field:

- `data/seeds/iam.LoginEvent/definition.yml` L10-14 — `account_id` is a
  required string ("The ULID of the account this event relates to") and
  declares no `filters:` capability. The gate is the declaration, not the type:
  `src/doctype/field_definition.cr` L226-228 (no declared capability → empty
  operator set) and `src/document/filter_compiler.cr` L105-110, L242-244
  (every filter form raises 422; the error text names the remedy at L265).
- Document-list surface (`GET /Api/iam/LoginEvent`, agent `list_documents`):
  422 on any `account_id` filter.
- Audit surface (`src/audit/list.cr` L101-105): `FILTERABLE_FIELDS` covers
  `actioner_id` (eq/ne) but no document content fields — and `actioner_id` is
  uniformly `system`.
- `account_id` is in the search corpus (`definition.yml` L6) — substring
  search only, not a structured query.

## Corrections to the report

- Actioner variety — refuted. All paths use the same writer; the actioner is
  uniformly `system`. The synthetic principals exist as `account_id` (subject)
  values, not actioners: `system:password` (`src/iam/login.cr` L68-74),
  `system:oidc` (`src/iam/oidc/routes.cr` L98-168), and the IdP `sub` claim for
  denies with no resolved account (`src/iam/oidc/identity.cr` L102-103).
- "OIDC flows store an email in `account_id`" — refuted. Unresolved OIDC denies
  store the provider `sub` (an opaque subject), not an email. Resolved flows
  store the account ULID.

## Fix direction (decision points from the issue stay open)

1. Make the subject queryable. Add `filters: [equality]` (optionally
   `text_search`) to `account_id` in `data/seeds/iam.LoginEvent/definition.yml`.
   Additive capability; `Index::Manager` emits the index. 0.2.0-beta is
   deployed — ride the seed reconcile / doctype update path and confirm it
   updates the stored definition on existing instances.
2. Attribute the event to the subject. In `write_login_event`, stamp
   `actioner_id: account_id` when the identity resolves; keep `system` for the
   synthetic denial principals. This alone makes the audit surface's existing
   `actioner_id` filter per-account, with no definition change.
3. Open design questions from the issue remain: cross-account events (doer vs
   subject, with the doer in `details`), refresh volume in per-account views,
   backfill of historical rows, and release-notes impact for consumers that
   filter `actioner_id = system`.
