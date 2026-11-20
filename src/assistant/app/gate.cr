# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"
require "json"

require "../../rbac/auth_context"
require "../access"

module Facet
  module Assistant
    module App
      # Availability gate for the app assistant.
      #
      # Availability is the AND of two questions, each with one owner: does
      # this app offer an assistant (`assistant_enabled` on the app), and
      # may this account use assistants (`assistant_access` on the active
      # role, `Assistant::Access.allowed?` — the same flag the in-facet
      # assistant reads).
      #
      # The app projection is read live on every check — the same read the
      # grant resolution runs — so a flip of the flag applies on the next
      # create and on the next streamed message. No cache sits in between.
      #
      # The gate also refuses a caller whose token does not name the
      # targeted app. A main-app session user carries no `app_id`, and an
      # app token for a different app fails the match. The assistant runs
      # only on the app's own token, so every tool call inherits the app's
      # grant ceiling — the boundary guarantee of the design.
      module Gate
        # Loads the app's projection content live. Returns `nil` when the id
        # names no live `app.App` row (absent or tombstoned).
        def self.load_app(db : DB::Connection, app_id : String) : JSON::Any?
          db.query_one?(
            "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
            app_id,
            as: JSON::Any,
          )
        end

        # The full gate. `app_id` is the app the surface targets — the
        # caller's own app id on the create route, the conversation's
        # stored id on the stream route. Returns `false` when the caller's
        # token names another app (or no app), the app is absent, the flag
        # is off, or the active role lacks `assistant_access`. A missing
        # flag reads as off, like every role flag.
        def self.allowed?(db : DB::Connection, auth_context : RBAC::AuthContext, app_id : String) : Bool
          return false unless auth_context.app_id == app_id

          content = load_app(db, app_id)
          return false unless content
          return false unless content["assistant_enabled"]?.try(&.as_bool?) == true

          Access.allowed?(db, auth_context)
        end
      end
    end
  end
end
