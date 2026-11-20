# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../document/update"

module Facet
  module IAM
    # Flips account document fields with the system principal — the same
    # pattern the invite flow uses for status flips. The human-facing audit
    # trail lives in `iam.LoginEvent` rows; the mutation log records the
    # content change like any other document update.
    module AccountPatch
      # Applies a partial patch to an `iam.Account` document.
      #
      # `Document::Update` treats a no-op patch as success, so repeated
      # flips are safe. The patch only carries document fields — secret
      # material goes through the `Secrets` store, never through here.
      def self.call(
        db : DB::Connection,
        account_id : String,
        patch : Hash(String, JSON::Any),
      ) : Document::Update::Result | Facet::ServiceError
        Document::Update.call(db, "iam", "Account", account_id, patch.to_json,
          RBAC::AuthContext.system(account_id))
      end

      # Convenience overload taking a raw JSON object body.
      def self.call(
        db : DB::Connection,
        account_id : String,
        patch : String,
      ) : Document::Update::Result | Facet::ServiceError
        Document::Update.call(db, "iam", "Account", account_id, patch,
          RBAC::AuthContext.system(account_id))
      end
    end
  end
end
