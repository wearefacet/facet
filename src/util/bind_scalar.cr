# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Util
    # Coerces a raw JSON value to a `DB::Any`-compatible primitive for
    # parameter binding. Strings, numbers, booleans, and `nil` pass
    # through; other JSON shapes (objects / arrays) stringify — they
    # cannot bind as numeric or boolean, so PostgreSQL then NULLs out the
    # comparison.
    #
    # One coercion for every filter compiler (`FilterSet`,
    # `FilterClauses`), so all of them bind the same way.
    #
    # Lives beside `FilterSet` rather than inside `FilterClauses` because
    # `FilterClauses` depends on `FilterSet`; the reverse dependency would
    # make the require cycle.
    def self.bind_scalar(raw : JSON::Any::Type) : ::DB::Any
      case raw
      when String, Int64, Float64, Bool, Nil
        raw
      else
        raw.to_s
      end
    end
  end
end
