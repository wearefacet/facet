# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../error"
require "../iam/account_patch"
require "../iam/api_key"
require "../iam/helpers"
require "../rbac"
require "./service_accounts"
require "../util/time_helper"

module Facet
  module App
    # App-owned API keys: issue (with rotate), active-key lookup, and revoke,
    # all scoped by the `app_id` column on `api_keys`.
    #
    # An app API key is a row in the existing `api_keys` table issued against
    # the app's service account (`App::ServiceAccounts.ensure`). The row pins
    # `{account: service account, role: service_role_id}` and carries
    # `app_id`. Verification and the request path treat the key exactly like
    # an OAuth app token: effective reach = grant ∩ pinned role, the same
    # `app_scoped` contract.
    #
    # Route-level policy: **one active key per app**. Issuing when an active
    # key exists is a rotation — the old row is revoked and the new one
    # issued in the same transaction. Keys never enter the event log; the
    # one-time raw token is the only disclosure.
    module ApiKeys
      # The freshly issued key. `key` is the raw token — shown exactly once.
      record Issued,
        id : String,
        key : String,
        display_prefix : String,
        service_account_id : String,
        role_id : String

      # The active key row of an app — never contains secret material.
      record Active,
        id : String,
        display_prefix : String,
        role_id : String,
        created_at : Time,
        last_used_at : Time?

      # Issues a key for the app, rotating any active key. Atomic: the
      # service-account provisioning (idempotent), the role sync, the old
      # key's revocation, and the new row share one transaction.
      #
      # Rejected when the app is missing (404), is not a backend app
      # (422), carries no `service_role_id` (422), the service role's
      # connectivity excludes the `api` channel (422), or the app's grants
      # do not intersect the role's permission lines (422) — the role is part
      # of the app document, set from the wizard's permissions step or the
      # app's Settings tab.
      def self.issue(db : DB::Connection, app_id : String) : Issued | Facet::ServiceError
        prelude = load_issue_prelude(db, app_id)
        return prelude if prelude.is_a?(Facet::ServiceError)
        content, role_id, role_content = prelude

        if denial = grant_intersection_gate(content, role_id, role_content)
          return denial
        end

        slug = content["slug"]?.try(&.as_s?) || ""
        display_name = content["name"]?.try(&.as_s?) || slug

        issued = nil
        error = nil

        Database.with_transaction(db, ignore_if_set: true) do |txn|
          ensured = ServiceAccounts.ensure(txn, app_id, slug, display_name, role_id)
          if ensured.is_a?(Facet::ServiceError)
            error = ensured
            next
          end
          account_id = ensured

          # Keep the "exactly one role" invariant: a rotate that picked a
          # different service role re-pins the account in the same
          # transaction.
          account = IAM::Helpers.find_account_by_id(txn, account_id)
          if account && (account[:roles] != [role_id])
            patch = {
              "roles"        => [role_id],
              "default_role" => role_id,
            }.to_json
            result = IAM::AccountPatch.call(txn, account_id, patch)
            if result.is_a?(Facet::ServiceError)
              error = Facet::ServiceError.new(500, "Service account role sync failed")
              next
            end
          end

          # Rotation: one active key per app, revoked and replaced here.
          revoke_active(txn, app_id)

          created = IAM::ApiKey.generate(
            txn,
            account_id,
            role_id,
            key_name(slug),
            nil,
            app_id,
          )

          IAM::Helpers.write_login_event(
            txn,
            account_id,
            "api_key_created",
            "App=#{slug} Role=#{role_id} Prefix=#{created.display_prefix}",
            app: app_id,
          )

          issued = Issued.new(
            id: created.id,
            key: created.key,
            display_prefix: created.display_prefix,
            service_account_id: account_id,
            role_id: role_id,
          )
        end

        return error.as(Facet::ServiceError) if error
        issued.as(Issued)
      end

      # Loads the app's active key row, if any. Never exposes the secret.
      def self.active_key(db : DB::Connection, app_id : String) : Active?
        db.query_one?(
          <<-SQL,
            SELECT id, display_prefix, role_id, created_at, last_used_at
            FROM api_keys
            WHERE app_id = $1 AND revoked_at IS NULL
            ORDER BY created_at DESC
            LIMIT 1
          SQL
          app_id
        ) do |rs|
          Active.new(
            id: rs.read(String),
            display_prefix: rs.read(String),
            role_id: rs.read(String),
            created_at: rs.read(Time),
            last_used_at: rs.read(Time?),
          )
        end
      end

      # Soft-revokes every active key row of the app. Idempotent: a second
      # call returns `false`. Returns `true` when this call revoked a row.
      def self.revoke(db : DB::Connection, app_id : String) : Bool
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          revoke_active(txn, app_id)
        end
      end

      # ── Private ────────────────────────────────────────────────────────

      # Loads and validates the app + its service role ahead of issuance:
      # the app exists, is a backend app, and its `service_role_id` names a
      # live role whose connectivity carries the `api` channel. Returns the
      # prelude ({content, role_id, role_content}) or the ServiceError to
      # answer with.
      private def self.load_issue_prelude(db : DB::Connection, app_id : String) : {Hash(String, JSON::Any), String, JSON::Any} | Facet::ServiceError
        app = load_app(db, app_id)
        return Facet::ServiceError.new(404, "App not found") unless app

        content = app[:content].as_h
        return Facet::ServiceError.new(422, "App is not a backend app") unless content["client_type"]?.try(&.as_s?) == "confidential"

        role_id = content["service_role_id"]?.try(&.as_s?)
        return Facet::ServiceError.new(422, "Service role is not set") unless role_id
        role_content = IAM::Helpers.find_role_content(db, role_id)
        return Facet::ServiceError.new(422, "Service role is not set") unless role_content
        if denial = role_api_gate(role_content)
          return denial
        end

        {content, role_id, role_content}
      end

      # The connectivity gate for issuance: nil when the role's list
      # carries `api`, else the 422. A missing or malformed list reads as
      # empty — fail closed.
      private def self.role_api_gate(role_content : JSON::Any) : Facet::ServiceError?
        channels = role_content["connectivity"]?.try(&.as_a?) || return role_api_denial
        return nil if channels.any?(&.as_s?.try(&.==("api")))

        role_api_denial
      end

      private def self.role_api_denial : Facet::ServiceError
        Facet::ServiceError.new(422,
          "The service role's connectivity excludes the 'api' channel — enable it on the role first")
      end

      # The issuance-time grant ∩ role gate. A key whose grant intersection
      # with the role is empty verifies but refuses every request with a
      # bare 401 (the request path fails closed on `EffectiveScope.empty?`),
      # so the operator learns about it only at runtime. Refuse the issuance
      # instead, and name the remedy. Runs only when both sides exist — an
      # app with no grants, or a role with no permission lines, has no
      # intersection to check.
      private def self.grant_intersection_gate(
        content : Hash(String, JSON::Any),
        role_id : String,
        role_content : JSON::Any,
      ) : Facet::ServiceError?
        app_scope = RBAC::AppScope.from_content("", JSON::Any.new(content))
        return nil if app_scope.grants.empty?

        active_role = RBAC::ActiveRole.from_projection_content(role_content)
        return nil if active_role.permissions.empty?

        return nil unless RBAC::GrantResolver.resolve(app_scope, active_role).empty?

        Facet::ServiceError.new(422, grant_intersection_message(app_scope, role_id))
      rescue ArgumentError
        nil
      end

      # Names the problem and the remedy: the role line that reaches the
      # grant target. A domain-wide role line (`fin`) has an empty path and
      # never covers a concrete grant target — the grant is the ceiling, and
      # the intersection needs the target repeated on the role side.
      private def self.grant_intersection_message(app_scope : RBAC::AppScope, role_id : String) : String
        remedies = app_scope.grants.map do |grant|
          %({"on": "#{grant.target}", "action": "*"})
        end
        remedies.uniq!
        "The app's grants do not intersect the service role #{role_id}'s permissions — " \
        "the key would be refused at every request. Repeat each grant target as a concrete " \
        "role permission line (e.g. #{remedies.join(", ")}) or widen the role."
      end

      private def self.load_app(db : DB::Connection, app_id : String) : NamedTuple(id: String, content: JSON::Any)?
        db.query_one?(
          "SELECT id, content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          app_id
        ) do |rs|
          {id: rs.read(String), content: rs.read(JSON::Any)}
        end
      end

      private def self.revoke_active(db : DB::Connection, app_id : String) : Bool
        result = db.exec(
          "UPDATE api_keys SET revoked_at = now() WHERE app_id = $1 AND revoked_at IS NULL",
          app_id
        )
        result.rows_affected > 0
      end

      private def self.key_name(slug : String) : String
        "app:#{slug}"
      end
    end
  end
end
