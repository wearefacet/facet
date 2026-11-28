# WP 21 — Review: fresh eyes, accuracy, completeness

**Goal:** prove the three promises of v2 before it ships: a newcomer
understands it, every feature is there, and what it says is true.

**Depends on:** WP 20.
**Write scope:** `doc/plans/documentation-v2/ledgers/review/**`,
`site-docs/package.json` (strict coverage flip), `site-docs/coverage-exclude.yml`
(only to remove stale exclusions). **No page edits**: findings go to a fix
list, and the owning WPs (or a follow-up dispatch) fix them.

This WP has three parts, run by **three separate agents**. None of them may
have written a page in this plan. Part 1's agent must not read the code, this
plan, or `doc/`.

---

## Part 1 — The newcomer test (fresh agent, site only)

Give the agent only: the built site (`npm run preview` URL, or `dist/`), a
fresh Facet instance, and the persona card below. Nothing else.

> You work at a 45-person company. You have never heard of Facet. Your boss
> asked you to find out what it is and try it. You can read the docs site and
> use the Facet instance. You cannot read the source code or ask anyone.
> For each task: say where you started, every page you opened, where you got
> confused and why, and whether you finished. Be honest when something is
> unclear — that is the point of this test.

Tasks (in this order):

1. In your own words: what is Facet, and what problem does it solve?
2. Explain the difference between a domain, a doctype and a document.
3. Explain why the same person can see different things depending on their role.
4. Would Facet be a good fit for a 10-person design agency that only needs a
   shared task list? Why?
5. Follow **Your first hour** from tutorial 1 to tutorial 5 on the instance.
   Report time per tutorial and every place you had to guess.
6. As a workspace user: find a booking, change its date, then undo the change.
7. As a workspace user: you cannot see a client your colleague sees. Find out why.
8. As an author: add a field "Insurance value" to Item, visible only to managers.
9. As an author: decide whether to build in the app or in files, and explain
   your choice.
10. As an author: take a domain built in files on dev to another instance.
11. As a developer: make a script that lists today's bookings with an API key.
12. As a developer: what will your app be able to do for a user with the
    `warehouse` role? How do you know?
13. As an admin: require MFA for everyone.
14. As an admin: find who changed a booking yesterday, and what they changed.
15. As an admin: how long is history kept, and can you change it?
16. As an operator: what do you need to back up?
17. As an operator: how do you upgrade, and what happens to running requests?
18. Find the exact name of the config key that sets the file storage.
19. Which features does Facet *not* have that you might expect?
20. Look up three terms you did not understand in the glossary. Were the
    definitions enough?

Deliverable: `ledgers/review/newcomer.md` with, per task, pages visited,
confusion points (quoted), result, and a severity (blocker / confusing / minor).

Pass criteria: tasks 1–4 and 19 answered correctly from Discover alone;
tasks 5–18 completed; no blocker.

## Part 2 — The accuracy audit (fresh agent, code access)

1. Pick 30 pages at random (seeded; record the seed), weighted to how-to and
   explanation pages, at least 3 per tab.
2. On each, verify 5 claims against the code and the running instance,
   preferring numbers, defaults, labels and security statements. Do not
   trust the claim ledger; re-verify.
3. Pick 20 old pages at random; check their preservation checklists against
   the new site (`04` §4).
4. Re-run WP 10's extraction scripts (`ledgers/scripts/`) at the current
   `HEAD` and diff against `surfaces.md`: every surface has a page.

Deliverable: `ledgers/review/accuracy.md` — claims checked, failures with
evidence, lost facts, surfaces without a page.

Pass criteria: claim error rate under 2 % and zero security-claim errors;
zero lost facts; zero surfaces without a page.

## Part 3 — Completeness and the gates (any agent)

1. Run `node scripts/check-coverage.mjs --strict`: R1 and R4 must pass.
2. Run the R2, R3, R5, type, title, link, layer-link and dead-end checks.
3. Check every old URL redirects (from the pre-v2 sitemap).
4. Run `make gen-docs` and confirm a clean diff.
5. If all pass, flip the build to strict coverage: change the `prebuild`
   script in `site-docs/package.json` to `--strict`. Record the flip in
   `doc/site-docs.md` → Coverage and staleness (a request to WP 20's scope
   owner, or the maintainer, if WP 20 is closed).

Deliverable: `ledgers/review/gates.md` with every command and its output.

## The fix list

All three parts append to `ledgers/review/fixes.md`: one row per finding,
with page, finding, severity, owning WP. The maintainer dispatches fixes as a
follow-up round with the same contract. Re-run Part 1 tasks that failed after
the fixes land.

## Done when

- [ ] Three reports written by three agents that did not write pages.
- [ ] Pass criteria met, or the fix list is dispatched and re-tested.
- [ ] Strict coverage on.
