# The e2e backend image (harness §3): multi-stage Crystal build over the
# repo. Shards install in their own layer above a thin source layer so
# re-builds are cheap.
#
# Build context: the repository root.
#
# Build args (optional — compose supplies throwaway defaults; they feed
# the OCI version/revision labels only):
#   VERSION   — e.g. a release tag (default dev)
#   REVISION  — the git commit sha (default unknown)

ARG VERSION=dev
ARG REVISION=unknown

FROM crystallang/crystal:1.21.0 AS build
LABEL org.opencontainers.image.licenses="BUSL-1.1"
# The base image carries the usual Crystal link deps but not Lua, which the
# `lua` shard (Lua bindings) needs at link time.
RUN apt-get update \
  && apt-get install -y --no-install-recommends liblua5.4-dev \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install

COPY src ./src
# Migrations, Lua event scripts, and the seed corpus are embedded into the
# binary at compile time (`Migrate::MIGRATION_SOURCES`, `Seed::SEED_FILES`,
# `Stream::LOCK_SHARDS_SCRIPT`) — the build stage needs `db/` and `data/`
# next to `src/` for the `read_file` macros to resolve.
COPY db ./db
COPY data ./data
# `--link-flags=-Wl,--no-export-dynamic`: the debug (non-release) build is
# multi-module, so Crystal links it with `-rdynamic` and GNU ld turns every
# `@` in a mangled name into an ELF symbol version. Past ~32767 versions the
# 15-bit `.gnu.version` index overflows and the loader resolves libc symbols
# (environ, __libc_start_main) against bogus method names — the same class of
# failure as the spec binary (`make test`), which also links with this flag.
# See crystal-lang/crystal#13193. A release build is single-module and immune;
# this image deliberately builds unoptimized (see the runtime stage note).
RUN crystal build src/main.cr --link-flags=-Wl,--no-export-dynamic -o /app/facet

FROM crystallang/crystal:1.21.0
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet" \
      org.opencontainers.image.description="Facet backend server — document store with event sourcing" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"
# curl feeds the compose healthcheck; liblua5.4 matches the linked shard
# (the build stage compiles against it, the runtime loads it).
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl liblua5.4 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The compiled binary embeds `db/` (migrations, Lua event scripts) and the
# seed corpus at build time, so the runtime image needs no `db/` tree.
# `src/` still ships whole: the assistant skill corpora
# (`src/assistant/*/skills/`) are read at runtime, and the `__DIR__`-relative
# config resolution (`<root>/config.e2e.yml`) needs the intermediate
# directories to exist (~4 MB). `data/` carries the e2e fixture bundle the
# entrypoint imports. The dev binary (`make build`) ships unoptimized too —
# the harness binary builds without `--release`, so the served behaviour
# under test matches day-to-day development.
COPY --from=build /app/facet /app/facet
COPY --from=build /app/src ./src

COPY data ./data
COPY e2e/docker/backend-entrypoint.sh /usr/local/bin/backend-entrypoint.sh
COPY e2e/stack/config.e2e.yml.tmpl /app/config.e2e.yml.tmpl

RUN chmod +x /usr/local/bin/backend-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/backend-entrypoint.sh"]
