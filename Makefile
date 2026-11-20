# Facet — backend (Crystal) build targets.
#
# These targets wrap the most common Crystal invocations so contributors don't
# have to remember the entry-point path or the exact flags. Backend-only — the
# frontend lifecycle (dev/build/test/storybook) is driven by `pnpm` scripts in
# `frontend/package.json`. For the full dev experience (migrate + backend +
# frontend in parallel) use `./scripts/dev`.
#
# Common targets:
#   make test          # run the Crystal spec suite (fail-fast)
#   make check         # type-check / build without emitting a binary
#   make build         # build dev server binary into build/ (mtime-tracked)
#   make build_release # release-optimized binary into build/facet-release
#   make run           # run the dev server (crystal run, no artifact)
#   make clean         # remove the build/ directory
#   make gen-docs      # regenerate every reference page for the docs site

CRYSTAL   ?= crystal
SRC       := src/main.cr
BUILD_DIR := build
BIN       := $(BUILD_DIR)/facet
BIN_REL   := $(BUILD_DIR)/facet-release
# Precompiled spec binary. `crystal spec` recompiles the whole program
# (~60 s) on every run; this binary compiles once and then accepts the
# runner flags (`-e`, `-l`, `--profile`, ...) for sub-second iteration.
SPEC_BIN  := $(BUILD_DIR)/spec_run

# Crystal is a whole-program compiler — there are no per-file objects to
# track. Make mtime tracking gives the next best thing: no rebuild at all
# when no source changed, and a full rebuild otherwise. The files embedded
# into the binary at compile time (SQL migrations, Lua event scripts, seed
# doctypes, the shard version) join the dependency set so a change to any
# of them triggers a rebuild.
SRCS := $(shell find src lib -name '*.cr' 2>/dev/null)
EMBEDDED := $(shell find db/migrations db/lua data/seeds -type f 2>/dev/null) shard.yml
DEPS := $(SRCS) $(EMBEDDED) shard.lock

.DEFAULT_GOAL := help

# `--fail-fast` aborts the run on the first failing example. Override with
# `make test FAIL_FAST=` when the full failure list is wanted in one pass.
FAIL_FAST ?= --fail-fast

# By default, specs are run with enough debugging information for reading backtrace
# Do not add `--debug` flag unless you want to use gdb. It creates large memory usage.
SPEC_FLAGS ?=

# Explicit, sorted spec file list. `crystal spec` with no arguments collects
# `spec/**/*_spec.cr` in unsorted readdir order, which differs between a
# fresh CI checkout and a long-lived dev tree — compile order then decides
# which same-named top-level def wins (see `make spec_defs_check`). A sorted
# list makes local and CI runs identical and reproducible.
SPEC_FILES := $(shell find spec -type f -name '*_spec.cr' | sort)

# Every file the spec binary compiles: the examples plus their support files
# (`spec_helper.cr`, `spec/support/*`). The binary depends on all of them so
# editing the helper triggers a rebuild — `SPEC_FILES` alone misses it.
SPEC_SRCS := $(shell find spec -type f -name '*.cr' | sort)

.PHONY: help test test_build test_db_up test_db_down check build build_release run clean license_check spec_defs_check docker_images docker_smoke gen-docs gen-docs-rest-api gen-docs-cli gen-docs-field-types gen-docs-filter-operators gen-docs-npm-cli gen-docs-doctype-schema gen-docs-dvt-schema gen-docs-lua gen-docs-agent-tools gen-docs-system-settings gen-docs-config-keys gen-docs-account-settings gen-docs-health-metrics gen-docs-feature-index

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
		/^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# `make test` builds the spec binary first and then runs it as a separate
# process. Beyond the obvious reuse, this keeps the compiler's memory out of
# the test run: Crystal's build process allocates a large amount and does not
# release it, so running the specs in the same process (as `crystal spec`
# does) leaves that footprint in place for the whole suite. Building first
# lets the compiler exit and free everything before the examples start.
test: license_check test_db_up $(SPEC_BIN) ## Run the Crystal spec suite (fail-fast; header check + test database first)
	$(SPEC_BIN) $(FAIL_FAST) $(SPEC_FLAGS)

# Compile the spec suite into a binary (skipped when no source changed).
# Faster iteration: build once, then re-run selections with no compile step.
#
#   make test_build
#   ./build/spec_run -e "Document::Create"
#   ./build/spec_run --profile -e "Document::Update"
#   ./build/spec_run -l spec/document/create_spec.cr:117
#
# `make test` builds this binary, then runs it — same suite, same flags.
test_build: $(SPEC_BIN) ## Compile the spec suite into build/spec_run (no run)

$(SPEC_BIN): $(DEPS) $(SPEC_SRCS)
	@mkdir -p $(BUILD_DIR)
	@echo "Compiling spec suite into $@ ..."
	@$(CRYSTAL) build --no-debug -o $@ $(SPEC_FILES)

test_db_up: ## Start the throwaway PostgreSQL for the spec suite (port 5433)
	docker compose -f compose.test.yml up -d --wait

test_db_down: ## Stop and remove the test PostgreSQL
	docker compose -f compose.test.yml down

check: ## Type-check / build without emitting a binary (--no-codegen)
	$(CRYSTAL) build $(SRC) --no-codegen

license_check: ## Fail when a first-party source file misses the SPDX header
	scripts/check-license-headers.sh

spec_defs_check: ## Fail when a top-level def name is publicly defined in more than one spec file
	scripts/check-spec-defs.sh

build: $(BIN) ## Build the dev server binary into build/ (skipped when up to date)

$(BIN): $(DEPS)
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build $(SRC) -o $@

build_release: $(BIN_REL) ## Release-optimized build into build/

$(BIN_REL): $(DEPS)
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build $(SRC) --release -o $@

run: ## Run the dev server (crystal run, no artifact)
	$(CRYSTAL) run $(SRC) -- server

clean: ## Remove the build/ directory
	rm -rf $(BUILD_DIR)

docker_images: ## Build the release images locally (facet + facet-frontend)
	docker build -f docker/backend.Dockerfile -t facet .
	docker build -f docker/frontend.Dockerfile -t facet-frontend .

docker_smoke: ## Run the smoke stack and its checks against the local images (docker/smoke.sh)
	docker/smoke.sh

# ── Documentation site — reference page generators ────────────────────────
# One target per generated page under site-docs/src/content/docs/reference/.
# Generator scripts live in scripts/gen_docs/ and state their source of
# truth in a header comment. Never hand-edit a generated page; fix the
# generator. `make gen-docs` runs every target; the release workflow runs
# it before the site build (see doc/site-docs.md → Reference generators).

gen-docs: gen-docs-rest-api gen-docs-cli gen-docs-field-types gen-docs-filter-operators gen-docs-npm-cli gen-docs-doctype-schema gen-docs-dvt-schema gen-docs-lua gen-docs-agent-tools gen-docs-system-settings gen-docs-config-keys gen-docs-account-settings gen-docs-health-metrics gen-docs-feature-index ## Regenerate every reference page for the docs site

gen-docs-rest-api: ## Vendor the OpenAPI file the REST API page embeds
	cp doc/api/openapi.json site-docs/public/api/openapi.json

gen-docs-cli: ## Regenerate reference/cli-facet.md from the CLI registry
	$(CRYSTAL) run scripts/gen_docs/cli.cr

gen-docs-field-types: ## Regenerate reference/field-types.md from the field type sources
	$(CRYSTAL) run scripts/gen_docs/field_types.cr

gen-docs-filter-operators: ## Regenerate reference/filter-operators.md from the filter compiler
	$(CRYSTAL) run scripts/gen_docs/filter_operators.cr

gen-docs-npm-cli: ## Regenerate reference/cli-npm.md from the @facetapp/cli help output
	node scripts/gen_docs/npm_cli.mjs

gen-docs-doctype-schema: ## Regenerate reference/doctype-schema.md from the doctype validator
	$(CRYSTAL) run scripts/gen_docs/doctype_schema.cr

gen-docs-dvt-schema: ## Regenerate reference/dvt-schema.md from the view template validator
	$(CRYSTAL) run scripts/gen_docs/dvt_schema.cr

gen-docs-lua: ## Regenerate reference/lua-api.md from the Lua engine doc comments
	$(CRYSTAL) run scripts/gen_docs/lua.cr

gen-docs-agent-tools: ## Regenerate reference/agent-tools.md from the agent tool registry
	$(CRYSTAL) run scripts/gen_docs/agent_tools.cr

gen-docs-system-settings: ## Regenerate reference/system-settings-keys.md from the settings registry
	$(CRYSTAL) run scripts/gen_docs/system_settings.cr

gen-docs-config-keys: ## Regenerate reference/config-keys.md from the config loaders
	$(CRYSTAL) run scripts/gen_docs/config_keys.cr

gen-docs-account-settings: ## Regenerate reference/account-settings-keys.md from the account settings registry
	$(CRYSTAL) run scripts/gen_docs/account_settings.cr

gen-docs-health-metrics: ## Regenerate reference/health-metrics-names.md from healthcheck and metrics
	$(CRYSTAL) run scripts/gen_docs/health_metrics.cr

gen-docs-feature-index: ## Regenerate reference/feature-index.md from the inventory and page front-matter
	node scripts/gen_docs/feature_index.mjs
