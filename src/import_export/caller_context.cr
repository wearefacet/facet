# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../rbac"
require "../iam/helpers"

module Facet
  module ImportExport
    # Rebuilds an enqueue-time caller identity into an execution-time
    # `RBAC::AuthContext`, shared by the export and import job handlers.
    #
    # Roles, apps, and grants re-read from their live projections when the
    # job runs, so an authorization change between enqueue and execution
    # applies — the same contract the export job holds. A vanished or
    # unusable role, app, or grant raises `Jobs::JobError`: silently
    # downgrading the caller would hide the authorization change.
    module CallerContext
      Log = ::Log.for("facet.import_export.caller_context")

      # The plain identity fields both job payloads carry.
      record Caller,
        account_id : String,
        role_id : String?,
        app_id : String?,
        api_key_id : String?

      def self.rebuild(db : DB::Connection, caller : Caller) : RBAC::AuthContext
        if app_id = caller.app_id
          rebuild_app_scoped(db, caller, app_id) ||
            raise Jobs::JobError.new("Import/export app grant for #{app_id} no longer resolvable")
        elsif api_key_id = caller.api_key_id
          RBAC::AuthContext.api_key(caller.account_id, load_role(db, caller), api_key_id)
        elsif caller.role_id
          RBAC::AuthContext.authenticated(caller.account_id, load_role(db, caller))
        else
          RBAC::AuthContext.system(caller.account_id)
        end
      end

      # The role reference a job payload carries for a real caller: the
      # qualified `iam.Roles` projection id — the exact form
      # `IAM::Helpers.find_role_content` resolves at execution time.
      # `ActiveRole#role_id` is the role's own `name` field (e.g. `admin`),
      # not the reference; the payload builders must stamp through here.
      def self.role_reference(auth : RBAC::AuthContext) : String?
        principal = auth.principal
        return nil unless principal.is_a?(RBAC::Principal::Real)
        "iam.Roles.#{principal.active_role.role_id}"
      end

      private def self.rebuild_app_scoped(db : DB::Connection, caller : Caller, app_id : String) : RBAC::AuthContext?
        app_content = fetch_live(db, "app", "App", app_id)
        return nil if app_content.nil?
        return nil unless app_content.as_h["status"]?.try(&.as_s) == "active"

        app_scope = RBAC::AppScope.from_content(app_id, app_content)
        active_role = load_role(db, caller)
        return nil unless RBAC::GrantResolver.role_usable?(app_scope, active_role)

        effective = RBAC::GrantResolver.resolve(app_scope, active_role)
        return nil if effective.empty?

        RBAC::AuthContext.app_scoped(caller.account_id, active_role, effective, app_id, caller.api_key_id)
      end

      private def self.load_role(db : DB::Connection, caller : Caller) : RBAC::ActiveRole
        role_id = caller.role_id ||
                  raise Jobs::JobError.new("Import/export job carries no role id for account #{caller.account_id}")

        content = IAM::Helpers.find_role_content(db, role_id) ||
                  raise Jobs::JobError.new("Import/export role #{role_id} no longer exists")

        RBAC::ActiveRole.from_projection_content(content)
      end

      private def self.fetch_live(db : DB::Connection, domain : String, doc_type : String, id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
          domain, doc_type, id,
          as: JSON::Any,
        )
      end
    end
  end
end
