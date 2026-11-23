# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "log"
require "../../util/script_helpers"
require "../../util/pg_error"
require "../../rbac/auth_context"
require "../../document/create"
require "../../document/update"
require "../helpers"
require "../account_patch"
require "../session_emit"
require "./discovery"

module Facet
  module IAM
    module OIDC
      # Identity resolution, linking, and JIT provisioning for inbound OIDC
      # logins. Federated identity links live on the `iam.Account` document
      # as the `federated_identities` array field (no side
      # table, no migration); the join key is (provider, subject), never
      # email, so an IdP email change can never silently take over an
      # account.
      #
      # Resolution follows four steps in order:
      # 1. exactly one account holds the (provider, subject) link → login;
      # 2. verified email with an allowlisted domain → link and login;
      # 3. unknown identity + unknown email + verified email + allowed
      #    domain + auto_provision → JIT-create the account;
      # 4. everything else → deny (audit detail only, generic browser
      #    error).
      module Identity
        SYSTEM_PRINCIPAL = "system:oidc"

        # Normalized claims the resolution acts on.
        record Claims,
          sub : String,
          email : String?,
          email_verified : Bool,
          display_name : String? do
          # Extracts the claims from a verified id_token payload. Raises on
          # a missing `sub` — the durable subject is the join key.
          def self.from_payload(payload : Hash(String, JSON::Any)) : Claims
            sub = payload["sub"]?.try(&.as_s?)
            unless sub
              raise Error.new("invalid_token", "id_token has no 'sub' claim")
            end
            email = payload["email"]?.try(&.as_s?)
            # Some providers serialize the flag as a string; accept both.
            verified = payload["email_verified"]?.try(&.as_bool?) ||
                       payload["email_verified"]?.try(&.as_s?) == "true" || false
            display_name = payload["name"]?.try(&.as_s?) ||
                           payload["preferred_username"]?.try(&.as_s?)
            Claims.new(sub: sub, email: email, email_verified: verified, display_name: display_name)
          end
        end

        record ResolvedAccount,
          id : String,
          status : String,
          email : String,
          display_name : String,
          roles : Array(String),
          default_role : String?

        record Resolved,
          account : ResolvedAccount,
          provisioned : Bool = false,
          linked : Bool = false

        record Denied,
          reason : String,
          account_id : String? = nil

        # Resolves the identity to an account without emitting a session.
        # Returns `Resolved` or `Denied`; the audit event for a denial is
        # written by `authenticate`.
        def self.resolve(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
        ) : Resolved | Denied
          resolve(db, provider, claims, retries: 1)
        end

        # ── Authentication orchestration ──────────────────────────────────

        # Full OIDC login: resolve → pending bootstrap flip → cookie-mode
        # session emit → audit events. Returns `TokenEmitter::Result` or a
        # generic `ServiceError` — the reason detail never reaches the
        # browser, only the audit log. Local MFA is
        # not consulted: the IdP is the factor of record.
        def self.authenticate(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
        ) : TokenEmitter::Result | Facet::ServiceError
          case resolved = resolve(db, provider, claims)
          in Denied
            # The audit subject follows the resolution: a denial that names an
            # account (suspended, service account, failed link) carries that
            # account as the actioner. A denial with no account (unknown
            # identity, email-branch refusal) carries the raw IdP `sub` and
            # keeps the `system` actioner.
            if audit_account = resolved.account_id
              Helpers.write_login_event(db, audit_account, "oidc_denied", resolved.reason)
            else
              Helpers.write_login_event(db, claims.sub, "oidc_denied", resolved.reason,
                subject_resolved: false)
            end
            Facet::ServiceError.new(401, "Login denied")
          in Resolved
            authenticate_resolved(db, provider, claims, resolved)
          end
        end

        # ── Private ────────────────────────────────────────────────────────

        private def self.authenticate_resolved(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          resolved : Resolved,
        ) : TokenEmitter::Result | Facet::ServiceError
          account = resolved.account

          if resolved.provisioned
            Helpers.write_login_event(db, account.id, "oidc_provisioned", "Provider: #{provider.name}")
          end

          # A pending account that federates is bootstrapped by the login.
          # The flip is idempotent — a no-op patch is a
          # success.
          if account.status == "pending"
            flip = AccountPatch.call(db, account.id, {"status" => JSON::Any.new("active")})
            if flip.is_a?(Facet::ServiceError)
              Helpers.write_login_event(db, account.id, "oidc_denied", "Status flip failed: #{flip.message}")
              return Facet::ServiceError.new(401, "Login denied")
            end
          end

          # A roleless account runs under the anonymous role (B-120), like
          # the password paths — it can authenticate, so it must be able to
          # connect. The frontend renders the no-role screen from the
          # emitted `available_roles` / `active_role` pair.
          role = active_role(account) || IAM::ANONYMOUS_ROLE_ID

          emit = SessionEmit.call(db, account.id, role, true)
          case emit
          in TokenEmitter::Result
            Helpers.write_login_event(db, account.id, "oidc_login", "Provider: #{provider.name}")
            emit
          in Facet::ServiceError
            Helpers.write_login_event(db, account.id, "oidc_denied", "Session emit failed: #{emit.message}")
            Facet::ServiceError.new(401, "Login denied")
          end
        end

        # Active role for the session — the shared rule (`default_role` when
        # still assigned, else the first assigned role), read from the
        # resolved account row.
        private def self.active_role(account : ResolvedAccount) : String?
          Helpers.default_active_role(account.roles, account.default_role)
        end

        # ── Resolution steps ───────────────────────────────────────────────

        private def self.resolve(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          retries : Int32,
        ) : Resolved | Denied
          step1 = resolve_by_link(db, provider, claims)
          return step1 if step1

          email = claims.email.try(&.strip.downcase)
          return email_branch_denial(provider) unless email && claims.email_verified &&
                                                      domain_allowed?(provider, email)

          resolve_by_email(db, provider, claims, email, retries)
        end

        # Step 1 — the (provider, subject) link is authoritative. Returns
        # nil when no account holds the link (the caller moves on to the
        # email branch).
        private def self.resolve_by_link(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
        ) : Resolved | Denied?
          matches = lookup_by_link(db, provider.name, claims.sub)
          if matches.size > 1
            # Corrupted state: deny defensively.
            return Denied.new(
              reason: "Defensive denial: multiple accounts hold the federated identity " \
                      "(provider=#{provider.name}, subject=#{claims.sub})"
            )
          end
          if account = matches.first?
            return status_denial(account) || Resolved.new(account: account)
          end
          nil
        end

        # Steps 2 and 3, for a verified email on an allowlisted
        # domain: link the existing account, JIT-provision, or deny.
        private def self.resolve_by_email(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          email : String,
          retries : Int32,
        ) : Resolved | Denied
          if found = Helpers.find_account_by_email(db, email)
            # Step 2 — email match. A service account is a machine identity
            # and stays rejected everywhere.
            return status_denial_from(found) || service_account_denial(found) ||
              link_and_resolve(db, provider, claims, found)
          end

          # Step 3 — JIT provisioning.
          return provision(db, provider, claims, email, retries) if provider.auto_provision

          Denied.new(reason: "Unknown identity and auto-provisioning is disabled " \
                             "(provider=#{provider.name})")
        end

        private def self.email_branch_denial(
          provider : Provider,
        ) : Denied
          Denied.new(reason: "Email missing, unverified, or its domain is not allowlisted " \
                             "(provider=#{provider.name})")
        end

        # Returns a `Denied` for a suspended/disabled account, nil when the
        # status permits login (`pending` is bootstrapped by the login).
        private def self.status_denial(account : ResolvedAccount) : Denied?
          return nil if account.status == "active" || account.status == "pending"
          Denied.new(reason: "Account is #{account.status}", account_id: account.id)
        end

        private def self.status_denial_from(found) : Denied?
          status = found[:status]
          return nil if status == "active" || status == "pending"
          Denied.new(reason: "Account is #{status}", account_id: found[:id])
        end

        private def self.service_account_denial(found) : Denied?
          return nil unless found[:service_account]
          Denied.new(reason: "Service accounts cannot federate", account_id: found[:id])
        end

        private def self.domain_allowed?(provider : Provider, email : String) : Bool
          domain = email.partition('@')[2].downcase
          return false if domain.empty?
          provider.domains.includes?(domain)
        end

        # Appends the (provider, subject) link to the account and returns
        # the resolved account. Idempotent: an existing identical link is
        # left untouched (no duplicate entry, no mutation).
        private def self.link_and_resolve(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          found,
        ) : Resolved | Denied
          content = fetch_content(db, found[:id])
          unless content
            return Denied.new(reason: "Account disappeared during linking", account_id: found[:id])
          end

          existing = content["federated_identities"]?.try(&.as_a?) || [] of JSON::Any
          if linked?(existing, provider.name, claims.sub)
            return Resolved.new(account: account_ref(found), linked: false)
          end

          new_entry = JSON.parse({
            "provider"  => provider.name,
            "subject"   => claims.sub,
            "linked_at" => Time.utc.to_rfc3339,
          }.to_json)
          patch = {"federated_identities" => JSON::Any.new(existing + [new_entry])}

          result = Document::Update.call(db, "iam", "Account", found[:id], patch.to_json,
            RBAC::AuthContext.system(SYSTEM_PRINCIPAL))
          case result
          in Document::Update::Result
            Resolved.new(account: account_ref(found), linked: true)
          in Facet::ServiceError
            Denied.new(reason: "Linking failed: #{result.message}", account_id: found[:id])
          end
        end

        private def self.linked?(entries : Array(JSON::Any), provider_name : String, subject : String) : Bool
          entries.any? do |entry|
            h = entry.as_h?
            h && h["provider"]?.try(&.as_s?) == provider_name &&
              h["subject"]?.try(&.as_s?) == subject
          end
        end

        # JIT-provisions the account (step 3). A unique-violation
        # on the account email (or the email-derived document id) means a
        # concurrent callback won — re-run the resolution instead of
        # creating a duplicate.
        private def self.provision(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          email : String,
          retries : Int32,
        ) : Resolved | Denied
          roles = provision_roles(db, provider)
          if roles.empty?
            return Denied.new(reason: "Provider '#{provider.name}' has no default_role and the instance " \
                                      "sets no iam.oidc.provision_roles baseline for JIT provisioning")
          end
          default_role = roles.first

          begin
            # No doc_id override: the account id is the email address (the
            # named-id branch in Document::Create.resolve_doc_id derives,
            # normalizes, and conflict-checks it).
            result = Document::Create.call(db, "iam", "Account",
              provision_content(provider, claims, email, roles, default_role),
              RBAC::AuthContext.system(SYSTEM_PRINCIPAL))
          rescue ex : PQ::PQError
            return re_resolve(db, provider, claims, retries, "database unique constraint (#{sqlstate(ex)})")
          end

          handle_create_result(db, provider, claims, email, retries, result)
        end

        # The roles a JIT account of *provider* receives: the provider's
        # own default_role when set (today's per-provider override), else
        # the instance-wide baseline (`iam.oidc.provision_roles` on
        # core.SystemSettings, read uncached through IAM::Policy). Empty
        # means provisioning must deny — a role-less account could never
        # hold a session.
        private def self.provision_roles(
          db : DB::Connection,
          provider : Provider,
        ) : Array(String)
          role = provider.default_role
          return [role] if role && !role.empty?
          IAM::Policy.provision_roles(db)
        end

        # The JIT account body (step 3): active status, the resolved
        # provisioning roles, and the federated identity link. The first
        # role doubles as the account's default_role (login election
        # falls back to the first assigned role anyway — storing it keeps
        # the content shape identical to a hand-created account).
        private def self.provision_content(
          provider : Provider,
          claims : Claims,
          email : String,
          roles : Array(String),
          default_role : String,
        ) : String
          link = JSON.parse({
            "provider"  => provider.name,
            "subject"   => claims.sub,
            "linked_at" => Time.utc.to_rfc3339,
          }.to_json)
          display_name = claims.display_name.try(&.strip)
          display_name = nil if display_name.try(&.empty?)
          {
            "email"                => email,
            "name"                 => display_name || email,
            "status"               => "active",
            "roles"                => roles,
            "default_role"         => default_role,
            "organizational_unit"  => "/",
            "federated_identities" => [link],
          }.to_json
        end

        private def self.handle_create_result(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          email : String,
          retries : Int32,
          result : Document::Create::Result | Facet::ServiceError,
        ) : Resolved | Denied
          case result
          in Document::Create::Result
            Resolved.new(account: created_account_ref(result.projection, email), provisioned: true)
          in Facet::ServiceError
            handle_create_error(db, provider, claims, email, retries, result)
          end
        end

        private def self.created_account_ref(
          projection : Mutation::Client::Projection,
          email : String,
        ) : ResolvedAccount
          content = projection.content
          ResolvedAccount.new(
            id: projection.id,
            status: content["status"]?.try(&.as_s?) || "active",
            email: content["email"]?.try(&.as_s?) || email,
            display_name: content["name"]?.try(&.as_s?) || email,
            roles: content["roles"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
            default_role: content["default_role"]?.try(&.as_s?),
          )
        end

        private def self.handle_create_error(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          email : String,
          retries : Int32,
          error : Facet::ServiceError,
        ) : Resolved | Denied
          if email_collision?(error)
            return re_resolve(db, provider, claims, retries, "email unique constraint")
          end
          # The email-derived account id colliding (NamedIdError 409 from
          # the named-id branch) means the account already exists — the
          # re-run links it at the email step, exactly like an email
          # unique collision.
          if error.status == 409
            return re_resolve(db, provider, claims, retries, "account id (email) already exists")
          end
          # Detail is audit-only — the browser sees the generic denial.
          detail = error.details.try(&.map { |d| "#{d.field}: #{d.message}" }.join("; "))
          Denied.new(reason: "Provisioning failed: #{detail || error.message}")
        end

        # Re-runs the resolution from step 1. `retries` is 1 on the first
        # call and 0 on the retry — a second consecutive collision is
        # corrupted state, not a race, and denies.
        private def self.re_resolve(
          db : DB::Connection,
          provider : Provider,
          claims : Claims,
          retries : Int32,
          cause : String,
        ) : Resolved | Denied
          if retries <= 0
            return Denied.new(reason: "JIT provisioning collided twice (#{cause})")
          end
          Log.info { "OIDC JIT collision (#{cause}) — re-resolving identity" }
          resolve(db, provider, claims, retries: retries - 1)
        end

        # True when the create failed on the account email's unique
        # constraint (application-level check surfaces it as a 422 with a
        # structured `unique` error on the email field).
        private def self.email_collision?(error : Facet::ServiceError) : Bool
          return false unless error.status == 422
          details = error.details
          return false unless details
          details.any? { |d| d.code == "unique" && d.field == "email" }
        end

        private def self.sqlstate(ex : PQ::PQError) : String
          Util::PgError.sqlstate(ex) || "unknown"
        end

        # Containment lookup over the Account projections, served by the
        # gin_jsonb index on `federated_identities`.
        private def self.lookup_by_link(
          db : DB::Connection,
          provider_name : String,
          subject : String,
        ) : Array(ResolvedAccount)
          probe = JSON.build do |json|
            json.array do
              json.object do
                json.field("provider", provider_name)
                json.field("subject", subject)
              end
            end
          end

          db.query_all(
            <<-SQL, probe) do |rs|
              SELECT id, content->>'status', content->>'email', content->>'name',
                     content->'roles', content->>'default_role'
              FROM projections
              WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL
                AND content->'federated_identities' @> $1::jsonb
            SQL
            id = rs.read(String)
            status = rs.read(String?) || "active"
            email = rs.read(String?) || ""
            display = rs.read(String?)
            roles_raw = rs.read(JSON::Any?)
            default_role = rs.read(String?)
            roles = roles_raw.try(&.as_a?.try(&.map(&.as_s))) || [] of String
            ResolvedAccount.new(id: id, status: status, email: email,
              display_name: display || email, roles: roles, default_role: default_role)
          end
        end

        private def self.account_ref(found) : ResolvedAccount
          ResolvedAccount.new(
            id: found[:id],
            status: found[:status],
            email: found[:email],
            display_name: found[:display_name],
            roles: found[:roles],
            default_role: found[:default_role],
          )
        end

        private def self.fetch_content(db : DB::Connection, account_id : String) : JSON::Any?
          db.query_one?(
            "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' " \
            "AND id = $1 AND deleted_at IS NULL",
            account_id, as: JSON::Any
          )
        end
      end
    end
  end
end
