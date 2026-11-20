# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"

module Facet
  module Util
    # Read helpers for PostgreSQL server errors.
    #
    # crystal-pg surfaces server errors as `PQ::PQError`; the server error
    # fields live in `#fields`, and the SQLSTATE is carried under the tag
    # `:code`. One extractor so every caller reads the field the same way
    # (statement timeouts, deadlock retry, constraint matching).
    module PgError
      # Returns the SQLSTATE of *ex*, or `nil` when the field is absent.
      def self.sqlstate(ex : PQ::PQError) : String?
        ex.fields.find(&.name.==(:code)).try(&.message)
      end

      # Returns the constraint name the server reported for *ex*, or `nil`
      # when the field is absent — only constraint/index violations carry it.
      def self.constraint_name(ex : PQ::PQError) : String?
        ex.fields.find(&.name.==(:constraint_name)).try(&.message)
      end

      # Returns the server's `Detail:` line for *ex*, or `nil` when absent.
      # For a unique violation it names the conflicting key and value
      # ("Key (email)=(…) already exists.").
      def self.detail(ex : PQ::PQError) : String?
        ex.fields.find(&.name.==(:detail)).try(&.message)
      end
    end
  end
end
