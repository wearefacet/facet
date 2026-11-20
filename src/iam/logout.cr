# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module IAM
    # Handles session logout.
    module Logout
      # Logs out a session by deleting it from Redis and writing a logout event.
      #
      # * `db` — database connection
      # * `session_id` — the Redis session ID to delete
      def self.call(db : DB::Connection, session_id : String) : Nil
        session = RedisSession.load(session_id)
        if session
          RedisSession.delete(session_id)
          Helpers.write_login_event(db, session.account_id, "logout", "Session: #{session_id}")
        end
      end
    end
  end
end
