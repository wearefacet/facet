# 02 — Information architecture

How the new site is organised, and why. The exact path of each page is in
[`03-page-map.md`](03-page-map.md); this file gives the shape and the rules.

---

## 1. Principles

1. **Sort by reader first, then by depth.** The top level answers "who are
   you and what are you here to do?". Inside each tab, pages go from the
   guided path, to tasks, to depth.
2. **A newcomer sees one sidebar, not eleven sections.** Each tab has its own
   sidebar. The other tabs are one click away, at the top of the sidebar.
3. **One golden path.** "Your first hour" takes any reader from nothing to a
   running Facet with a domain, an app and a colleague. Every tab points to
   it.
4. **Choices are explicit.** Where the product offers two ways to do one job
   (build in the app or in files; sign in an app user or a backend service),
   a decision page states the choice before the reader goes down one path.
5. **Depth is always reachable.** Every simple page links down to the
   precise one. Nothing is hidden; it is ordered.

## 2. The five tabs

| Tab | Path | For | Answers | Size (approx.) |
|---|---|---|---|---|
| **Discover** | `/discover/` | Claire, Marc (evaluators) | What is Facet? How does it work, in plain words? Is it for me? Is it safe? How does it compare? | 20 pages |
| **Use** | `/use/` | Everyday workspace users | How do I find, read, change and track my data? How do I use the assistant? | 15 pages |
| **Build** | `/build/` | Inès (authors) and Sam (developers) | How do I model my data, and build apps on it? | 70 pages |
| **Administer** | `/admin/` | Marc (admins) and Ops (operators) | How do I install, configure, secure, govern and run Facet? | 45 pages |
| **Reference** | `/reference/` | Everyone, and agents | What is the exact key, field, operator, command, payload? | 22 pages |

The five tabs appear as a topic list at the top of the sidebar (that is where `starlight-sidebar-topics` renders them; a header placement would need a component override — WP 11 may propose one). The landing page (`/`) has one door per tab
plus a prominent **Your first hour** button.

### 2.1 Discover

```
Discover
  Overview                      (index — "Start here")
  Why Facet
  How Facet works
    The big picture
    Domains: where your data lives
    Documents: records with a memory
    Roles: who sees and does what
    Apps: built fast, replaced freely
    The assistant: AI with your rights
  A day at Brightwater          (illustrative tour of the running example)
  Is Facet right for you?
  Security and governance
  Compare
    Overview + 5 comparison pages
  Licensing and services
```

**How Facet works** is the heart of onboarding. Six short pages, one diagram
each, no engine words (`01-voice-and-vibe.md` §5.2). After these pages, a
reader can follow any L2 page in the site.

### 2.2 Use

```
Use
  Overview
  Your first day
    A tour of the workspace
    Sign in and secure your account
    The dashboard
  Work with documents
    Open and edit a document
    Comments and attachments
    History and undo
    Import and export
  Find things
    Lists, boards and calendars
    Search and the command palette
    Keyboard shortcuts
  Notifications
  Ask the assistant
  Your settings and API keys
```

### 2.3 Build

Build serves two personas who meet in the middle: the author models data, the
developer builds apps on it. The tab opens with the shared golden path, then
splits.

```
Build
  Overview                      (path picker: model data / build an app / both)
  Your first hour               (tutorials — see §4)
  Set up a dev environment
  Model your data
    Choose how you build        (decision page: in the app vs in files)
    In the app: draft and publish
      How drafts work
      Drafts, editors and publishing
      Build with the assistant
      Check before you publish
    In files: dev mode
      The domain watcher
      The domain file layout
      Build domains with a coding agent
    From dev to production
    Move domains with bundles
    Change a live domain safely
    Data: doctypes and fields     (6 pages)
    Relations                     (4 pages)
    Views                         (4 pages)
    Behaviour                     (2 pages)
    Automation                    (3 pages)
    Access rules                  (1 page)
  Build apps
    Overview
    How apps work on Facet
    Quickstart
    Connect                       (7 pages)
    Read and write data           (6 pages)
    Host and embed                (2 pages)
    AI agents                     (3 pages)
  How it works (deeper)           (L3 pages for authors and developers)
```

#### The two build modes (important)

Facet has two ways to build a domain. The site must present them as a
choice, early and clearly, and every shared page must work for both.

| | In the app: draft → publish | In files: dev mode |
|---|---|---|
| Where | Any instance, including staging and production | A dev server you own; it refuses to run in production |
| Who | Authors, often non-developers | Developers and AI coding agents |
| How you edit | The **Builder** UI or the domain-builder assistant, inside a draft (`_…`) | YAML and Lua files in your editor; the watcher applies each save |
| Safety net | The draft is isolated; **Check** runs diagnostics; publish is one transaction | Version control; drafting is bypassed |
| Test data | Scratch documents in the draft; publish copies structure only | `documents: preserve` or `discard` in the watcher config |
| Reaches production by | **Publish** | Export a bundle, import it on the target, then (optionally) adjust in a draft there |

Rules for authors of Build pages:

- `build/model/index.md` ("Choose how you build") presents this table, with
  one card per mode and a third card "From dev to production".
- Shared pages (data, relations, views, behaviour, automation, access) show
  definitions both ways with synced tabs: `<Tabs syncKey="build-mode">` with
  a **Builder** tab and a **Files** tab. The reader's choice then sticks across
  pages. When a feature only exists in one mode, say so in one line instead
  of showing a tab.
- `build/model/dev-to-production.md` is new. It explains the round trip, what
  moves in a bundle and what does not (documents only with
  `--with-documents`), and what happens if the same domain is edited in files
  and in a draft. Verify the last point against the code (WP 16); do not guess.

### 2.4 Administer

```
Administer
  Overview                      (path picker: install / secure / govern / run)
  Install
    System requirements
    Run with containers
    Go to production
    First start and bootstrap
  Configure
    Configuration files
    System settings
    Email
    File storage
    Currencies
    Languages
  People and access
    Manage accounts
    Roles and permissions
    Assign roles
    Show each role only its rows
    Hide a field from some roles
    Who can change roles
    Require MFA
    Single sign-on (OIDC)
    Sessions and lockouts
  Apps and machine access
    Control what apps can reach
    API keys
  History and audit
    See who did what
    Roll back a change
    Retention: what is kept
  The assistant
    Connect a language model
    Govern the assistant
  Keep it running
    Health, metrics and logs
    Background jobs and cron
    Database migrations
    Upgrade Facet
    Indexes
    Back up and restore          (blocked on decision D7)
  Under the hood                  (L3 pages for admins and operators)
```

Govern and Operate merge because in an SMB they are often the same person
(Marc), and the old split forced him to jump between two sections for one
job. Merged pages are listed in the page map.

### 2.5 Reference

```
Reference
  Overview
  Glossary
  Feature index (generated)
  REST API (generated)
  CLI: facet / app CLI (generated)
  Config keys, system settings keys, account settings keys (generated)
  Doctype schema, view template schema, field types, filter operators (generated)
  Jinja2 context, Lua API, permission syntax
  Agent tools (generated), webhook payloads (generated)
  Error responses, health and metrics names
  Changelog
```

Reference keeps its current paths, because the generators in
`scripts/gen_docs/` write to them. Only the glossary and the changelog move
in.

## 3. Page types

Every page declares `type` in its front-matter. Each type has one job.

| `type` | Layer | Job | Skeleton |
|---|---|---|---|
| `overview` | L1 | Orient and route. Tab and group index pages. | Lead, "What do you want to do?" cards, **All pages in this section** list. No steps. |
| `tutorial` | L2 | Teach by doing; one path, one result. | See §4. |
| `how-to` | L2 | Get one job done. | `doc/documentation.md` skeleton; optional `## How it works` before `## Related`. |
| `explanation` | L1 or L3 | Build a mental model. | Lead, diagram, `## Explanation` (or plain H2s), `## What this means for you`, `## Related`. |
| `reference` | L3 | Look something up. | Table-first. Generated where possible. |

`## What this means for you` is new and required on explanation pages: two to
four bullets that turn the idea into consequences the reader can act on.

## 4. Your first hour (the golden path)

One tutorial track, one running example, one hour of real work in total.

| # | Page | Result | Primary persona |
|---|---|---|---|
| 0 | Overview | Knows the plan, the time, what they need | everyone |
| 1 | Run Facet | Facet running locally, admin signed in, tour done | Marc, Sam |
| 2 | Model your first domain | The *Equipment* domain built **with the assistant in a draft**, checked, published, with a kanban board | Inès |
| 2b | The same domain in files | The same domain in files under the watcher (optional, for developers) | Sam |
| 3 | Ship your first app | A small check-out app for the warehouse, built with an AI coding agent, deployed on Facet, signed in through Facet | Sam |
| 4 | Give your team access | A colleague invited; the *Warehouse* role can see equipment but not purchase prices | Marc |
| 5 | Connect an AI agent | An MCP client (for example Claude Desktop) answers "which tents are free next weekend?" under one role | Sam, Inès |

Rules:

- Tutorials chain with `prev`/`next` front-matter.
- Each tutorial opens with a box: **You will build**, **Time**, **You need**.
  Write it as plain markdown (a short list), not a custom component, so the
  `.md` twin stays readable.
- Each step shows the expected result, with a screenshot for UI steps.
- Each tutorial ends with **What you learned** (three bullets, each linked to
  the L1 page of that idea) and **Next**.
- Tutorials are tested end to end on a fresh instance (WP 14 and WP 21).

## 5. Index pages (path pickers)

Index pages route. They never list 26 links as the first thing.

```markdown
---
title: Build
type: overview
...
---

<Lead: who this tab is for, what they will be able to do, 2–3 sentences.>

## What do you want to do?

<CardGrid>
  <LinkCard title="Try it in an hour" description="Run Facet, build a domain, ship an app." href="/build/first-hour/" />
  <LinkCard title="Model your business data" description="Doctypes, fields, views and rules." href="/build/model/" />
  <LinkCard title="Build an app on Facet" description="Sign users in, read and write data, deploy." href="/build/apps/" />
</CardGrid>

## All pages in this section

<grouped list with one-line descriptions>
```

Use Starlight's built-in `CardGrid` and `LinkCard`. They render to readable
links in the `.md` twin. Three to five cards; never more than six.

## 6. Navigation devices

| Device | Where | How |
|---|---|---|
| Tabs (topics) | Every page | `starlight-sidebar-topics` plugin (decision D1): a topic list above the sidebar; each topic has its own sidebar. |
| Collapsed groups | Long sidebars (Build, Administer) | `collapsed: true` on groups below the current one. For autogenerated directory groups, `starlight-auto-sidebar` can set labels and collapsed state from a `_meta.yml` per directory (WP 11 decides if it is needed). |
| Path-picker cards | Tab and group index pages | §5. |
| "Before you start" links | How-to and tutorial pages | Link each prerequisite page; never assume the reader saw it. |
| Layer links | `## Related` | One layer up, one layer down (`01-voice-and-vibe.md` §3). |
| Mode tabs | Build model pages | `<Tabs syncKey="build-mode">` (§2.3). |
| Glossary hovers | — | Not used. Link the glossary entry at first use instead (hovers do not survive in `.md` twins). |
| Search | Every page | Pagefind (built in). Page descriptions must contain the product term, so a search for "named scope" finds "Show each role only its own rows". |
| Redirects | Old URLs | Astro `redirects` in `astro.config.mjs`, generated from the page map (WP 11). Every old URL keeps working. |

## 7. Front-matter changes

WP 11 extends `site-docs/src/content.config.ts`:

- adds `type` (enum: `overview`, `tutorial`, `how-to`, `explanation`,
  `reference`), required on every page except the landing page;
- keeps `audience`, `features`, `verified_at` as they are.

The coverage script keeps reading `features`. WP 11 adds a check that every
page has a valid `type`.

## 8. What does not change

- Astro + Starlight, the two locales, D2 diagrams, `llms*.txt`, the `.md`
  twins and the copy-as-markdown button.
- The reference generators and their output paths.
- The coverage tooling (`inventory.yml`, `coverage-exclude.yml`,
  `scripts/check-coverage.mjs`), extended in WP 10 and WP 11.
- The landing-page components (`src/components/landing/`). WP 20 rewires the
  doors to the five tabs.
