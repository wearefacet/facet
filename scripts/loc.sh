#!/usr/bin/env bash
#
# Count lines of code with cloc, excluding dependencies and generated output:
#   lib/                    Crystal shards (third-party)
#   frontend/node_modules/  npm/pnpm deps (incl. node_modules/.pnpm)
#   frontend/.svelte-kit/   SvelteKit generated output
#   packages/*/node_modules/  npm/pnpm deps (incl. node_modules/.pnpm)
#   packages/*/dist/        Bundled JS output (not hand-written code)
#   build/                  Compiled Crystal binary output
#   tmp/                    Scratch files
#   data/                   Fixtures and seeds (content data, not code)
#
# Usage:
#   ./scripts/loc.sh                 # count all languages
#   ./scripts/loc.sh --by-file       # per-file breakdown
#   ./scripts/loc.sh crystal         # only Crystal
#   ./scripts/loc.sh --lang=js       # only JavaScript (shorthand)
#   ./scripts/loc.sh --all           # count everything (no excludes)
#
# Assumes: cloc on PATH.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LANG_FILTER=""
ALL=0
EXTRA_ARGS=()

# ── Arg parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
	case "$arg" in
		--all)
			ALL=1
			;;
		--by-file)
			EXTRA_ARGS+=(--by-file)
			;;
		--lang=*)
			LANG_FILTER="${arg#--lang=}"
			;;
		-h|--help)
			echo "Usage: $0 [--by-file] [--all] [--lang=<name>|crystal|js|svelte|html|sql|lua|ts]"
			echo
			echo "Count lines of code with cloc, excluding dependencies and generated output."
			echo
			echo "Options:"
			echo "  --by-file    Per-file breakdown instead of per-language summary"
			echo "  --all        Count everything (no excludes)"
			echo "  --lang=<n>   Only count the given language"
			echo "  crystal      Shorthand for --lang=Crystal"
			echo "  js           Shorthand for --lang=JavaScript"
			echo "  ts           Shorthand for --lang=TypeScript"
			echo "  svelte       Shorthand for --lang=Svelte"
			echo "  html         Shorthand for --lang=HTML"
			echo "  sql          Shorthand for --lang=SQL"
			echo "  lua          Shorthand for --lang=Lua"
			exit 0
			;;
		*)
			case "$arg" in
				crystal) LANG_FILTER="Crystal" ;;
				js) LANG_FILTER="JavaScript" ;;
				ts) LANG_FILTER="TypeScript" ;;
				svelte) LANG_FILTER="Svelte" ;;
				html) LANG_FILTER="HTML" ;;
				sql) LANG_FILTER="SQL" ;;
				lua) LANG_FILTER="Lua" ;;
				*)
					echo "Unknown option: $arg" >&2
					echo "Try '$0 --help' for usage." >&2
					exit 1
					;;
			esac
			;;
	esac
done

# ── Excludes ──────────────────────────────────────────────────────────────
# --exclude-dir matches directory basenames anywhere in the tree; the
# --not-match-d regex (with --fullpath) catches paths that span multiple
# directory levels, e.g. node_modules/.pnpm/**.
#
# NOTE: "lib" is deliberately NOT in --exclude-dir: that option matches
# basenames at any depth, so it would also drop frontend/src/lib/ (real
# code). The top-level ./lib/ shards directory is excluded only via the
# anchored ^./lib/ alternative in the regex below.
#
# The regex anchors each word to whole path segments (leading "/" and
# trailing "/") so bare words like "build", "tmp" or "data" do not
# match substrings inside legit paths, e.g. src/assistant/domain_builder/
# (the "build" substring).
EXCLUDES="node_modules,.svelte-kit,build,tmp,data,dist"
NOT_MATCH='(^./lib/|/(node_modules|\.svelte-kit|build|tmp|data|dist)/)'

# ── Build the command ─────────────────────────────────────────────────────
ARGS=(.)

if [ "$ALL" -eq 0 ]; then
	ARGS+=(--exclude-dir="$EXCLUDES" --fullpath --not-match-d="$NOT_MATCH")
fi

if [ -n "$LANG_FILTER" ]; then
	ARGS+=(--include-lang="$LANG_FILTER")
fi

ARGS+=("${EXTRA_ARGS[@]}")

# ── Run ───────────────────────────────────────────────────────────────────
cd "$ROOT_DIR"
exec cloc "${ARGS[@]}"
