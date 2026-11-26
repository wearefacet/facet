# WP 22 — French

**Goal:** the French site matches the English one: same structure, same
facts, natural French.

**Depends on:** WP 21 passed (do not translate pages that are still moving).
**Write scope:** `site-docs/src/content/docs/fr/**`, French overlays in
`scripts/gen_docs/fr_overlay*` (then `make gen-docs`).

---

## Rules

- Follow [`doc/site-docs-fr-style.md`](../../site-docs-fr-style.md): translate
  the meaning, not the words; keep the term glossary; take UI labels from
  `frontend/messages/fr.json`, exactly.
- The voice of `01-voice-and-vibe.md` applies in French: situation, job,
  payoff; one idea per sentence; no jargon in L1; warm through care. Use
  *vous*.
- The French pages moved by WP 11 still hold the old text. Treat them as a
  glossary source, not as a base: translate from the new English page.
- Screenshots: if the capture script supports the French locale, capture
  French screenshots (`site-docs/src/assets/screens/fr/…`); otherwise keep the
  English ones and add nothing.
- Brightwater keeps its English proper names (people, company); translate
  doctype labels only if the example bundle has French labels (it should not
  need them).

## Order

1. Discover (all), then Your first hour, then Use.
2. Administer › People and access, History and audit.
3. The rest of Build and Administer.
4. Reference leads (overlays) and the glossary.

Until a page is translated, Starlight shows the English page with the
"untranslated" banner. That is acceptable during the transition (decision D8).

## Done when

- [ ] Every English page has a French twin with the same front-matter
      `features`, `type`, `sidebar.order`, and a fresh `verified_at`.
- [ ] No French page holds pre-v2 text (check: the word count and headings
      follow the English page).
- [ ] Gates pass; report per `00-contract.md` §10.
