# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Regenerates `doc/api/openapi.json` — the committed OpenAPI artifact the CI
# drift job diffs (`openapi-drift` job in `.github/workflows/ci.yml`).
#
# DB-free by design: the route modules below register closures into the
# in-memory Kemal radix tree at register time — no database connection is
# opened and no config file is loaded. Requiring `src/http/openapi` defines
# the served `GET /Api/openapi.json` route (the `register` call happens in
# `HTTP::Server.routes`); that route is excluded from the drift walk by the
# module itself.
#
# Usage: crystal run scripts/gen_openapi.cr [output-path]
# The drift check fails the script loudly when the declarations no longer
# match the registered routes.

require "kemal"
require "../src/http/openapi"
require "../src/document/routes"
require "../src/audit"
require "../src/iam"
require "../src/settings"
require "../src/http/secrets_routes"
require "../src/import_export/routes"
require "../src/index/routes"
require "../src/artifact/purge"
require "../src/artifact/routes"
require "../src/system_settings/routes"

Facet::Document::Routes.register
Facet::Audit::Routes.register
Facet::IAM::Routes.register
Facet::HTTP::SecretsRoutes.register
Facet::ImportExport::Routes.register
Facet::Index::Routes.register
Facet::Artifact::Routes.register
Facet::SystemSettings::Routes.register

issues = Facet::HTTP::OpenAPI.drift_check
unless issues.empty?
  issues.each { |issue| STDERR.puts "openapi drift: #{issue}" }
  abort "OpenAPI drift: declared routes do not match the Kemal route table (#{issues.size} issue(s))"
end

output = ARGV[0]? || File.join(__DIR__, "..", "doc", "api", "openapi.json")
File.write(output, Facet::HTTP::OpenAPI.spec_json)
puts "wrote #{output} (#{Facet::HTTP::OpenAPI.spec_json.bytesize} bytes, #{Facet::HTTP::OpenAPI.declared_routes.size} declared operations)"
