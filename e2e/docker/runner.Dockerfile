# The Playwright runner image (harness §3): the mcr base pins browser
# versions; the @playwright/test package pins 1.61.0 to match.
#
# Build context: the repository root. The runner needs the e2e package
# (tests, fixtures, config) and the facet CLI + chat package sources
# (packages/cli, packages/chat), so the app scenario can deploy through the
# real binary and mount the real assistant bundle. The root .dockerignore
# re-includes exactly those trees and keeps node_modules out.
#
# Build args (optional — compose supplies throwaway defaults; they feed
# the OCI version/revision labels only):
#   VERSION   — e.g. a release tag (default dev)
#   REVISION  — the git commit sha (default unknown)

ARG VERSION=dev
ARG REVISION=unknown

FROM mcr.microsoft.com/playwright:v1.61.0-jammy
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet e2e runner" \
      org.opencontainers.image.description="Facet e2e Playwright runner image" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"
RUN npm install -g pnpm@10.30.3

WORKDIR /e2e

# Copy the stack shims FIRST and set NODE_OPTIONS after they exist: the
# env applies to every node process in this image, including the pnpm
# installs below and the CLI later. Node clients (Playwright request
# fixture, the facet CLI) fail hostname verification against Caddy's
# internal `*.localhost` wildcard — the same shims the frontend image
# loads (see their header comment).
COPY e2e/stack/node-runtime-shims.cjs /usr/local/lib/node-stack-shims.cjs
ENV NODE_OPTIONS="--require /usr/local/lib/node-stack-shims.cjs"

# Dependency layer first so source edits do not re-install node_modules.
COPY e2e/package.json e2e/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# The facet CLI builds once per image (its own lockfile — the package is
# standalone, no workspace file at the repo root). The scenario invokes the
# local /cli/dist/index.js: hermetic, no pnpx network fetch.
COPY packages/cli /cli
RUN cd /cli && pnpm install --frozen-lockfile && pnpm build

# @facetapp/chat builds once per image (own lockfile — same pattern). The
# vite lib build keeps the runtime dependencies external — a host bundler
# resolves them — so scripts/bundle-assistant.mjs plays that host: one
# browser-ready ESM dropped next to the miniapp fixture, where
# writeMiniappBuild copies it into every deployed build. The
# app-head-to-toe scenario mounts it as the app's assistant.
COPY packages/chat /chat
RUN cd /chat && pnpm install --frozen-lockfile && pnpm build

COPY e2e/playwright.config.ts e2e/tsconfig.json e2e/scenarios.txt ./
COPY e2e/tests ./tests
COPY e2e/scripts ./scripts
COPY e2e/fixtures ./fixtures
COPY e2e/stack ./stack

RUN node /e2e/scripts/bundle-assistant.mjs /chat /e2e/fixtures/miniapp/facet-assistant.js

RUN chmod +x stack/*.sh

ENTRYPOINT ["/e2e/stack/runner-entrypoint.sh"]
