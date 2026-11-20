# Facet documentation site

Public documentation website for [Facet](https://github.com/wearefacet/facet),
built with [Starlight](https://starlight.astro.build) on Astro.

```sh
npm run dev       # dev server at localhost:4321
npm run build     # static build into dist/ — the validation gate
npm run preview   # serve the built site
```

- Content lives in `src/content/docs/` (English) and `src/content/docs/fr/`
  (French). Files that share a filename across the two trees are linked
  translations. A missing translation falls back to the English page with a
  notice banner.
- Diagrams are D2 fences. `scripts/build-diagrams.mjs` renders each one to an
  SVG pair (light + dark) under `public/diagrams/`; run `npm run diagrams`
  after editing one. The house style lives in `scripts/diagram-theme.mjs`.
- The build also generates `llms.txt`, `llms-small.txt`, and `llms-full.txt`
  for LLM consumption.
- The concern document for agents is [`doc/site-docs.md`](../doc/site-docs.md).
