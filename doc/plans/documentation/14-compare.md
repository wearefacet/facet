# WP 14 — Compare section (`/compare/`)

Phase 2 (whole-doc §7) · Depends on: WP 01, WP 04 (positioning pages); D4 and D8 from `99-decisions.md` (licensing and support offers) · Write scope: `site-docs/src/content/docs/compare/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.10. "Honest 'Facet vs the world' pages, including when **not** to choose Facet."

## Pages

| File | Title | Front-matter | Notes |
|---|---|---|---|
| `compare/vs-airtable-notion.md` | Facet vs Airtable and Notion databases | `audience: [evaluator]`, `features: []` | Where a spreadsheet-style tool wins; where governed data, RBAC and audit win |
| `compare/vs-retool-lowcode.md` | Facet vs Retool and low-code builders | `audience: [evaluator]`, `features: []` | App-first vs data-substrate-first |
| `compare/vs-odoo-erp.md` | Facet vs Odoo and ERP suites | `audience: [evaluator]`, `features: []` | Fixed processes vs domain modeling |
| `compare/vs-supabase-firebase.md` | Facet vs Supabase and Firebase | `audience: [evaluator, developer]`, `features: []` | Raw backend-as-a-service vs built-in governance |
| `compare/vs-ai-built-apps.md` | Facet vs "just let the AI build it" | `audience: [evaluator, developer]`, `features: []` | Disposable apps on a governed substrate — the whole-doc thesis |

Also finish `compare/index.md` (from WP 01): one paragraph + the page list.

## Shared page shape

Each comparison page uses the WP 00 skeleton (Explanation variant) with one table up front:

| | Facet | <Alternative> |
|---|---|---|
| Data model | ... | ... |
| Access control | ... | ... |
| Audit and rollback | ... | ... |
| Hosting | ... | ... |
| Best for | ... | ... |

## Writing notes

- Be honest about the alternative's strengths. A comparison that never loses is not credible (whole-doc §3.10). Every page has a "Choose <alternative> when" section.
- Ground claims in the product: link `/start/what-is-facet/`, `/start/security-governance/`, and the relevant concept pages. Do not invent competitor facts — describe the alternative at the level a reader can verify, or not at all.
- D4 (licensing page) and D8 (support offers, footer links) affect the "what you get" claims. Check the decisions file before writing.

## Definition of done

- [ ] Five pages + finished index, front-matter per WP 00.
- [ ] Each page has a "Choose X when" section naming real limits.
- [ ] User review of the five pages before they count as done — positioning copy is a product-voice decision. Flag this in your report.
- [ ] `cd site-docs && npm run build` passes.
