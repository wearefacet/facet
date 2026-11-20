---
title: Releases
description: How Facet versions and ships releases, and where to read the release notes.
audience: [operator, developer]
features: []
sidebar:
  order: 0
verified_at: 7a6cb462
---

Use this page to find out what a release contains and where it lands. One git
tag starts each release, and the tag prefix picks the artifact: `v*` publishes
versioned container images, and a package prefix publishes one npm package.

## How releases work

Facet ships two kinds of artifacts from one repository:

| Artifact | Release trigger | Where it lands |
| --- | --- | --- |
| Container images | a `v*` git tag | GHCR: `ghcr.io/wearefacet/facet`, `ghcr.io/wearefacet/facet-frontend` |
| npm packages | a package tag prefix (`sdk-v*`, `chat-v*`, `cli-v*`) | the npm registry, plus a GitHub Release |

Both release pipelines run their own gates:

- **Container pipeline** — builds and smoke-tests both architectures before
  anything reaches the registry.
- **npm pipeline** — runs lint, type-check, and tests before it publishes.

## Container images

A maintainer pushes a `v*` tag. The release workflow then builds the backend
and frontend images for amd64 and arm64, runs the smoke stack on both
architectures, and publishes:

| Image tag | Meaning |
| --- | --- |
| `X.Y.Z` | One exact release |
| `X.Y` | The latest release in a minor series |
| `latest` | The latest release — release tags only, never branch builds |

A push to `master` publishes the rolling channel: the `master` and `nightly`
image tags move on every green build. A failed smoke gate leaves the registry
untouched.

## npm packages

Each package under `packages/` owns a tag prefix, and one tag starts exactly
one release:

| Tag | Package |
| --- | --- |
| `sdk-v*` | `@facetapp/sdk` |
| `chat-v*` | `@facetapp/chat` |
| `cli-v*` | `@facetapp/cli` |

The tag version must equal the `version` in the package's `package.json`, so a
tag without a version bump publishes nothing. A version with a `-`, for
example `0.0.2-beta.1`, is a prerelease: it publishes under the `beta`
dist-tag and never becomes `latest`. Each release opens a GitHub Release with
generated notes.

## Release notes

Read the notes for each release on its GitHub Release. They start with the
first release.

## Related

- Deploy the release images: [Operate](/operate/)
- The container build and publish pipeline (repo doc):
  [doc/ops/container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md)
- The npm package release flow (repo doc):
  [doc/packages/release.md](https://github.com/wearefacet/facet/blob/main/doc/packages/release.md)
