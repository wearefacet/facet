# 01 — Voice and vibe

This is the most important file of the plan. The current site is correct. It
fails because it reads like the system describing itself to someone who
already knows it. Your job is to make it read like **a senior colleague
showing a new team member around**: calm, clear, honest, never in a hurry,
never showing off.

Read the whole file before you write a page. Come back to §10 (the checklist)
before you finish each page.

---

## 1. The feeling we want

When a reader closes a page, they should think:

- "I understand what this is for."
- "I know what to do next."
- "Nobody tried to sell me anything or impress me."
- "If I need the details, I know where they are."

Five words for the vibe: **calm, concrete, kind, honest, complete.**

| We are | We are not |
|---|---|
| A colleague who has done this many times | A spec, a sales page, or a professor |
| Patient with people who know nothing yet | Condescending ("simply", "just", "obviously") |
| Precise about values, labels, limits | Vague to sound friendly |
| Honest about limits and trade-offs | Defensive or hype-driven |
| Warm through clarity and care | Warm through jokes, emoji or exclamation marks |

Facet is a serious product for organisations that care about their data. The
tone carries that seriousness without being cold. The product's own promise
is a good guide: *apps are disposable, your data is not.* The docs should feel
like the data side of that sentence — stable, trustworthy, there for years.

## 2. Who reads us

Every page names its audience in the front-matter. Write for **that person**,
and assume they know **nothing about Facet**, but they are competent at their
own job. Here are the personas. Keep them in mind as real people.

| Persona | Code | Who they are | What they know | What they fear |
|---|---|---|---|---|
| **Claire**, operations manager | `evaluator`, `user` | Runs operations at a 60-person company. Uses spreadsheets, a CRM, two SaaS tools that do not talk to each other. | Her business, very well. Business software as a user. Nothing about databases. | Losing control of company data. Being locked in. Being made to feel stupid. |
| **Marc**, IT lead | `evaluator`, `admin` | One-person IT team in an SMB. Manages accounts, SSO, backups, vendors. | Networks, identity, Linux basics, compliance words (GDPR, ISO 27001). Not a developer. | Security holes, audit failures, a tool nobody can maintain. |
| **Inès**, power user / consultant | `author` | Builds the company's Airtable bases today, or works for a consulting firm (such as Amplitude) that sets up tools for clients. | Data modelling by instinct: tables, links, statuses. Some formulas. No code. | Building something that breaks when the business changes. |
| **Sam**, developer | `developer` | Builds an internal app, often with an AI coding agent. | Web development, REST, OAuth in theory, TypeScript. | Auth plumbing, hosting chores, unclear permission errors. |
| **Ops**, the self-hoster | `operator` | Runs Facet on a server. Sometimes Marc, sometimes an Amplitude engineer. | Containers, PostgreSQL basics, reverse proxies, logs. | Upgrades that break, data loss, 3 a.m. alerts. |
| **The agent** | all | A coding agent reading `llms-full.txt` or a `.md` twin. | Everything in its training data, nothing about Facet. | Ambiguity. It acts on what the page literally says. |

Rules that follow from the personas:

- **Claire and Marc never see code in Discover or Use pages**, except a short
  config snippet in Discover's security page if Marc needs it.
- **Inès must be able to build a real domain without writing code** (the
  in-app path, with the assistant). Lua and Jinja2 appear in Build, but each
  page says first whether you need them.
- **Sam gets exact commands, exact payloads, exact errors.** Warmth for Sam
  means not wasting their time.
- **The agent needs every page to stand alone**: explicit prerequisites,
  complete examples, exact names. Warm prose does not hurt the agent; vague
  prose does.

## 3. The layer model (how we stay simple *and* complete)

Every topic exists at up to three depths. A reader climbs down only when they
want to.

| Layer | Question it answers | Where it lives | Jargon allowed |
|---|---|---|---|
| **L1 — orientation** | "What is this, and why should I care?" | `discover/`, tab index pages, the first paragraph of every page | None (see §5 budget) |
| **L2 — task** | "How do I do this job?" | Tutorials, how-to pages in `use/`, `build/`, `admin/` | Product terms, each defined at first use on the page |
| **L3 — depth** | "How exactly does it work? What are the edge cases?" | `build/deeper/`, `admin/under-the-hood/`, `reference/`, and the "How it works" section at the end of a how-to | Full precision, still defined |

Rules:

- **Each page lives at one layer.** A how-to page does not open with the
  internals. It can end with a short `## How it works` section and a link
  down to L3.
- **Each page links one layer up and one layer down** in `## Related` when
  those pages exist ("New to roles? Start with *Roles in two minutes*." /
  "For the exact enforcement order, see *How access is enforced*.").
- **Moving a fact down a layer is allowed. Deleting it is not.** The
  preservation checklist (`00-contract.md` §5) makes sure of this.
- **Precision does not decrease with depth; vocabulary increases.** An L1
  page is not allowed to be wrong for the sake of simplicity. "Facet keeps
  every change" is true; "Facet keeps every change forever" is false (retention
  compacts old history). Say "Facet records every change, and keeps the full
  history for as long as your retention settings say."

## 4. How a page flows

The skeleton from `doc/documentation.md` stays (lead, When to use this,
Before you start, Steps, Example, Troubleshooting, Related). v2 adds rules on
*how the reader moves through it*.

### 4.1 The lead paragraph: situation, job, payoff

The first two to four sentences answer three questions, in this order:

1. **Where is the reader?** Their situation, in their words.
2. **What does this page help them do?**
3. **What do they get?**

> You keep client data in Facet, and your sales team should see only their
> own clients. A **row scope** does that: it filters which documents a role
> can reach, everywhere — lists, search, the API, the assistant. Set it up
> once on the role, and every app follows it.

Banned lead formulas (the current site overuses them): "Read this page to
see…", "This page covers…", "This page explains…", "In this section…",
"Facet is a governed application platform…" (except once, on the Why Facet
page). Do not open two neighbour pages with the same sentence shape.

### 4.2 One new idea per page

A newcomer can absorb one new concept at a time. If a page needs two new
concepts, either the second already has its own page (link it, with one plain
sentence of summary), or the page must split.

### 4.3 Name the idea after you show it

Introduce a term **after** the reader understands what it does, then name it,
in bold, once:

> You never change a live domain directly. You work in a private copy, check
> it, and switch it live in one step when it is ready. That copy is a
> **draft**, and the switch is **publish**.

Not:

> A draft domain is a non-live domain with an autogenerated name prefixed by
> `_` in which doctype definitions can be edited without a version gate.

(The second sentence's facts are true and belong in L3: the `_` prefix, the
auto-generated name, no version gate. Put them in `build/model/in-app/how-drafts-work.md`.)

### 4.4 Say why, briefly

Each rule, limit or safety step gets one sentence of *why*. People follow
rules they understand, and they remember them.

> Publishing copies the structure only, never the test documents you created
> in the draft. That way, nothing you typed while experimenting ends up in
> production data.

### 4.5 Show the expected result

After each important step, say what the reader should see: the screen, the
message, the output. Use the real output (from the running app or command).
For UI steps, a screenshot is welcome (see §8).

### 4.6 End with a next step

Every page ends with somewhere to go: the next tutorial step, the deeper
page, or the related job. A reader should never reach a dead end.

## 5. Vocabulary and the jargon budget

### 5.1 Glossary terms (always use these, with one meaning)

These are Facet's product words. Use them consistently. Define each at its
first use on a page (a short clause is enough), and link the glossary.

*domain, doctype, document, field, draft, publish, role, permission, row
scope, field tag, grant, app, workspace, Builder, assistant, sidecar (shown to
users as "comments and attachments"), action, hook, webhook, history,
rollback, retention, bundle, API key, service account.*

### 5.2 Engine words (L3 only)

These words describe how the engine works. They are banned from L1 and from
the lead paragraph of L2 pages. In an L3 page or a "How it works" section,
use them, and define them:

*projection, mutation, mutation log, auth context, principal, elected role,
enforcer, metadata gate, cause chain, tombstone, coalescing, compaction, lazy
migration, re-projection, ETag, at-most-once, consumer group, lease, DPoP,
PKCE, JSONB, AuthContext, effective scope, intersection (∩).*

Translations for L1 and L2:

| Engine word | Say instead (L1/L2) |
|---|---|
| mutation log | the history (of a document) / the change log |
| mutation | a change |
| projection | the current version of a document |
| elected role / role election | the role you act as (you pick one when you have several) |
| auth context | who is calling and with which role |
| grants ∩ roles | an app can never do more than both the user and the app are allowed |
| enforcer / enforcement | Facet checks the rule on every request |
| non-disclosing denial | Facet answers "not found" instead of "forbidden", so nobody learns the document exists |
| tombstone | a deleted document Facet still remembers, for history |
| lazy migration | old documents update to the new structure the next time someone reads them |
| at-most-once delivery | a webhook or hook can miss an event in rare failures; the reconcile job repairs it |
| DPoP | proof that the token belongs to this app (developer pages define the term) |

### 5.3 Words we do not use

- **Belittling:** simply, just, easily, obviously, of course, trivial, merely.
- **Hype:** powerful, seamless, robust, blazing, revolutionary, magic,
  leverage, unlock, supercharge, effortless, game-changer, best-in-class.
- **Hedges you could verify away:** should, might, probably, usually — when
  the code gives a definite answer. Check the code instead.
- **Future tense for features:** will soon, coming, planned, roadmap.

### 5.4 UI labels and code names

- UI labels are **bold** and exact, as in the running app: **Builder**,
  **New domain**, **Publish**. Check `frontend/messages/en.json` for the
  string.
- Code names, keys, paths, commands are in `code`: `dev.domain_watch.path`.
- Never paraphrase a label, a key, or an error message.

## 6. Titles

Titles are the sidebar. A newcomer scans them to find their job.

- **How-to pages: the job, as a verb phrase.** "Hide a field from some roles",
  not "Field visibility with tags". "Show each role only its own rows", not
  "Named scopes".
- **Explanation pages: the idea, as a plain noun phrase or a question.**
  "Why you act as one role at a time", not "Auth contexts".
- **Reference pages: the thing.** "Config file keys", "Lua API".
- **The product term may follow in the description and the lead**, so search
  and agents still find it.
- 40 characters or fewer, sentence case, no section prefix, no parenthesis.

The page map (`03-page-map.md`) proposes a title for every page. You may
improve a title if it keeps these rules; record the change in your report.

## 7. Examples

- **Use the running example** (`05-running-example.md`): Brightwater
  Rentals, its domains, roles and people. Do not invent new companies.
  Readers learn faster when every page builds on the same story.
- **Examples are complete and runnable.** No `…`, no "rest of config here".
- **Real values.** Real field names from the example bundle, real outputs
  from the running instance.
- **Where the example does not fit** (an operator page about TLS), use plain
  placeholders that are obviously placeholders: `docs.example.com`.

## 8. Visuals

- **Diagrams** (D2 on site pages): one idea per diagram, short labels, flat
  nodes (see `doc/site-docs.md` → Diagrams). Every explanation page leads with
  one. Each "How Facet works" page has one.
- **Screenshots** of the workspace and Builder for Use pages and tutorials.
  A newcomer needs to see where a button is. Captured by the script from WP
  14, with the Brightwater data, light theme, 1280 px wide. Add alt text that
  says what the screenshot shows, not "screenshot".
- **Tables** for options, keys, comparisons. Not for narrative.
- **Never** stock images, decorative illustrations, or emoji.

## 9. Before and after

These rewrites use real content from the current site. Every fact stays; the
order, vocabulary and layer change. They show the *voice*. They are not
verified copy: when you write the real page, verify each fact again (for
example, which surfaces a row scope applies to) before you keep it.

### 9.1 A concept page (L3 → L1 + L3)

**Before** (`concepts/auth-contexts.md`, lead):

> A browser tab, an app, an agent and a command-line script can all call the
> same API. Facet gives every request the same authorization shape: one auth
> context. Read this page to see what sits inside that context, and what the
> one elected role costs.

**After — L1** (`discover/how-it-works/roles.md`, one section):

> **You act as one role at a time.** Someone can hold several roles — say,
> *Sales* and *Manager*. When they sign in, they pick the role they work as,
> and everything they see and do follows that one role. To switch, they pick
> another. This keeps every action easy to explain later: the history shows
> who did it, and as which role.

**After — L3** (`admin/under-the-hood/one-role-at-a-time.md`, lead):

> Every request to Facet — from the workspace, an app, an AI agent or a
> script — carries exactly one identity and one role. Facet calls this pair
> the **auth context**. This page shows how each way of connecting sets it,
> and why Facet never merges two roles.

(The channel/credential table from the old page follows unchanged.)

### 9.2 A how-to lead

**Before** (`build/named-scopes.md`):

> A named scope is a saved filter over the fields of one doctype. An
> administrator attaches it to a permission line, and the permission then
> reaches only the rows the filter matches.

**After** (`build/model/access/named-scopes.md`):

> At Brightwater, each salesperson should see only the clients they manage.
> As the domain author, you write that rule once, on the *Client* doctype:
> "clients whose account manager is me". This saved rule is a **named
> scope**. An administrator then gives it to the *Sales* role — see
> [Show each role only its own rows](/admin/people/row-scopes/).

### 9.3 A section index

**Before**: a bulleted list of 26 page titles.

**After**: "What do you want to do?" with three to five cards, each a job and
a first page, then the full page list under **All pages in this section**.
See `02-information-architecture.md` §5.

### 9.4 A troubleshooting entry

**Before**: `### Publish fails with a diagnostics error`

**After**: `### Publish says my domain has errors` — then the fix as an
ordered path: "Open **Check**. Each line names the doctype and the field. Fix
the first one, run **Check** again. Still failing? …"

## 10. The voice checklist (run it on every page)

- [ ] The lead says situation, job, payoff — no banned formula (§4.1).
- [ ] The persona in `audience` can follow the page without another tab
      open, or the prerequisite is linked in **Before you start**.
- [ ] At most one new concept; each term named after it is shown (§4.2, §4.3).
- [ ] No engine words outside L3 or a "How it works" section (§5.2).
- [ ] No belittling, hype, hedge or future words (§5.3).
- [ ] The title is a job (how-to), an idea (explanation) or a thing
      (reference) — 40 characters or fewer (§6).
- [ ] Each rule or limit has one sentence of why (§4.4).
- [ ] Expected results are shown after important steps (§4.5).
- [ ] The example uses Brightwater and is complete (§7).
- [ ] UI labels are bold and exact; keys and commands are code (§5.4).
- [ ] `## Related` links one layer up and one layer down (§3).
- [ ] Read aloud: no sentence makes you take a breath in the middle.
      Average sentence about 15 words; none above 25 outside tables.
- [ ] Nothing true was lost; it is here or one layer down.

## 11. What stays from the current rules

Keep everything in `doc/documentation.md` Rule 2 and Rule 2a: action first,
"you" first, short beats, scannable, troubleshooting in the reader's words,
never trade precision for friendliness. v2 relaxes two things only:

- The ASD-STE100 baseline stays the default (plain words, one idea per
  sentence, active voice) but **the 20-word ceiling becomes an average of
  ~15 with a hard limit of 25**, so the prose can breathe and does not sound
  robotic.
- "No humor" stays. **Warmth through care is now required**, not just
  allowed: name the reader's situation, say why, give the next step.

WP 11 writes these changes into `doc/documentation.md` so they outlive this
plan.
