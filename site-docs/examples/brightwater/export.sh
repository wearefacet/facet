#!/usr/bin/env bash
#
# Rebuild the bundles/ tarballs from the live instance. Run this after you
# change any of the three domain directories, so the committed bundles stay
# in step with them.
#
# The tarballs carry the domain DEFINITIONS only (doctypes, views, hooks,
# scopes) — not the demo data. A fresh instance gets its data from
# load.sh + seed.py, which build it deterministically. Definitions-only
# also keeps account references out of the tarballs: accounts never exist
# in a bundle, and documents would carry ids that mean nothing elsewhere.
#
# Tarballs, not directories: a .facet-domain directory inside this one
# would sit in the dev watcher's watch root and confuse its ownership
# checks. A .tar.gz file is invisible to the watcher.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"

mkdir -p "$DIR/bundles"
for domain in equipment clients rentals; do
    "$REPO_ROOT/scripts/facet" domain:export "$domain" \
        --output "$DIR/bundles/$domain.facet-domain.tar.gz"
    echo "exported bundles/$domain.facet-domain.tar.gz"
done
