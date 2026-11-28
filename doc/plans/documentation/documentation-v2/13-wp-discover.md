# WP 13 — Discover

**Goal:** a reader who has never heard of Facet understands what it is, how
it works in plain words, whether it fits them, and whether it is safe —
in about 20 minutes of reading, with no engine vocabulary.

**Depends on:** WP 11; decisions D6 (licensing wording), D10 (services).
**Audience:** Claire and Marc (`01-voice-and-vibe.md` §2).

**Write scope:** `site-docs/src/content/docs/discover/**` (English only).
**Inputs:** the old pages at their new paths, `ledgers/originals/` for split
pages, `README.md` and `LICENSING.md` at the repo root, `doc/project-structure.md`.

---

## Pages

| Path | Title | Job of the page |
|---|---|---|
| `discover/index.md` | Start here | Who Facet is for; three cards: *Understand Facet* (How it works), *Is it for me?*, *Try it in an hour*. |
| `discover/why-facet.md` | Why Facet | The problems first, in the reader's words: data spread across tools, nobody sure who can see what, fragile bridges between systems, IT that slows the business down for good reasons, SaaS prices that rise with no way out. Then the idea: one governed home for your business data, plus the apps that run on it; apps are disposable, data is not. Then what Facet is *not* (not an app builder for end users, not a BI tool — verify the limits list in `is-facet-right-for-you`). |
| `discover/how-it-works/index.md` | The big picture | One diagram: people, apps and agents → Facet (accounts and roles, permission checks, history) → domains. Five short paragraphs, each linking to the next five pages. |
| `discover/how-it-works/domains.md` | Domains: where your data lives | A domain = one business area (Brightwater: equipment, clients, rentals). Doctypes and fields as "the kinds of records and what they hold". Domains are kept apart; sharing between them is explicit. Drafts in one paragraph. |
| `discover/how-it-works/documents.md` | Documents: records with a memory | A document = one record. Every change is recorded: who, when, through what. You can see the history and undo. Retention in one honest sentence. Comments and attachments. |
| `discover/how-it-works/roles.md` | Roles: who sees and does what | Roles; one role at a time; limiting rows (Tom sees his clients) and fields (Lucía does not see prices); checked on every request, whatever the app — so an app cannot bypass the rules. |
| `discover/how-it-works/apps.md` | Apps: built fast, replaced freely | An app lives outside the data. It signs in through Facet and gets at most what both the user and the app are allowed. Facet hosts it, so there is no separate server to run. Delete the app; data, rules and history stay. Say how the workspace relates to apps only after you verify it in the code (it may or may not go through the same app path). |
| `discover/how-it-works/assistant.md` | The assistant: AI with your rights | The assistant has no rights of its own; it acts as you, as your current role, and its changes appear in history under your name. Three places it appears (workspace, Builder, inside apps); agents can connect over MCP. Bring your own model (verify what the config supports). |
| `discover/a-day-at-brightwater.md` | A day at Brightwater | Fictional tour: Tom books, Lucía checks out items in the app, Nadia asks the assistant, Ravi reviews the audit. Each scene links to the page that explains it. Screenshots from WP 14 when available (leave clear placeholders `<!-- screenshot: … -->` until then and list them in the report). |
| `discover/is-it-right-for-you.md` | Is Facet right for you? | Keep the honest limits. Structure: *Facet fits well when…* / *Facet is not the right tool when…* / *What you need to run it*. Every limit verified at `HEAD`. |
| `discover/security.md` | Security and governance | For Marc. Identity, access, history, data storage, secrets, hosting — each as a short claim with a link to the admin page that proves it. No marketing. No claims about certifications or compliance that the product does not hold (decision D12). |
| `discover/compare/*` | (6 pages) | Voice pass only: lead paragraphs, titles, engine words, Related links. Do not change the verdicts without verification. |
| `discover/licensing-and-services.md` | Licensing and services | Plain-words licence: what you can do (use, modify, self-host, offer services around it), what the Additional Use Grant forbids, the four-year conversion to Apache 2.0, the CLA for contributions, trademark rules. Then where to get help (decision D10). Source only from `LICENSE`, `LICENSING.md`, `TRADEMARKS.md`, `CLA.md`. |

## Rules specific to this WP

- **Zero engine words** (`01` §5.2) on every Discover page except a short
  "For the technical detail" link list at the end.
- Each How Facet works page: **one** D2 diagram, under 600 words,
  `## What this means for you` with 2–4 bullets, and links to the L2 pages
  for each part.
- Every claim is still verified. Simple is not approximate (`01` §3).
- The L1 material that came out of split concept pages must keep its link to
  the L3 page that now holds the details.

## Features

Discover pages document few features directly; they orient. Set `features`
only where the page truly documents something (for example
`discover/security.md` keeps its `IAM-*`, `RBC-*`, `AUD-*` wildcard *only if*
each area is genuinely explained there; otherwise list the IDs it explains and
link the rest).

## Done when

- [ ] All pages above written; the six How Facet works pages read in order in
      under 15 minutes.
- [ ] A test reader with no Facet knowledge can explain in their own words:
      domain, document, role, app, assistant, history. (WP 21 runs this test;
      run a quick version yourself by asking a fresh agent.)
- [ ] Voice checklist passed on every page; engine-word count in leads = 0.
- [ ] Preservation checklists closed for `start/*` and the L1 halves of the
      split concept pages.
- [ ] Gates pass; report per `00-contract.md` §10.
