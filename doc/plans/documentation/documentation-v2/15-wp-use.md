# WP 15 — Use (the workspace)

**Goal:** an employee who just got a Facet account can find their way, work
with their data, and trust what they see — without knowing anything about how
Facet is built.

**Depends on:** WP 11, WP 12, WP 14 part A (screenshots).
**Audience:** everyday users. Think of Lucía and Tom in the example: good at
their jobs, not interested in software.

**Write scope:** `site-docs/src/content/docs/use/**` except `use/index.md`
(WP 20). Requests for screenshots go into `site-docs/scripts/screens/shots.yml`
(append only).

---

## Pages

See `03-page-map.md` §4 and §9 for paths and titles.

| Group | Pages |
|---|---|
| Your first day | A tour of the workspace (new), Sign in and secure your account, The dashboard |
| Work with documents | Open and edit a document, Comments and attachments, History and undo, Import and export data |
| Find things | Lists, boards and calendars, Search and the command palette, Keyboard shortcuts |
| (top level) | Notifications, Ask the assistant, Your settings and API keys |

## Rules specific to this WP

- **No code, no config, no engine words.** Not even in "How it works"
  sections. If a user needs to know a limit ("you can only see the records
  your role allows"), say it in plain words and link Discover's Roles page.
- **Screenshots on every page** that has a UI step. Use Brightwater data and
  the right persona (Tom for sales screens, Lucía for warehouse screens).
- **Write for "why can't I…?" moments.** Users arrive at these pages when
  something does not look right. Every page has a Troubleshooting section in
  the user's words: "I can't see a record my colleague sees", "The Edit button
  is missing", "My change disappeared". Each answer names the likely cause
  (role, row scope, field tag, retention, a guard) in plain words and says who
  to ask (their administrator).
- **The tour page** (`use/first-day/index.md`) walks the screen from top to
  bottom: sidebar, domains, lists, a document, search, the assistant,
  notifications, the account menu. One screenshot per stop. It covers the
  welcome tour (FE-19): verify what the tour shows today.
- **API keys on the account page**: users can create personal API keys
  (verify). Explain in one paragraph what they are for and the risk, and link
  the developer and admin pages for detail.
- **Assistant page:** what to ask, what it can and cannot do, that it acts as
  the user's current role, that its changes appear in history under the
  user's name, how to cancel a running answer, where usage limits show.
  Verify each against `src/assistant/workspace/` and the UI.

## Features

At minimum, this WP covers: FE-01, FE-02, FE-03, FE-04, FE-05, FE-06, FE-07,
FE-08, FE-09, FE-17, FE-18, FE-19, FE-22, AI-01 (user side), AUD-02 and AUD-04
(user side), DOC-06 (user side), IAM-03, IAM-04, IAM-05, IAM-10, IAM-11 (user
side), PLT-17. Check `ledgers/surfaces.md` for every workspace route and
label, and fill the page column.

## Done when

- [ ] All pages written, each with screenshots for its UI steps.
- [ ] Every workspace route in `surfaces.md` (excluding Builder, Configure and
      admin-only screens) points to a Use page.
- [ ] Preservation checklists closed for all `workspace/*` pages.
- [ ] Voice checklist passed; zero engine words.
- [ ] Gates pass; report per `00-contract.md` §10.
