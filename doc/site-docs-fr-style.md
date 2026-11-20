# French style guide

How to write the French pages under `site-docs/src/content/docs/fr/`. The site
stack and i18n mechanics live in [`site-docs.md`](site-docs.md); the writing
rules (action-first, one audience, verified claims) live in
[`documentation.md`](documentation.md) and apply to French pages unchanged.
This file holds what changes in French: how a page must read, which terms stay
English, and the traps that make French sound like translated English.

**Source files:** every page under `site-docs/src/content/docs/fr/`, and the
French UI strings in `frontend/messages/fr.json`.

## Rule 1 — Translate the meaning, not the words

Read the whole English paragraph, close it, and write what it says the way a
French engineer would have written it from scratch. Then re-open the English
and check that no fact, number, or caveat is lost.

Never mirror the English syntax. Word-by-word translation produces calques,
and calques are the reason French readers reject a text. Real examples caught
in a previous pass:

| Do not write | Why | Write |
| --- | --- | --- |
| « La configuration vit dans deux fichiers » | calque of "lives in" | « Deux fichiers portent la configuration » |
| « l'administrateur de dev semé » | "seeded" rendered literally | « l'administrateur créé par l'initialisation » |
| « Les écrivains ajoutent seulement » | English word order | « Le journal n'accepte que les ajouts » |
| « deux sauvegardes rapides laissent une ligne » | "leave one row", reads ambiguous | « ne laissent qu'une seule ligne » |
| « Ce identifiant » | elision error | « Cet identifiant » |
| « au plus une fois par décision » | "by decision" is not "par décision" | « au plus une fois, par conception » |
| « la frontière de rétention » | "boundary" is not a border | « la limite de rétention » |

The read-aloud test decides: if a sentence sounds like English wearing French
words, rewrite it. A short French sentence beats a long translated one — split
English sentences freely when French breathes better.

## Rule 2 — Terminology

### Keep in English

Established technical terms stay English. French developers use them as-is;
translating them loses the reader:

> webhook, backend, frontend, payload, token, refresh token, session,
> endpoint, rate limit, timeout, callback, cache, worker, cron, hook, append-
> only, streaming, event sourcing, lockfile, PATH, app, prompt, fail closed
> (see Rule 4 for the idiom rendering), token de concurrence stays « ETag »

Acronyms and protocol names never translate: API, SDK, CLI, REST, HTTP, SQL,
JSON, JSONB, YAML, OAuth, OIDC, JWT, MFA, TOTP, SSO, PKCE, MCP, ETag, ULID,
SPA, CSV, UTC, E2E.

Product and stack names never translate: Facet, doctype (the product term —
the French UI keeps « doctypes » too), domain names (`hr`, `sales`),
`iam.Account`, Crystal, PostgreSQL, Redis, Caddy, SvelteKit, Storybook,
Vitest, Playwright.

### Translate

| English | French |
| --- | --- |
| domain | domaine |
| record | enregistrement |
| draft | brouillon |
| live domain (vs draft) | domaine réel |
| publish | publier |
| saved view | vue enregistrée |
| pinned view | vue épinglée |
| role | rôle |
| elected role | rôle élu |
| grant | attribution |
| permission line | ligne de permission |
| scope | périmètre (row scope → périmètre de lignes) |
| field tag | étiquette de champ |
| backlink | lien entrant |
| view template | modèle de vue |
| snapshot | instantané |
| rollback | retour arrière |
| undo / redo | annuler / rétablir |
| retention | rétention |
| compaction | compactage |
| coalescing (write-time) | fusion à l'écriture |
| mutation log | journal des mutations |
| login-event log | journal des connexions |
| show page | page détail |
| workspace | espace de travail |
| sign in / sign out | se connecter / se déconnecter |
| seeded | créé par l'initialisation, pré-créé |
| throwaway | (for dev data) des données que vous pouvez effacer à tout moment |
| enforcer | contrôleur |
| guard | garde-fou |
| write-only field | champ en écriture seule |
| redaction | caviardage |
| non-disclosing read | lecture sans divulgation |
| fail closed | le refus par défaut (render the meaning, not the idiom) |

Product-gender rule: Facet is masculine (« il »), by default for products; a
feature agrees with its head noun (la plateforme → elle, le journal → il).

### UI labels — copy the product

The product UI is localized: `frontend/messages/fr.json` holds every French
string (Paraglide). When a page names a button, menu, or page title, use the
exact string from that file — « Enregistrer », « Paramètres », « Historique »,
« Épingler la vue actuelle ». Never invent a French label. If the string does
not exist in `fr.json`, keep the English label and quote it as-is.

## Rule 3 — Grammar and typography

- **Apostrophe:** use the typographic apostrophe ’ (U+2019), as the product UI
  does: « l’utilisateur », « l’état ».
- **Double punctuation:** no line can start with `: ; ! ?`. Put a
  non-breaking space (U+00A0) before them: « comment ? », « ceci : ».
- **Quotation marks:** use « guillemets » with non-breaking spaces inside, for
  quoted UI text and cited words. Code stays in backticks, never quoted.
- **Elisions:** cet identifiant, cet appelant, cette ligne — never « ce
  identifiant ».
- **Titles and headings:** sentence case, no Title Case. Titles stay ≤ 40
  characters — French runs longer than English, so shorten the idea instead
  of inflating the title.
- **No exclamation marks, no marketing words, no hedges** — same rules as the
  English pages.
- **Numbers and code:** values, commands, config keys, error codes, and table
  or column names never change. A `422` stays `422`.

## Rule 4 — Sentence shape

- Vous-form, present tense. Imperative for step lists (« Ouvrez », « Lancez »),
  indicative for descriptions.
- One idea per sentence, same as the English pages. English one-sentence
  paragraphs with three em-dashes usually become two French sentences.
- Bold lead-ins stay bold lead-ins (« **Fusion à l’écriture.** … »).
- English nominal stacks unfold with prepositions: "mutation log retention
  compaction window" → « la fenêtre de compactage du journal des mutations ».
- Security idioms render as meaning: "fails closed" → « en cas d’échec,
  l’accès est refusé » or « le refus par défaut » — never « échoue fermé ».

## Standard headings

Recurring headings use one translation across all pages:

| English | French |
| --- | --- |
| When to use this | Quand l’utiliser |
| Before you start | Avant de commencer |
| Prerequisites | Prérequis |
| Steps | Étapes |
| Explanation | Explication |
| Example | Exemple |
| Troubleshooting | Dépannage |
| Related | Voir aussi |
| Next steps | Pour aller plus loin |
| In this section | Dans cette section |

## Page mechanics

- **Front-matter:** copy `audience`, `features`, `verified_at`, and
  `sidebar.order` from the English twin unchanged. Translate `title` and
  `description` only. `description` stays one sentence, ≤ 160 characters.
  A `title` or `description` that contains ` : ` must be quoted — YAML reads
  a bare colon as a nested mapping and the build fails.
- **File path:** same path under `fr/` — `start/install.md` →
  `fr/start/install.md`. The pairing is by filename (see
  [`site-docs.md`](site-docs.md) → i18n).
- **Internal links:** point to the `/fr/...` route, even when the French page
  does not exist yet — Starlight serves the English fallback with a notice
  banner. Translate the link text. For links with an `#anchor`, recompute the
  anchor from the translated heading: lowercase, spaces to hyphens, accents
  kept, punctuation stripped (« Voir aussi » → `#voir-aussi`).
- **Diagrams:** reuse the English `<!-- d2 ... -->` block and its
  `/diagrams/<hash>-light|dark.svg` references unchanged. Diagram labels stay
  English; never regenerate French SVGs.
- **Code blocks:** comments inside code may be translated; identifiers,
  flags, and URLs never.
- **Generated reference pages:** their French prose lives in the generator
  (see the `GenDocs` scripts under `scripts/gen_docs/`); the French body must
  pass this style guide like any hand-written page.

## Definition of done for a French page

- [ ] Written from the meaning, not the words — read-aloud test passes.
- [ ] Terminology matches the tables above; UI labels match `fr.json`.
- [ ] No entry from the calque table; elisions correct; typographic
      apostrophes and non-breaking spaces in place.
- [ ] Front-matter complete; title ≤ 40 chars; description ≤ 160.
- [ ] Internal links carry `/fr/`; diagrams and code blocks untouched.
- [ ] `cd site-docs && npm run build` passes; the page renders under `dist/fr/`.
- [ ] Agent readers: the `.md` twin under `dist/fr/` carries the French content.
  The `llms*.txt` files stay English-only — the `starlight-llms-txt` plugin
  filters to the default locale by design.
