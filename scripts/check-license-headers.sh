#!/bin/sh
# Fails when a first-party source file misses the SPDX license header.
# First-party trees: src/, spec/, scripts/ (Crystal), db/migrations (SQL),
# frontend TS/JS/Svelte, packages/cli TS, e2e TS. Vendored and generated
# trees (lib/, node_modules/, .svelte-kit/, dist/, build/, tmp/, paraglide)
# are excluded.
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

spdx="SPDX-License-Identifier: BUSL-1.1"
missing=0

# find paths, prune everything vendored or generated
find \
  src spec scripts \
  -type d \( -name node_modules -o -name .svelte-kit -o -name dist \
    -o -name build -o -name tmp -o -name lib \) -prune -o \
  -type f \( -name '*.cr' \) -print \
  > "$$.cr" 2>/dev/null

find db/migrations -type f -name '*.sql' -print > "$$.sql" 2>/dev/null

find \
  frontend/src frontend/.storybook packages/cli/src packages/cli/test \
  e2e/tests e2e/stack \
  -type d \( -name node_modules -o -name .svelte-kit -o -name dist \
    -o -name build -o -name tmp -o -name lib -o -name paraglide \) -prune -o \
  -type f \( -name '*.ts' -o -name '*.js' -o -name '*.svelte' \
    -o -name '*.mjs' -o -name '*.cjs' \) -print \
  > "$$.fe" 2>/dev/null

for f in frontend/vite.config.ts frontend/eslint.config.js \
         e2e/playwright.config.ts; do
  [ -f "$f" ] && echo "$f" >> "$$.fe"
done

check() {
  file="$1"
  if ! head -n 5 "$file" 2>/dev/null | grep -q "SPDX-License-Identifier: BUSL-1.1"; then
    echo "missing SPDX header: $file"
    missing=$((missing + 1))
  fi
}

while IFS= read -r f; do check "$f"; done < "$$.cr"
while IFS= read -r f; do check "$f"; done < "$$.sql"
while IFS= read -r f; do check "$f"; done < "$$.fe"

rm -f "$$.cr" "$$.sql" "$$.fe"

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "$missing file(s) miss the SPDX header. Add:"
  echo "  Crystal / SQL : # SPDX-License-Identifier: BUSL-1.1"
  echo "  TS / JS       : // SPDX-License-Identifier: BUSL-1.1"
  echo "  Svelte        : <!-- SPDX-License-Identifier: BUSL-1.1 -->"
  exit 1
fi

echo "SPDX license headers: OK"
