# WP 18 — Administer

**Goal:** the person responsible for Facet in an SMB — often one person doing
both IT administration and operations — can install it, configure it, decide
who sees what, prove what happened, and keep it running.

**Depends on:** WP 11, WP 12; decisions D7 (backup) and D11 (upgrade policy), one page each.
**Audience:** Marc (admin) and Ops (operator). Marc knows identity and
compliance but is not a developer; Ops knows containers and PostgreSQL.

**Write scope:** `site-docs/src/content/docs/admin/**` except
`admin/index.md` (WP 20).

**Batches:**

| Batch | Groups |
|---|---|
| A — govern | `people/*` (9), `apps-access/*` (2), `history/*` (3), `under-the-hood/one-role-at-a-time.md`, `how-access-is-enforced.md`, `change-log.md` |
| B — operate | `install/*` (4), `configure/*` (6), `assistant/*` (2), `keep-running/*` (5, plus backup if D7 is decided), `under-the-hood/index.md`, `events-and-delivery.md`, `ai-and-permissions.md` |

Paths and titles: `03-page-map.md` §3, §7, §9.

---

## Page rules

- **Lead with the admin's question**, not the feature: "A new salesperson
  starts on Monday. Here is how to give them an account and the right role."
- **Every security statement is verified and sourced** in the claim ledger.
  This tab is where an auditor will look. No "secure", "safe", "compliant"
  without saying exactly what is done.
- **Merged pages** (`history/retention.md` from `govern/retention.md` +
  `operate/retention-tuning.md`): policy first, in plain words ("By default,
  Facet keeps the full history of a document for N days; older changes are
  folded into one snapshot, so you can roll back at most N days" — verify N
  and the wording), then the operator settings as a second half with its own
  H2. Close both preservation checklists.
- **The people group reads as one story.** In order: accounts → roles and
  permissions → assign roles → rows → fields → who can change roles → MFA →
  SSO → sessions. Use the Brightwater roles throughout. The row-scope page
  pairs with WP 16's `access/named-scopes.md`; both link each other at the
  top.
- **Install group:** `production.md` is a checklist that links every other
  page an operator must read before going live (TLS, email, file storage,
  backups, monitoring, upgrades, MFA policy). Each item has a one-line why.
- **Config examples** are complete files or complete sections, taken from a
  configuration that you started the server with.
- **Commands** are run on the running instance; output pasted.
- **Under the hood** pages are L3: precise, engine words allowed and defined,
  one diagram each, each linked from the L2 page that needs it.
- **Backup and restore** (`keep-running/backup-restore.md`): do not write it
  until D7 is decided. If D7 says "operator's responsibility", the page says
  so plainly and lists exactly what must be backed up (PostgreSQL, the file
  store, the config, the secrets — verify each) and how to verify a restore.

## Features

At least: IAM-01 to IAM-14 (admin side), RBC-01 to RBC-10, AUD-01 to AUD-08,
AUT-01, AUT-04, AUT-05, AUT-07, AI-07, AI-08, AI-09, PLT-01 to PLT-17
(admin/operator side), FE-11, FE-12, FE-14, FE-15, FE-16, FE-20. Fill the
page column of `surfaces.md` for `/Configure/*` and `/Settings/*` routes,
config keys, system settings keys, cron tasks, metrics and the `facet` CLI.

## Done when

- [ ] A test admin can, from these pages only: invite a user, give them a
      role with a row scope and a hidden field, enforce MFA, find a change in
      the audit log and roll it back. (Run it on the Brightwater instance.)
- [ ] A test operator can, from these pages only: start Facet in containers
      with TLS, email and S3 storage, check health, and upgrade. (Run it.)
- [ ] Every feature above covered by a how-to or explanation page (R2).
- [ ] Preservation checklists closed for all old `govern/*`, `operate/*` and
      the concept pages this WP owns.
- [ ] Gates pass; report per `00-contract.md` §10.
