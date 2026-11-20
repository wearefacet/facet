# Third-party licenses

This file lists third-party software that Facet bundles or ships. Each component keeps its own license. The NOTICE file references this list.

## Shards (Crystal)

The table lists every shard in `shard.lock` (30). Versions and source URLs come from `shard.lock`. License strings come from the `license` field in each installed `lib/<name>/shard.yml`.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| agent-cr | 0.1.0+git.commit.1c009f7c4f4df6b7e89563fcd162b6a59d5dd4cb | MIT | https://github.com/anykeyh/agent.cr.git |
| ameba | 1.7.0 | MIT | https://github.com/crystal-ameba/ameba.git |
| awscr-s3 | 0.8.3 | MIT | https://github.com/taylorfinnell/awscr-s3.git |
| awscr-signer | 0.8.2 | MIT | https://github.com/taylorfinnell/awscr-signer.git |
| backtracer | 1.2.4 | MIT | https://github.com/sija/backtracer.cr.git |
| bindata | 3.2.1 | MIT | https://github.com/spider-gazelle/bindata.git |
| carbon | 0.6.1 | MIT | https://github.com/luckyframework/carbon.git |
| carbon_smtp_adapter | 0.5.0 | MIT | https://github.com/luckyframework/carbon_smtp_adapter.git |
| content_disposition | 1.2.0 | MIT | https://github.com/jetrockets/content_disposition.cr.git |
| crinja | 0.9.0 | Apache-2.0 | https://github.com/straight-shoota/crinja.git |
| cron_parser | 0.4.0 | MIT | https://github.com/kostya/cron_parser.git |
| db | 0.14.0 | MIT | https://github.com/crystal-lang/crystal-db.git |
| ed25519 | 1.1.0 | MIT | https://github.com/spider-gazelle/ed25519.git |
| email | 0.7.1 | MIT | https://github.com/arcage/crystal-email.git |
| exception_page | 0.5.0 | MIT | https://github.com/crystal-loot/exception_page.git |
| habitat | 0.4.9 | MIT | https://github.com/luckyframework/habitat.git |
| jwt | 1.7.2 | MIT | https://github.com/crystal-community/jwt.git |
| kemal | 1.14.0 | MIT | https://github.com/kemalcr/kemal.git |
| lua | 0.4.0+git.commit.c5e3e09c5e9857414306bbe1fd56937cf1a87902 | MIT | https://github.com/veelenga/lua.cr.git |
| lucky_task | 0.3.0 | MIT | https://github.com/luckyframework/lucky_task.git |
| lucky_template | 0.2.0 | MIT | https://github.com/luckyframework/lucky_template.git |
| mpsc | 0.1.0+git.commit.62869371a53eeaff95bc9abe282788947a9aaf5d | MIT | https://github.com/jgaskins/mpsc.git |
| openssl_ext | 2.8.5 | MIT | https://github.com/spider-gazelle/openssl_ext.git |
| opentelemetry | 0.3.5 | MIT | https://github.com/jgaskins/opentelemetry.git |
| pg | 0.30.0 | BSD-3-Clause | https://github.com/will/crystal-pg.git |
| protobuf | 2.3.1 | MIT | https://github.com/jeromegn/protobuf.cr.git |
| radix | 0.4.1 | MIT | https://github.com/luislavena/radix.git |
| redis | 0.16.0 | MIT | https://github.com/jgaskins/redis.git |
| shrine | 0.6.5 | MIT | https://github.com/jetrockets/shrine.cr.git |
| wordsmith | 0.5.0 | MIT | https://github.com/luckyframework/wordsmith.git |

Notes:

- `bindata`, `ed25519`, and `pg` do not set a `license` field in `shard.yml`. Their licenses come from the `LICENSE` file in each repository (default branch): `bindata` and `ed25519` are MIT; `pg` is BSD-3-Clause.
- `lua` is `veelenga/lua.cr` at a pinned commit; the fork fixes landed upstream. Its installed `shard.yml` declares MIT.

## npm packages

The tables list the direct dependencies of the three package manifests. Versions are the installed versions in each `node_modules` folder. `Kind` is `runtime` for `dependencies` and `development` for `devDependencies`. Transitive dependencies are not listed.

### frontend/package.json

| Package | Version | License | Kind |
| --- | --- | --- | --- |
| @codemirror/autocomplete | 6.20.3 | MIT | runtime |
| @codemirror/commands | 6.10.4 | MIT | runtime |
| @codemirror/lang-markdown | 6.5.0 | MIT | runtime |
| @codemirror/language | 6.12.3 | MIT | runtime |
| @codemirror/language-data | 6.5.2 | MIT | runtime |
| @codemirror/legacy-modes | 6.5.3 | MIT | runtime |
| @codemirror/lint | 6.9.7 | MIT | runtime |
| @codemirror/search | 6.7.1 | MIT | runtime |
| @codemirror/state | 6.7.0 | MIT | runtime |
| @codemirror/view | 6.43.2 | MIT | runtime |
| @lezer/highlight | 1.2.3 | MIT | runtime |
| @lucide/svelte | 1.21.0 | ISC | runtime |
| @milkdown/crepe | 7.22.1 | MIT | runtime |
| @milkdown/kit | 7.22.1 | MIT | runtime |
| bits-ui | 2.18.1 | MIT | runtime |
| codemirror | 6.0.2 | MIT | runtime |
| highlight.js | 11.11.1 | BSD-3-Clause | runtime |
| luaparse | 0.3.1 | MIT | runtime |
| marked | 16.4.2 | MIT | runtime |
| mermaid | 11.16.0 | MIT | runtime |
| svelte-codemirror-editor | 2.1.0 | MIT | runtime |
| uqr | 0.1.3 | MIT | runtime |
| @chromatic-com/storybook | 5.2.1 | MIT | development |
| @eslint/compat | 2.1.1 | Apache-2.0 | development |
| @eslint/js | 10.0.1 | MIT | development |
| @inlang/paraglide-js | 2.20.0 | MIT | development |
| @playwright/test | 1.61.0 | Apache-2.0 | development |
| @storybook/addon-a11y | 10.4.6 | MIT | development |
| @storybook/addon-docs | 10.4.6 | MIT | development |
| @storybook/addon-svelte-csf | 5.1.2 | MIT | development |
| @storybook/addon-vitest | 10.4.6 | MIT | development |
| @storybook/sveltekit | 10.4.6 | MIT | development |
| @sveltejs/adapter-node | 5.5.7 | MIT | development |
| @sveltejs/kit | 2.65.2 | MIT | development |
| @sveltejs/vite-plugin-svelte | 7.1.2 | MIT | development |
| @tailwindcss/vite | 4.3.1 | MIT | development |
| @types/js-yaml | 4.0.9 | MIT | development |
| @types/luaparse | 0.2.13 | MIT | development |
| @types/node | 22.19.21 | MIT | development |
| @vitest/browser | 4.1.9 | MIT | development |
| @vitest/browser-playwright | 4.1.9 | MIT | development |
| eslint | 10.11.0 | MIT | development |
| eslint-config-prettier | 10.1.8 | MIT | development |
| eslint-plugin-svelte | 3.23.0 | MIT | development |
| globals | 17.13.0 | MIT | development |
| js-yaml | 5.0.0 | MIT | development |
| playwright | 1.61.0 | Apache-2.0 | development |
| prettier | 3.8.4 | MIT | development |
| prettier-plugin-svelte | 4.1.1 | MIT | development |
| prettier-plugin-tailwindcss | 0.8.0 | MIT | development |
| storybook | 10.4.6 | MIT | development |
| storybook-dark-mode | 5.0.0 | MIT | development |
| svelte | 5.56.3 | MIT | development |
| svelte-check | 4.6.0 | MIT | development |
| tailwindcss | 4.3.1 | MIT | development |
| typescript | 6.0.3 | Apache-2.0 | development |
| typescript-eslint | 8.71.0 | MIT | development |
| vite | 8.0.16 | MIT | development |
| vitest | 4.1.9 | MIT | development |

### packages/cli/package.json

| Package | Version | License | Kind |
| --- | --- | --- | --- |
| commander | 14.0.3 | MIT | runtime |
| @types/node | 22.20.3 | MIT | development |
| prettier | 3.9.8 | MIT | development |
| typescript | 6.0.3 | Apache-2.0 | development |
| vitest | 4.1.11 | MIT | development |

### e2e/package.json

| Package | Version | License | Kind |
| --- | --- | --- | --- |
| @axe-core/playwright | 4.13.0 | MPL-2.0 | development |
| @playwright/test | 1.61.0 | Apache-2.0 | development |
| @types/node | 24.13.6 | MIT | development |
| typescript | 6.0.3 | Apache-2.0 | development |

## Review flags

None.
