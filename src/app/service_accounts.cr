# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../error"
require "../document/create"
require "../document/update"
require "../iam/helpers"
require "../util/script_helpers"
require "../util/time_helper"

module Facet
  module App
    # Service-account provisioning for backend apps (`client_type:
    # "confidential"`).
    #
    # A backend app authenticates through an API key issued against a
    # dedicated machine identity: an `iam.Account` with `service_account:
    # true`, `status: "active"`, and exactly one role (the app's
    # `service_role_id`, both in `roles` and as `default_role`). The account
    # holds no password slot — login, invite, and password-reset all refuse
    # service accounts, so the key is its only credential.
    #
    # The provisioning is idempotent: the app document links its service
    # account via the `service_account_id` reference field, and a later
    # issuance reuses the linked account. Created with the system principal
    # (the same precedent as OIDC JIT provisioning) — the caller's
    # authorization happened at the route, and no role grants `iam.Account`
    # creation on behalf of an app.
    module ServiceAccounts
      # Placeholder email domain for machine identities. `.invalid` is a
      # reserved TLD: the address can never receive mail, which is the point
      # — a service account has no inbox (see the plan's open question 2).
      SERVICE_EMAIL_DOMAIN = "apps.facet.invalid"

      # The service-account email for an app slug. The slug pattern
      # (`^[a-z0-9][a-z0-9-]*$`) guarantees the address satisfies the
      # `iam.Account` email shape.
      def self.email_for(slug : String) : String
        "svc.#{slug}@#{SERVICE_EMAIL_DOMAIN}"
      end

      # Returns the app's service-account id, provisioning one when the link
      # is absent or stale. Idempotent: an existing, live link wins.
      #
      # Writes the account document and the `service_account_id` back-link on
      # the app in the caller's transaction (nesting is safe — see
      # `Database.with_transaction` savepoint semantics). The role sync is
      # the issuer's job (`App::ApiKeys`), not this module's: provisioning
      # pins the role only at creation.
      def self.ensure(
        db : DB::Connection,
        app_id : String,
        slug : String,
        display_name : String,
        role_id : String,
      ) : String | Facet::ServiceError
        app_content = load_app_content(db, app_id)
        return Facet::ServiceError.new(404, "App not found") unless app_content

        linked = app_content.as_h["service_account_id"]?.try(&.as_s?)
        if linked && IAM::Helpers.find_account_by_id(db, bare_account_id(linked))
          return bare_account_id(linked)
        end

        # No live link (first issuance, or the account was deleted) —
        # provision a fresh account and re-point the app at it.
        result = Document::Create.call(
          db,
          "iam",
          "Account",
          account_content(slug, display_name, role_id),
          RBAC::AuthContext.system,
          doc_id: Util::ScriptHelpers.ulid,
        )
        case result
        in Facet::ServiceError
          return Facet::ServiceError.new(500, "Service account provisioning failed: #{result.message}")
        in Document::Create::Result
          account_id = result.projection.id
        end

        patch = {"service_account_id" => account_id}.to_json
        update = Document::Update.call(
          db,
          "app",
          "App",
          app_id,
          patch,
          RBAC::AuthContext.system,
        )
        return Facet::ServiceError.new(500, "Service account link failed: #{update.message}") if update.is_a?(Facet::ServiceError)

        account_id
      end

      # ── Private ────────────────────────────────────────────────────────

      # Reference fields normalize to the qualified `{domain}.{Doctype}.{id}`
      # form on persistence. The link is written by this module either way —
      # strip the prefix so the id stays the bare projection id the key row
      # and the audit path expect.
      private def self.bare_account_id(linked : String) : String
        prefix = "iam.Account."
        linked.starts_with?(prefix) ? linked[prefix.size..] : linked
      end

      private def self.load_app_content(db : DB::Connection, app_id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          app_id,
          as: JSON::Any,
        )
      end

      private def self.account_content(slug : String, display_name : String, role_id : String) : String
        {
          "email"               => email_for(slug),
          "name"                => display_name,
          "status"              => "active",
          "roles"               => [role_id],
          "default_role"        => role_id,
          "service_account"     => true,
          "organizational_unit" => "/",
        }.to_json
      end
    end
  end
end
