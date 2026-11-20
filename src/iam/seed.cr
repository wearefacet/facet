# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "../database"
require "../doctype/definition_store"
require "../document/projection_gucs"
require "../mutation/client"
require "../util/script_helpers"
require "../secrets/store"
require "./invite"

module Facet
  module IAM
    # Bootstraps the IAM subsystem during seeding.
    #
    # Creates:
    # - The admin `Account` document (if not already present), with
    #   `must_change_pw` as a document field.
    # - The `password` slot in the secret store, keyed by the account
    #   document.
    module Seed
      SEED_ADMIN_EMAIL    = "admin@example.tld"
      SEED_ADMIN_PASSWORD = -> { ENV.fetch("SEED_ADMIN_PASSWORD", "admin") }

      # The created first admin. The plaintext `password` is returned once —
      # the CLI prints it; nothing stores it in plaintext and nothing logs it.
      record Admin,
        id : String,
        email : String,
        password : String

      # Creates the first admin account with a generated one-time password.
      # The account carries `must_change_pw: true`, so the first login
      # short-circuits into the password-change bootstrap before any session
      # is issued. This is the production bootstrap path — `facet seed:admin`.
      #
      # Returns `nil` when a live account with this email already exists.
      # The bootstrap never resets an existing credential; recover access
      # through the password-reset flow instead.
      def self.seed_admin(db : DB::Connection, email : String) : Admin?
        if existing = admin_id_by_email(db, email)
          Log.info { "Admin account already exists (id=#{existing})" }
          return nil
        end

        admin_id = create_admin_account(db, email, must_change_pw: true)
        password = Invite.generate_password
        Secrets.set(db, "iam.Account.#{admin_id}", "password", password,
          mode: "hash", set_by: "system")

        # The plaintext never reaches the log — the CLI prints it once.
        Log.info { "Admin account seeded (id=#{admin_id}, email=#{email})" }
        Admin.new(id: admin_id, email: email, password: password)
      end

      # Returns the refusal message for `facet seed:dev` when the process
      # runs in production, nil otherwise. The dev seed writes the known
      # default credential with `must_change_pw: false` — the wrong first
      # state for a deployed identity provider. Production bootstraps the
      # first admin with `facet seed:admin <email>` instead.
      #
      # Reads `APP_ENV` per call (same resolution as `Service.app_env`) so
      # a one-shot CLI process always sees the value it booted with and a
      # spec can flip the environment.
      def self.dev_seed_refusal(app_env : String = ENV["APP_ENV"]? || "dev") : String?
        return nil unless app_env == "production"

        "'seed:dev' is refused when APP_ENV=production: it creates " \
        "#{SEED_ADMIN_EMAIL} with the known default password and " \
        "must_change_pw=false. Create the first admin with " \
        "'facet seed:admin <email>' instead."
      end

      # Seeds or resets the dev admin account for local development.
      #
      # Unlike `seed_admin`, this sets `must_change_pw: false` so login works
      # immediately without the password-change bootstrap. If the admin already
      # exists, the password is reset to the dev default and `must_change_pw`
      # is cleared. Intended for `facet seed:dev` (dev mode only).
      #
      # Returns `true` if the account was created, `false` if it was updated.
      # The dev seed is refused in production — see `dev_seed_refusal`.
      def self.seed_dev_admin(db : DB::Connection, email : String = SEED_ADMIN_EMAIL, password : String = SEED_ADMIN_PASSWORD.call) : Bool
        existing = admin_id_by_email(db, email)

        if existing
          # No FK cascades point at the account id (the account_settings
          # and notifications FKs to auth_secrets are gone), so the reset
          # path cleans up every side table keyed by the account id before
          # re-writing the password slot. A stale document id (mutation id
          # instead of document id) makes the deletes no-ops — the new
          # slot write still succeeds because (domain, doc_type, doc_id,
          # slot) is PRIMARY KEY and a stale row has a different key.
          db.exec("DELETE FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1", existing)
          db.exec("DELETE FROM auth_state WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1", existing)
          db.exec("DELETE FROM account_settings WHERE account_id = $1", existing)
          db.exec("DELETE FROM notifications WHERE account_id = $1", existing)

          Secrets.set(db, "iam.Account.#{existing}", "password", password,
            mode: "hash", set_by: "system")
          AccountPatch.call(db, existing, {"must_change_pw" => JSON::Any.new(false)})
          Log.info { "Dev admin account reset (id=#{existing})" }
          false
        else
          admin_id = create_admin_account(db, email, must_change_pw: false)
          Secrets.set(db, "iam.Account.#{admin_id}", "password", password,
            mode: "hash", set_by: "system")
          Log.info { "Dev admin account seeded (id=#{admin_id})" }
          true
        end
      end

      # Returns the id of the live account with this email, nil when absent.
      private def self.admin_id_by_email(db : DB::Connection, email : String) : String?
        db.query_one?("SELECT id FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = $1 AND deleted_at IS NULL",
          email,
          as: String
        )
      end

      # Creates an admin `iam.Account` document with the given email and the
      # standard admin role set. Returns the DOCUMENT id — the caller must
      # key the password slot on it. `Mutation::Client.create` returns the
      # mutation id, which is a different ULID — keying on it would corrupt
      # the slot lookup.
      private def self.create_admin_account(db : DB::Connection, email : String, must_change_pw : Bool) : String
        ensure_domain(db, "iam")

        admin_id = Util::ScriptHelpers.ulid
        content = JSON.parse({
          "email"          => email,
          "name"           => "Administrator",
          "status"         => "active",
          "roles"          => ["iam.Roles.admin"],
          "default_role"   => "iam.Roles.admin",
          "must_change_pw" => must_change_pw,
        }.to_json)

        Database.with_transaction(db, ignore_if_set: true) do |txn|
          # The projection trigger reads the staged GUCs — without them the
          # account lands with a NULL display_name and an empty search
          # corpus, and reference labels degrade to the raw id.
          if definition = Doctype::DefinitionStore.fetch_uncached(txn, "iam.Account")
            Document::ProjectionGucs.set_all(txn, definition, content)
          else
            Document::ProjectionGucs.clear_all(txn)
          end

          Mutation::Client.create(
            txn,
            "iam",
            "Account",
            doc_id: admin_id,
            content: content.to_json,
            actioner_id: "system",
          )
        end

        admin_id
      end

      private def self.ensure_domain(db : DB::Connection, domain_name : String) : Nil
        existing = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
          domain_name,
          as: Int32
        )
        return unless existing.nil?

        Database.with_transaction(db, ignore_if_set: true) do |txn|
          # core.Domain has no parseable definition — stage the empty GUC
          # set, the same branch Document::Create uses for domain creates.
          Document::ProjectionGucs.clear_all(txn)

          Mutation::Client.create(
            txn,
            "core",
            "Domain",
            doc_id: domain_name,
            content: %({"id": "#{domain_name}"}),
            actioner_id: "system",
          )
        end
      end
    end
  end
end
