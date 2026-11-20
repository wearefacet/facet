# The e2e frontend image (harness §3, D5): a production SvelteKit build
# served by `vite preview` (its default :4173 — no adapter-node server
# exists; the adapter stays @sveltejs/adapter-auto).
#
# Build context: the repository root.
#
# Build args (optional — compose supplies throwaway defaults; they feed
# the OCI version/revision labels only):
#   VERSION   — e.g. a release tag (default dev)
#   REVISION  — the git commit sha (default unknown)

ARG VERSION=dev
ARG REVISION=unknown

FROM node:24-bookworm-slim AS build
LABEL org.opencontainers.image.licenses="BUSL-1.1"
RUN npm install -g pnpm@10.30.3
ENV NODE_OPTIONS=--max-old-space-size=4096
WORKDIR /workspace/frontend

# Dependency layer first so source edits do not re-install node_modules.
COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml frontend/.npmrc ./
RUN pnpm install --frozen-lockfile

COPY frontend/vite.config.ts frontend/tsconfig.json ./
COPY frontend/src ./src
COPY frontend/static ./static
COPY frontend/messages ./messages
COPY frontend/project.inlang ./project.inlang
RUN pnpm build

FROM node:24-bookworm-slim
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.licenses="BUSL-1.1" \
      org.opencontainers.image.title="Facet frontend" \
      org.opencontainers.image.description="Facet frontend server — SvelteKit (vite preview)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/wearefacet/facet"

WORKDIR /workspace/frontend

COPY e2e/stack/node-runtime-shims.cjs /usr/local/lib/node-stack-shims.cjs

# Production SvelteKit derives the SSR request origin from these headers
# (envs are read at runtime, not build time); the stack shims let the SSR
# fetch verify Caddy's internal `*.localhost` wildcard and ride the https
# scheme (see the shim file's header comment).
ENV PROTOCOL_HEADER=x-forwarded-proto \
    HOST_HEADER=host \
    NODE_OPTIONS="--max-old-space-size=2048 --require /usr/local/lib/node-stack-shims.cjs"

COPY --from=build /workspace/frontend ./

EXPOSE 4173
CMD ["node_modules/.bin/vite", "preview", "--host", "0.0.0.0", "--port", "4173", "--strictPort"]
