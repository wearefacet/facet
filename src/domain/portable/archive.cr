# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Bundle archive for portable-domain import and export.
#
# One concept per file:
#
# - `bundle` — the bundle model, the format constants, and the entry records.
# - `writer` — the directory, tarball, and zip writers, with the YAML emitter.
# - `reader` — the directory, tarball, and zip readers, with the archive IO
#   and slug helpers.
# - `yaml_encode` — the YAML to JSON conversion call point, backed by
#   `Util::YamlJson`.
#
# See `doc/backend/portable-domains.md`.

require "./archive/bundle"
require "./archive/writer"
require "./archive/reader"
require "./archive/yaml_encode"
