# Brightwater Check-out

The warehouse app from the Facet documentation's first hour: the confirmed
bookings, with a button to mark items out and back in. A small Vite +
TypeScript single-page app that signs its users in through Facet
(OAuth 2.1 + PKCE) with `@facetapp/sdk`.

## Prerequisites

- A Facet instance with the Brightwater example loaded
  (`site-docs/examples/brightwater/load.sh`).
- The `brw-checkout` app registered on that instance — see
  [Ship your first app](../../src/content/docs/build/first-hour/first-app.md).
  The registration must list both redirect URIs this app uses:
  `http://localhost:5173/auth/callback` (local dev) and the hosted app's own
  `/auth/callback`.
- Node.js 20+ and pnpm.

## Run locally

```sh
pnpm install
pnpm dev          # http://localhost:5173
```

Sign in with a Brightwater account — Lucía Ferrer
(`lucia@brightwater.example`) holds the `warehouse` role the app needs.

## Deploy

```sh
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

The deploy serves the `dist/` build at the app's host on the instance.

## Structure

| File | What it does |
| --- | --- |
| `src/main.ts` | The app: OAuth sign-in, today's confirmed bookings, per-line item status with an out/back toggle. |
| `src/style.css` | The small stylesheet. |
| `facet.config.json` | The deploy target for `@facetapp/cli`. |
