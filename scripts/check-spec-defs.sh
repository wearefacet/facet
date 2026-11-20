#!/bin/sh
# Fails when a top-level def name is defined in more than one spec file
# unless every definition is `private`.
#
# Why: Crystal top-level defs are program-wide. When two spec files define
# the same name, the last one compiled silently wins — and `crystal spec`
# with no file arguments collects files in unsorted readdir order, so the
# winner differs between a fresh CI checkout and a dev working tree. This
# shadowing produced a CI-only spec failure (the 2-scope copy of an RBAC
# fixture overwrote the 3-scope one).
#
# Rules enforced:
#   - At most ONE file may define a given top-level def name publicly.
#     Shared helpers live once in `spec/support/` — see
#     `doc/backend/workflow.md` (Testing).
#   - A name may repeat across files only when EVERY definition is
#     `private`: a `private def` at top level is file-scoped in Crystal,
#     so each file keeps its own copy with no cross-file resolution.
#   - Repeated defs inside ONE file are overloads — not flagged.
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

# Collect: <visibility>\t<name>\t<file> for every column-0 def in the spec tree.
defs=$(find spec -type f -name '*.cr' -print0 | xargs -0 grep -nE '^(private[[:space:]]+)?def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null \
  | awk -F':' '{ file=$1; line=$2; sub(/^[^:]*:[^:]*:/, ""); sig=$0
      vis="public"; if (sig ~ /^private[[:space:]]+/) vis="private"
      name=sig; sub(/^private[[:space:]]+/, "", name); sub(/^def[[:space:]]+/, "", name); sub(/[[:space:]*(.].*$/, "", name)
      if (name != "") print vis "\t" name "\t" file }')

if [ -z "$defs" ]; then
  echo "check-spec-defs: no top-level defs found under spec/ — nothing to check" >&2
  exit 1
fi

# A name is in conflict when it is defined publicly in more than one file.
# (Private defs are file-scoped; any number of them is safe. Repeated defs
# within one file are overloads — dedupe to one file per name first.)
violations=$(printf '%s\n' "$defs" | awk -F'\t' '
  { key = $2 "\t" $3; if (!(key in seen)) { seen[key] = 1; files[$2] = files[$2] "\n  " $3; pub[$2] += ($1 == "public") ? 1 : 0 } }
  END {
    rc = 0
    for (name in pub) if (pub[name] > 1) { print name files[name]; rc = 1 }
    exit rc
  }')

if [ $? -ne 0 ]; then
  echo "check-spec-defs: top-level def name defined publicly in more than one spec file:" >&2
  echo "$violations" >&2
  echo "" >&2
  echo "Crystal top-level defs are program-wide; the last one compiled wins, and" >&2
  echo "spec file order is unsorted readdir order (differs between CI and dev)." >&2
  echo "Fix: keep one shared definition in spec/support/, or mark every copy" >&2
  echo "\`private\` (file-scoped). See doc/backend/workflow.md - Testing." >&2
  exit 1
fi

exit 0
