# The release backend image — ghcr.io/wearefacet/facet.
#
# Multi-stage Crystal build over the repo root context: shards install in
# their own layer above a thin source layer so rebuilds are cheap; the
# final stage is a slim non-root Ubuntu runtime. The e2e images
# (e2e/docker/*) are a different, throwaway contract: the same OCI labels,
# with throwaway defaults. No flag or layout change here may silently
# drift that set.
#
# Build context: the repository root (.dockerignore prunes it).
#
# Build args (CI supplies both; local builds may omit them — they feed the
# OCI labels only):
#   VERSION   — the release tag (e.g. v0.1.0)
#   REVISION  — the git commit sha

ARG VERSION=dev
ARG REVISION=unknown

# ── Build stage ─────────────────────────────────────────────────────────────
#
# The `lua` shard links liblua5.4 at build time and loads liblua5.4.so at
# runtime — the build stage needs the -dev package, the runtime stage the
# shared object only. `--release` matches `make build_release` (the
# whole-program Crystal release compile is the slow step; reference point,
# not a contract: 3-6 minutes cold on a 4-core host, under a minute when
# the shard layers are cached).
FROM crystallang/crystal:1.21.0 AS build
LABEL org.opencontainers.image.licenses="BUSL-1.1"
RUN apt-get update \
  && apt-get install -y --no-install-recommends liblua5.4-dev \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install

COPY src ./src
# Migrations, Lua event scripts, and the seed corpus are embedded into the
# binary at compile time (`Migrate::MIGRATION_SOURCES`, `Doctype::Seed`'s
# SEED_FILES, the Lua lock-shard script) — the build stage needs `db/` and
# `data/` next to `src/` for the `read_file` macros to resolve. A changed
# migration or seed file therefore requires a rebuild.
COPY db ./db
COPY data ./data
RUN crystal build src/main.cr --release -o /app/facet

# ── Runtime stage ───────────────────────────────────────────────────────────
#
# ubuntu:24.04 — the same glibc family as the build image (the crystallang
# image is Ubuntu 24.04). liblua5.4-0 is the shared object the binary loads;
# libxml2 and libyaml-0 are the Crystal stdlib link deps (XML and YAML
# parsers — the config loader pulls YAML at boot); ca-certificates feeds
# outbound TLS (SMTP, OIDC discovery, S3); curl feeds the HEALTHCHECK.
FROM ubuntu:24.04 AS runtime
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet" \
      org.opencontainers.image.description="Facet backend server — document store with event sourcing" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"

RUN apt-get update \
  && apt-get install -y --no-install-recommends liblua5.4-0 libxml2 libyaml-0-2 ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Non-root runtime user. /app and /data are owned by it: the entrypoint
# (running as facet) renders the config file into /app, and the server
# writes the artifact store under /data.
RUN groupadd -g 10001 facet && useradd -m -u 10001 -g facet facet

ENV APP_ENV=production \
    KEMAL_ENV=production \
    TZ=UTC

WORKDIR /app

# The compiled binary embeds `db/` (migrations, Lua event scripts) and the
# seed corpus at build time, so the runtime image needs no `db/` or `data/`
# tree. `src/` still ships whole: the assistant skill corpora
# (`src/assistant/*/skills/`) are read from it at runtime, and the
# `__DIR__`-relative config resolution (`/app/config.{APP_ENV}.yml`) and the
# runtime `shard.yml` version read need the files in place. This trio
# (`/app/facet`, `/app/src`, `/app/shard.yml`) is load-bearing — see
# doc/plans/container-release.md §7.
COPY --from=build /app/facet /app/facet
COPY --from=build /app/src ./src
COPY --from=build /app/shard.yml /app/shard.yml

# The config template the entrypoint renders from when
# /app/config.{APP_ENV}.yml is absent. A mounted file or FACET_CONFIG_FILE
# always wins over the render.
COPY docker/config.production.example.yml /app/config.production.example.yml
COPY docker/backend-entrypoint.sh /usr/local/bin/backend-entrypoint.sh

# Pre-create the artifact store root: a named volume mounted at /data
# inherits the ownership of this directory on first use.
RUN chmod +x /usr/local/bin/backend-entrypoint.sh \
  && mkdir -p /data/store \
  && chown -R facet:facet /app /data

USER facet

# Kemal binds 0.0.0.0:3000 by default; SIGTERM drains HTTP and WebSockets
# (src/app/shutdown.cr), so no custom stop signal is needed.
EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -f http://127.0.0.1:3000/Healthcheck || exit 1

ENTRYPOINT ["/usr/local/bin/backend-entrypoint.sh"]
CMD ["server"]
