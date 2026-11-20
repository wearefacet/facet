# The release frontend image — ghcr.io/wearefacet/facet-frontend.
#
# A production SvelteKit build served by the @sveltejs/adapter-node Node
# server (`node build`). TLS shims are NOT baked: internal release traffic
# is plain HTTP inside the compose network — the e2e shims
# (e2e/stack/node-runtime-shims.cjs) relax certificate checks for the
# internal-CA localhost stack only.
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
# Dependency layer first so source edits do not re-install node_modules.
# BACKEND_URL is deliberately NOT set here — the SSR /Api rewrite reads it
# at runtime ($env/dynamic/private), nothing is baked at build time.
FROM node:24-bookworm-slim AS build
LABEL org.opencontainers.image.licenses="BUSL-1.1"
RUN npm install -g pnpm@10.30.3
ENV NODE_OPTIONS=--max-old-space-size=4096
WORKDIR /workspace/frontend

COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml frontend/.npmrc ./
RUN pnpm install --frozen-lockfile

# The SvelteKit config lives inline in vite.config.ts — there is no
# svelte.config.js.
COPY frontend/vite.config.ts frontend/tsconfig.json ./
COPY frontend/src ./src
COPY frontend/static ./static
COPY frontend/messages ./messages
COPY frontend/project.inlang ./project.inlang
RUN pnpm build

# ── Production dependency stage ────────────────────────────────────────────
#
# Vite externalizes the package.json `dependencies` for the SSR build (the
# server chunks import them bare), and adapter-node's documented deployment
# ships them next to the build output. Production-only install — no dev
# tooling rides in the runtime image.
FROM node:24-bookworm-slim AS prod-deps
RUN npm install -g pnpm@10.30.3
WORKDIR /workspace/frontend
COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml frontend/.npmrc ./
RUN pnpm install --prod --frozen-lockfile

# ── Runtime stage ───────────────────────────────────────────────────────────
#
# The adapter-node output is self-contained (the server and every dependency
# bundle into build/server). The image's built-in non-root `node` user runs
# it; nothing else from the build tree ships.
FROM node:24-bookworm-slim AS runtime
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet frontend" \
      org.opencontainers.image.description="Facet frontend server — SvelteKit (adapter-node)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"

WORKDIR /app

# Production SvelteKit derives the SSR request origin from these headers
# (read at runtime, not build time): behind Caddy the scheme and host ride
# X-Forwarded-Proto and Host.
ENV PROTOCOL_HEADER=x-forwarded-proto \
    HOST_HEADER=host \
    HOST=0.0.0.0 \
    PORT=3000 \
    NODE_OPTIONS=--max-old-space-size=2048

# The adapter-node deployment surface: the build output, the package
# manifest ("type": "module" detection + dependency metadata), and the
# production node_modules the SSR chunks import (see the prod-deps stage).
COPY --from=build --chown=node:node /workspace/frontend/package.json ./package.json
COPY --from=prod-deps --chown=node:node /workspace/frontend/node_modules ./node_modules
COPY --from=build --chown=node:node /workspace/frontend/build ./build

USER node

# adapter-node binds HOST:PORT from the env. The HEALTHCHECK probe is a
# bare `node -e` fetch — no extra package on the slim image. Any status
# below 500 passes: the auth hook answers an anonymous caller with a
# redirect (303) or a 403, which still proves the server serves; demanding
# 200 would fail on the login redirect.
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"

EXPOSE 3000

CMD ["node", "build"]
