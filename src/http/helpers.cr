# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"
require "json"
require "../database"
require "../util/projections"
require "../util/pg_error"
require "./auth_handler"
require "./list_request"
require "./responders"
require "./gates"
require "./caching"
require "../document/row_access"
require "../iam/api_key"
require "../iam/helpers"

module Facet
  module HTTP
    # Facade for the shared route-handler helpers. The implementations
    # live in `Responders` (JSON and error writing), `Gates` (request
    # gates), and `Caching` (ETag validators and fingerprints). The
    # document-store primitives live in `Facet::Document::RowAccess`.
    # `extend` re-exports every method here, so each existing
    # `HTTP::Helpers.x` call site keeps its name and its signature.
    module Helpers
      # Kept for the call sites that log through the `Helpers` namespace.
      HTTP_LOG = Responders::HTTP_LOG

      # The shared list count cap, re-exported so route files can read it
      # through the `Helpers` facade like every other helper.
      COUNT_CAP = Responders::COUNT_CAP

      extend Responders
      extend Gates
      extend Caching
      extend ::Facet::Document::RowAccess
    end
  end
end
