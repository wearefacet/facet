# The release docs image — ghcr.io/wearefacet/facet-docs.
#
# A fully static Astro/Starlight build (English + French pages, sitemap,
# llms.txt, raw markdown twins) served by the stock nginx-unprivileged
# image. No runtime process beyond nginx: the site is content only, and the
# markdown twins and llms.txt files ride along as plain static files.
#
# Build context: the repository root (.dockerignore prunes it).
#
# Build args (CI supplies VERSION and REVISION; local builds may omit them —
# they feed the OCI labels only):
#   VERSION   — the release tag (e.g. v0.1.0)
#   REVISION  — the git commit sha
#   SITE_URL  — the canonical origin (astro `site`, canonical + og:url +
#               sitemap + robots.txt). The default is a placeholder; a
#               production build must set the real domain:
#               docker build --build-arg SITE_URL=https://docs.example.com …

ARG VERSION=dev
ARG REVISION=unknown

# ── Build stage ─────────────────────────────────────────────────────────────
#
# Dependency layer first so source edits do not re-install node_modules.
# The D2 diagram engine is pure WASM (@terrastruct/d2) and sharp ships
# prebuilt binaries for every platform in the lockfile, so the build runs on
# any architecture without system packages.
FROM node:24-bookworm-slim AS build
LABEL org.opencontainers.image.licenses="BUSL-1.1"
ARG SITE_URL=https://docs.facet.example
ENV NODE_OPTIONS=--max-old-space-size=4096 \
    SITE_URL=${SITE_URL}
WORKDIR /workspace/site-docs

COPY site-docs/package.json site-docs/package-lock.json ./
RUN npm ci

# The prebuild coverage check reads inventory.yml; the diagram renderer and
# the sitemap/robots emitters run inside `npm run build`. The build mutates
# pages in place (D2 fences become image blocks) — all inside this layer.
COPY site-docs/ ./
RUN npm run build

# ── Runtime stage ───────────────────────────────────────────────────────────
#
# nginx-unprivileged: the stock nginx image tuned to run as the non-root
# `nginx` user (uid 101) on port 8080 — same shape as the prod edge, which is
# itself nginx. The server block (docker/docs.nginx.conf) replaces the stock
# conf.d/default.conf; the image's main nginx.conf already carries the
# unprivileged pid/temp paths and the mime types.
FROM nginxinc/nginx-unprivileged:1.28-alpine AS runtime
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet docs" \
      org.opencontainers.image.description="Facet documentation website — static Astro/Starlight build behind nginx" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"

COPY docker/docs.nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build --chown=101:101 /workspace/site-docs/dist /usr/share/nginx/html

# The image's USER (101) and EXPOSE (8080) already match this deployment; the
# healthcheck rides busybox wget, which the alpine base carries. Any status
# below 500 proves the server serves — the site has no dynamic route that
# could answer 4xx for a healthy reason, so 200 is the only pass.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
