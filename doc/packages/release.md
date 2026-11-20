# npm package release

How the npm packages under `packages/` reach the npm registry: a maintainer pushes one git tag, one GitHub Actions workflow runs the gates, builds the package, publishes it to npm with provenance, and opens the GitHub Release.

## Source files

| File | Role |
| ---- | ---- |
| `.github/workflows/release-npm.yml` | The release workflow — tag mapping, guard, gates, build, smoke, publish, GitHub Release |
| `packages/*/package.json` | The metadata the workflow reads and npm requires (`version`, `repository`, `publishConfig.access`, `prepublishOnly` build guard) |

## Release flow

After the version-bump PR merges, a maintainer cuts the release with two commands:

```bash
git tag cli-v0.1.0
git push origin cli-v0.1.0
```

The tag version must equal the `version` in the package's `package.json`. The workflow checks this before any gate runs, so a tag without a version bump fails fast and publishes nothing.

## Tag namespace

One tag starts exactly one release pipeline. Each npm package owns a tag prefix, and the workflow maps the prefix to the package directory (one `case` row per package, at the top of the workflow):

| Tag | Package | Dist-tag |
| ---- | ---- | ---- |
| `sdk-v*` | `@facetapp/sdk` (`packages/sdk`) | `latest` |
| `chat-v*` | `@facetapp/chat` (`packages/chat`) | `latest` |
| `cli-v*` | `@facetapp/cli` (`packages/cli`) | `latest` |

A version that contains a `-` (for example `0.0.2-beta.1`) is a prerelease. It publishes under the `beta` dist-tag and never becomes `latest`.

## Workflow steps

| Step | What it does |
| ---- | ---- |
| Guard | Tag version must equal the `package.json` `version`; a prerelease selects the `beta` dist-tag |
| Install | `pnpm install --frozen-lockfile` (pnpm 10, Node 22) |
| Gates | `pnpm lint`, `pnpm check`, `pnpm test` — the release runs its own gates and does not depend on a previous CI run |
| Build | `pnpm build` (`tsc`; `vite build` + `tsc` for chat) — `dist/` is gitignored, so the tarball needs a fresh build |
| Smoke | CLI start (`node dist/index.js --help`, cli only); `npm pack --dry-run` with a file-list check (all packages) |
| Publish | Upgrade npm to `^11`, then `npm publish --access public --tag <dist-tag>` |
| GitHub Release | `gh release create --verify-tag --generate-notes` |

The tarball check allows only `dist/`, `README.md`, and `LICENSE` (npm always adds `package.json`), and requires `dist/index.js` — the entry point.

## Auth — npm trusted publishing

The workflow holds no npm token. The publish runs through OIDC trusted publishing with `id-token: write`:

- Requires npm ≥ 11.5.1 and Node ≥ 22.14.0. Node 22 bundles npm 10, so the workflow installs `npm@^11` before the publish step.
- Provenance is generated automatically on publishes from GitHub Actions. No flag is needed.
- Fallback: a granular automation token in the `NPM_TOKEN` secret, with `--provenance` on the publish command.

## One-time npm setup

Sequence matters. A trusted-publisher configuration expires 2 days after creation without a first publish, and its settings page exists only after the package is on npm. The sequence applies per package — a package whose first version went out by hand must ship its next version through a tag, because npm rejects a second publish of the same version.

1. One maintainer runs the first publish by hand from the package directory: `npm publish --access public` (2FA). This puts the package on npm.
2. Configure the trusted publisher in the npm console: Packages → the package → Settings → Trusted publishing. Fill in the GitHub organization, the repository, and the workflow filename `release-npm.yml`. Select **Allow npm publish**. The fields are case-sensitive and npm does not validate them at save — a typo shows up only at publish time.
3. Push a rehearsal prerelease tag within 2 days of the configuration. The first workflow publish validates the configuration before it expires.

Recommended hardening: in the npm console, package settings → Publishing access → require two-factor authentication and disallow tokens (trusted publishers keep working through OIDC). In GitHub, a tag ruleset that limits `cli-v*` pushes to maintainers.

## Failure handling

- Every step before publish is safe to re-run: delete the tag and push it again.
- After a successful publish, npm rejects a second publish of the same version. That rejection is the backstop against a double release.
- If only the GitHub Release step fails, create the release by hand. Never re-tag a published version.
