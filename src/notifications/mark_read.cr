# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../database"

module Facet
  module Notification
    # Dismissal paths: mark one notification as read, or every unread
    # notification for an account at once.
    module MarkRead
      # Mark one notification as read (by id, scoped to the account, so
      # a user cannot mark another user's notification).
      #
      # Idempotent: the `read_at IS NULL` guard makes a re-mark a
      # no-op and preserves the first `read_at`. Returns true only
      # when an unread, owned row was transitioned; false for an
      # unknown id, a not-owned id, or an already-read notification.
      def self.mark_read(db : DB::Connection, account_id : String, id : String) : Bool
        raise ArgumentError.new("Notification account_id is required") if account_id.blank?
        raise ArgumentError.new("Notification id is required") if id.blank?

        db.exec(
          "UPDATE notifications SET read_at = now()
           WHERE account_id = $1 AND id = $2 AND read_at IS NULL",
          account_id, id,
        ).rows_affected > 0
      end

      # Mark every unread notification for the account as read.
      # Returns the count of rows affected — 0 when none were unread,
      # so a second call is a no-op.
      def self.mark_all_read(db : DB::Connection, account_id : String) : Int32
        raise ArgumentError.new("Notification account_id is required") if account_id.blank?

        db.exec(
          "UPDATE notifications SET read_at = now()
           WHERE account_id = $1 AND read_at IS NULL",
          account_id,
        ).rows_affected.to_i32
      end
    end
  end
end
