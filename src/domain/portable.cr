# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Namespace root for portable-domain import/export.
#
# The portable-domain service captures a domain's **definition** — its
# `core.Domain` document, every `core.DocType` definition, every owned
# `core.DocumentView` template, and every **general** (shared, owner-less)
# `core.CollectionView` — into a versioned bundle that can be written to
# disk (as a directory or `.tar.gz`) and re-imported into another Facet
# instance. Document data is **not** portable; only the schema definition is.
#
# See `doc/backend/portable-domains.md`.

require "./portable/archive"
require "./portable/export"
require "./portable/import"
require "./portable/cli"
require "./portable/export_job"
require "./portable/import_job"
require "./portable/routes"
