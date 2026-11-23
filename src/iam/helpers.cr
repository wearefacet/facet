# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "../database"
require "../http/helpers"
require "../mutation/client"
require "../util/script_helpers"
require "../rbac/permission"
require "../rbac/auth_context"
require "./role_store"

module Facet
  module IAM
    # Shared helpers for IAM modules.
    #
    # Extracted to eliminate duplication across login.cr, challenge.cr,
    # refresh.cr, logout.cr, and mfa.cr.
    module Helpers
      # One `iam.Account` projection row. Every account reader returns this
      # shape — callers narrow to the fields they use.
      alias AccountRow = NamedTuple(
        id: String,
        email: String,
        display_name: String,
        roles: Array(String),
        default_role: String?,
        status: String,
        service_account: Bool,
        must_change_pw: Bool,
        mfa_enabled: Bool,
      )

      # Picks the active role for a session: `default_role` when it is still
      # assigned, else the first assigned role. Returns nil when the account
      # holds no usable role. Shared by `SessionEmit` (bootstrap mode) and
      # the OIDC identity flow.
      def self.default_active_role(assigned_roles : Array(String), default_role : String?) : String?
        return default_role if default_role && assigned_roles.includes?(default_role)
        assigned_roles.first?
      end

      # Renders a link TTL as English prose for the outbound email copy.
      # The `reset`-slot TTL is `iam.change_password_expiration`, and both
      # link emails must state the effective window instead of a hardcoded
      # duration (B-90). Picks the largest unit that divides the TTL exactly
      # (days → hours → minutes); a non-minute multiple floors to whole
      # minutes, so the copy never overstates the window.
      def self.link_validity_text(seconds : Int32) : String
        if seconds >= 86_400 && seconds % 86_400 == 0
          days = seconds // 86_400
          days == 1 ? "1 day" : "#{days} days"
        elsif seconds >= 3_600 && seconds % 3_600 == 0
          hours = seconds // 3_600
          hours == 1 ? "1 hour" : "#{hours} hours"
        elsif seconds >= 60
          minutes = seconds // 60
          minutes == 1 ? "1 minute" : "#{minutes} minutes"
        else
          seconds == 1 ? "1 second" : "#{seconds} seconds"
        end
      end

      # Writes a LoginEvent document for audit purposes. The optional `app`
      # is the `app.App` projection id when the event concerns an app session:
      # refresh reuse, refresh failure, Layer-1 denial, consent
      # granted. Stored as a top-level `app` field on the event content so an
      # admin can filter the audit log by app without parsing `details`.
      #
      # `subject_resolved` states whether `account_id` names a live
      # `iam.Account` row. It picks the mutation actioner: a resolved subject
      # is stamped as the actioner itself, so the audit `actioner_id` filter
      # answers "all login events about account X". A synthetic principal
      # (`system:password`, `system:oidc`, an unresolved IdP `sub`) keeps the
      # `system` actioner. Call sites pass the signal explicitly; the writer
      # never infers it from the id shape.
      #
      # Fail-silent: a LoginEvent write failure never breaks the request that
      # triggered it. The event is observability, not a transaction-side-effect.
      def self.write_login_event(
        db : DB::Connection,
        account_id : String,
        event : String,
        details : String? = nil,
        app : String? = nil,
        subject_resolved : Bool = true,
      ) : Nil
        content = {
          "account_id" => account_id,
          "event"      => event,
          "details"    => details,
          "app"        => app,
        }.to_json
        actioner_id = subject_resolved ? account_id : "system"
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          Mutation::Client.create(
            txn,
            "iam",
            "LoginEvent",
            doc_id: Util::ScriptHelpers.ulid,
            content: content,
            actioner_id: actioner_id,
          )
        end
      rescue ex
        Log.error { "Failed to write login event: #{ex.message}" }
      end

      # Writes a `layer1_denied` LoginEvent when an app-scoped identity is
      # refused at the Layer-1 grant pre-check. No-op when
      # `auth_context` carries no app binding — ordinary browser-session
      # denials are not app-attributed and never reach this path. The event
      # is written fail-silent so audit never breaks a refused request.
      def self.write_layer1_denial(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        action : String,
        domain : String,
        doctype_path : Array(String),
      ) : Nil
        app_id = auth_context.app_id
        return unless app_id
        write_login_event(db, auth_context.account_id, "layer1_denied",
          "#{action} on #{domain}.#{doctype_path.join(".")} refused by app grant",
          app: app_id)
      end

      # Finds a role document by its qualified reference id from the
      # projections table, served through the process-local `RoleStore`
      # cache (fanout eviction + staleness bound — see that module).
      #
      # References are always stored in the `{domain}.{Doctype}.{id}` form
      # (here `iam.Roles.admin`). The `id` of an `iam.Roles` projection is
      # exactly that qualified string, so the lookup is strict — no name
      # fallback, no domain/doctype splitting, no tolerance.
      def self.find_role_content(db : DB::Connection, role_name : String) : JSON::Any?
        RoleStore.fetch(db, role_name)
      end

      # True when the role content's `connectivity` list carries the `mcp`
      # channel — the MCP resource server's channel gate. A missing or
      # malformed list reads as false (fail closed). The one derivation the
      # consent screen, the code issuance, and the endpoint listing share.
      def self.mcp_channel?(role_content : JSON::Any) : Bool
        channels = role_content["connectivity"]?.try(&.as_a?) || return false
        channels.any?(&.as_s?.try(&.==("mcp")))
      end

      # The active role's `visible_tags` as a sorted wire array — the same
      # set the read mask and the write guards apply (`RBAC::FieldVisibility`).
      # Served by `GET /Api/iam/me` and the refresh/login emits so the SPA can
      # hide affordances for fields the caller can never see (B-176). Nil
      # when the role projection is missing; the frontend then applies no
      # filter (an affordance hint only — the enforcers stay the boundary).
      def self.build_visible_tags(role_content : JSON::Any?) : Array(String)?
        return nil if role_content.nil?
        RBAC::ActiveRole.from_projection_content(role_content).visible_tags.to_a.sort
      end

      # Builds the permission manifest (UX only) from the role definition.
      #
      # Returns both the `permissions` map (doctype → action list, used to
      # filter the sidebar nav) and the parallel `scopes` map (doctype →
      # action → scope-alias union), mirroring the Lua `ctx.actor.scope` /
      # `ctx.actor.scopes` semantics so the frontend can decide general vs
      # personal create UI without an extra round-trip.
      #
      # A wildcard `*.*` line keeps its aggregated action list on the `*.*`
      # key, and its `except` carve-outs fold per action under the reserved
      # `*.*.except.<action>` keys — the intersection of the lines' except
      # lists for that action (deduped, first-seen order preserved). A key is
      # emitted only when its fold is non-empty; a doctype key can never
      # contain `*`, so no collision is possible. Per-action keys keep the
      # carve-outs faithful when the wildcard lines except different doctypes
      # per action (the seeded `editor` creates `core.Webhook` through its
      # wildcard but reads/edits/deletes only its own): a single union hid
      # the create affordance the REST API still serves (B-85).
      #
      # A domain-wide line (`on` with no dot and a lower_case domain, e.g.
      # `hr`) is emitted under the domain-wildcard key `hr.*` — the frontend
      # matcher grants every doctype in the domain through it. A bare
      # CamelCase name (`Account`) keeps the `iam` shorthand and normalizes to
      # `iam.Account`. The first character's case is the discriminator,
      # mirroring the RBAC grammar (domains are lower_case, doctype path
      # segments are CamelCase).
      #
      # Scope rules per (doctype, action):
      #   - any matching permission line `unrestricted?` → `[]` (can create general)
      #   - all matching lines scoped            → union of `scope_aliases` (deduped)
      # Wildcard `*.*` lines merge under the `*.*` scopes key and domain-wide
      # lines under their `{domain}.*` key. The frontend consults `*.*` when
      # the wildcard fallback grants the action and `{domain}.*` when a
      # domain-wide grant does; admins are unaffected — they short-circuit on
      # `*.*` → `"*"` before the scopes lookup. Both fields are nil when the
      # role has no permissions at all.
      def self.build_permission_manifest(role_content : JSON::Any) : NamedTuple(
        permissions: Hash(String, Array(String))?,
        scopes: Hash(String, Hash(String, Array(String)))?,
      )
        perms_raw = role_content.as_h["permissions"]?.try(&.as_a?)
        return {permissions: nil, scopes: nil} if perms_raw.nil? || perms_raw.empty?

        permissions = {} of String => Array(String)
        # Per-action `except` carve-outs of the wildcard `*.*` lines:
        # action -> the lines' except lists, in first-seen order.
        wildcard_excepts = {} of String => Array(Array(String))
        # on_normalized -> action -> {unrestricted?, aliases}
        scope_groups = {} of String => Hash(String, {unrestricted: Bool, aliases: Set(String)})

        perms_raw.each do |perm|
          h = perm.as_h
          on = h["on"]?.try(&.as_s) || next
          action = h["action"]?.try(&.as_s) || next

          on_normalized = normalize_manifest_on(on)

          # permissions map: aggregate actions (deduped, insertion order preserved)
          actions = permissions[on_normalized] ||= [] of String
          actions << action unless actions.includes?(action)

          parsed = RBAC::Permission.from_json(perm)

          # Wildcard carve-outs: keep each line's list per action. The
          # frontend prefix-matches the folded result against a doctype
          # before it grants through the `*.*` fallback.
          if on_normalized == "*.*"
            lists = wildcard_excepts[action] ||= [] of Array(String)
            lists << parsed.except_paths
          end

          action_groups = scope_groups[on_normalized] ||= {} of String => {unrestricted: Bool, aliases: Set(String)}
          action_groups[action] = merge_scope_group(action_groups[action]?, parsed)
        end

        # Fold each action's lists to their intersection — backend grant
        # semantics are OR over lines, so a doctype is truly excepted for an
        # action only when every wildcard line with that action subtracts it.
        wildcard_excepts.each do |action, lists|
          folded = lists.reduce { |acc, list| acc & list }.uniq
          permissions["*.*.except.#{action}"] = folded unless folded.empty?
        end

        {permissions: permissions.empty? ? nil : permissions, scopes: build_scopes(scope_groups)}
      end

      # Normalizes a permission line's `on` into its manifest key.
      #
      # - `domain.Doctype` (contains a dot) — kept verbatim.
      # - a bare CamelCase name (`Account`) — the `iam` domain shorthand,
      #   normalized to `iam.Account`.
      # - a bare lower_case name (`hr`) — a domain-wide grant (domain `hr`,
      #   empty path), emitted as the domain-wildcard key `hr.*` so the
      #   frontend matcher can grant every doctype in the domain.
      #
      # The first character's case is the discriminator, mirroring the RBAC
      # grammar: domains are lower_case, doctype path segments are CamelCase.
      private def self.normalize_manifest_on(on : String) : String
        return on if on.includes?('.')
        first = on[0]?
        first && first.uppercase? ? "iam.#{on}" : "#{on}.*"
      end

      # Folds a parsed permission's scope into the existing per-action group.
      # Any unrestricted line collapses the whole group to `[]`.
      private def self.merge_scope_group(
        existing : {unrestricted: Bool, aliases: Set(String)}?,
        parsed : RBAC::Permission,
      ) : {unrestricted: Bool, aliases: Set(String)}
        base = existing || {unrestricted: false, aliases: Set(String).new}
        if parsed.unrestricted?
          {unrestricted: true, aliases: base[:aliases]}
        else
          {unrestricted: base[:unrestricted],
           aliases:      base[:aliases].concat(parsed.scope_aliases)}
        end
      end

      # Materializes the per-(doctype, action) scope-alias map.
      # Returns nil when no permission lines were collected.
      private def self.build_scopes(
        scope_groups : Hash(String, Hash(String, {unrestricted: Bool, aliases: Set(String)})),
      ) : Hash(String, Hash(String, Array(String)))?
        return nil if scope_groups.empty?

        scopes = {} of String => Hash(String, Array(String))
        scope_groups.each do |on_normalized, action_groups|
          action_scopes = {} of String => Array(String)
          action_groups.each do |action, group|
            action_scopes[action] = group[:unrestricted] ? [] of String : group[:aliases].to_a
          end
          scopes[on_normalized] = action_scopes
        end
        scopes
      end

      # Builds the permission manifest (UX only) from a resolved effective
      # scope — `RBAC::GrantResolver.resolve` output, the app's grant ∩ the
      # active role. Served by `GET /Api/iam/me` to app-scoped callers (app
      # tokens, app-owned API keys): from the app's perspective the grant is
      # the world, so the manifest lists only the doctypes the grant reaches
      # — no `*.*` fallback, no doctype outside the grant.
      #
      # The resolver de-wildcards entries against the grant targets, so the
      # key space is narrower than the role manifest's: concrete
      # `domain.Doctype` keys, plus the domain-wildcard `domain.*` form when
      # a wildcard grant target collapsed with a wildcard role permission.
      #
      # Carve-outs fold per granted action over every role line that grants
      # it (the same OR-over-lines semantics enforcement applies: an action
      # fires on a target only when some line's `except` list misses it).
      # A non-empty fold that covers the entry's own path kills the action
      # for the key and its whole subtree — the action is removed, so a
      # carved doctype does not appear in the manifest at all. Any other
      # non-empty fold is emitted under the reserved `{key}.except.{action}`
      # key; a client matcher prefix-matches the folded paths against the
      # target before granting through the key (descendant carve-outs).
      #
      # The `scopes` map mirrors `build_permission_manifest` (same private
      # helper): per (key, granted action), `[]` when any contributing line
      # is unrestricted, else the union of the lines' scope aliases.
      def self.build_effective_manifest(scope : RBAC::EffectiveScope) : NamedTuple(
        permissions: Hash(String, Array(String))?,
        scopes: Hash(String, Hash(String, Array(String)))?,
      )
        return {permissions: nil, scopes: nil} if scope.empty?

        permissions = {} of String => Array(String)
        # key -> granted action -> the except lists of every role line that
        # grants the action on the entry, in first-seen order. Folded to
        # their intersection below.
        except_lists = {} of String => Hash(String, Array(Array(String)))
        scope_groups = {} of String => Hash(String, {unrestricted: Bool, aliases: Set(String)})

        scope.entries.each do |entry|
          key = ([entry.domain] + entry.path).join('.')
          actions = permissions[key] ||= [] of String
          entry.actions.each do |action|
            actions << action unless actions.includes?(action)
          end

          action_groups = scope_groups[key] ||= {} of String => {unrestricted: Bool, aliases: Set(String)}
          key_lists = except_lists[key] ||= {} of String => Array(Array(String))
          entry.actions.each do |action|
            matching = entry.permissions.select(&.matches_action?(action))
            next if matching.empty?

            group = {unrestricted: false, aliases: Set(String).new}
            matching.each do |perm|
              group = merge_scope_group(group, perm)
            end
            action_groups[action] = group

            lists = key_lists[action] ||= [] of Array(String)
            matching.each do |perm|
              lists << perm.except_paths
            end
          end
        end

        fold_me_excepts(permissions, except_lists) unless except_lists.empty?

        {permissions: permissions.empty? ? nil : permissions, scopes: build_scopes(scope_groups)}
      end

      # Folds the collected carve-outs into the effective manifest. A fold
      # that covers the entry's own path kills the action for the key and
      # its whole subtree (carve-outs prefix-cover descendants) — the
      # action is removed, so a carved doctype does not appear in the
      # manifest at all. Any other non-empty fold lands under the reserved
      # `{key}.except.{action}` key for the client matcher to subtract on
      # descendant targets.
      private def self.fold_me_excepts(
        permissions : Hash(String, Array(String)),
        except_lists : Hash(String, Hash(String, Array(Array(String)))),
      ) : Nil
        except_lists.each do |key, action_lists|
          parts = key.split('.')
          domain = parts[0]
          entry_path = parts[1..]
          action_lists.each do |action, lists|
            folded = lists.reduce { |acc, list| acc & list }.uniq
            next if folded.empty?
            if except_covers_path?(folded, domain, entry_path)
              list = permissions[key]
              next unless list
              list.reject!(action)
              permissions.delete(key) if list.empty?
            else
              permissions["#{key}.except.#{action}"] = folded
            end
          end
        end
      end

      # True when any carve-out in `folded` covers the manifest key's own
      # path — the prefix rule `Permission#matches_except?` applies: an
      # entry on `crm.Contact` also covers `crm.Contact.Comment`.
      private def self.except_covers_path?(folded : Array(String), domain : String, entry_path : Array(String)) : Bool
        folded.any? do |entry|
          parts = entry.split('.')
          parts[0] == domain &&
            parts[1..].size <= entry_path.size &&
            parts[1..].zip(entry_path).all? { |a, b| a == b }
        end
      end

      # Finds an account by (normalized) email from the `iam.Account` projections.
      # The email comparison is case-insensitive via `LOWER` on both the
      # stored value and the bound parameter. Callers normalize with
      # `strip.downcase` before binding.
      #
      # `service_account` gates the password-login and password-reset flows:
      # a service account is an account without login capability.
      # `must_change_pw` and `mfa_enabled` are account document fields —
      # the login pipeline reads them straight from the content.
      def self.find_account_by_email(db : DB::Connection, email : String) : AccountRow?
        read_account_row(db, "LOWER(content->>'email') = $1", email)
      end

      # Finds an account by id and returns the full row:
      #
      # - `status` and `roles` — the API-key verification path checks them,
      # - `email` and `display_name` — the invite email needs them,
      # - `service_account` — both provisioning routes refuse service accounts,
      # - `mfa_enabled` — the account document's field, the single source
      #   of truth for the MFA status.
      def self.find_account_by_id(db : DB::Connection, account_id : String) : AccountRow?
        read_account_row(db, "id = $1", account_id)
      end

      # One reader behind the account finders. `predicate` is a fixed
      # SQL fragment (an internal constant, never request input) that names
      # the one bound parameter; `value` binds to it.
      private def self.read_account_row(
        db : DB::Connection,
        predicate : String,
        value : String,
      ) : AccountRow?
        db.query_one?(
          <<-SQL,
            SELECT id, content->>'email', content->>'name', content->'roles', content->>'default_role', content->>'status', content->>'service_account',
                   COALESCE((content->>'must_change_pw')::boolean, false),
                   COALESCE((content->>'mfa_enabled')::boolean, false)
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account'
              AND deleted_at IS NULL
              AND #{predicate}
          SQL
          value
        ) do |rs|
          id = rs.read(String)
          email_val = rs.read(String?) || ""
          display = rs.read(String?)
          roles_raw = rs.read(JSON::Any?)
          default_role = rs.read(String?)
          status = rs.read(String?) || "active"
          service_account = rs.read(String?) == "true"
          must_change_pw = rs.read(Bool)
          mfa_enabled = rs.read(Bool)
          roles = roles_raw.try(&.as_a?.try(&.map(&.as_s))) || [] of String

          {id: id, email: email_val, display_name: display || email_val, roles: roles, default_role: default_role, status: status, service_account: service_account, must_change_pw: must_change_pw, mfa_enabled: mfa_enabled}
        end
      end

      # True when the account holds a `password` slot in the secret store.
      # The store has no has-slot helper, so this reads the table directly.
      # An absent slot counts as no password — the state a first-invite
      # account is in before its first credential write.
      def self.password_slot_exists?(db : DB::Connection, account_id : String) : Bool
        !db.query_one?("SELECT 1 FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'password'", account_id, as: Int32).nil?
      end

      # Decodes the JWT payload from the access token and returns the value of
      # the given claim. The token is read from the `auth_token` cookie, or the
      # `Authorization: Bearer …` header as a fallback. Returns `nil` if the
      # token is missing, malformed, or the claim is absent.
      def self.decode_jwt_claim(env, claim : String) : String?
        token = access_token(env)
        return nil unless token
        decode_jwt_claim(token, claim)
      end

      # Decodes a claim from a raw JWT string. Returns `nil` on any error.
      def self.decode_jwt_claim(token : String, claim : String) : String?
        decoded_payload(token).try(&.[claim]?).try(&.as_s?)
      end

      # Decodes the JWT payload (no signature check) — the shared reader
      # behind the claim accessors. Returns nil on any decode error or when
      # the payload is not a JSON object.
      private def self.decoded_payload(token : String) : Hash(String, JSON::Any)?
        parts = token.split('.')
        return nil if parts.size != 3
        JSON.parse(Base64.decode_string(parts[1])).as_h?
      rescue
        nil
      end

      # Extracts the `sub` (account_id) claim from the access token.
      def self.extract_account_id(env) : String?
        decode_jwt_claim(env, "sub")
      end

      # Extracts the `role` claim from the access token.
      def self.extract_role(env) : String?
        decode_jwt_claim(env, "role")
      end

      # Extracts the `exp` claim from the access token as a Unix timestamp.
      def self.extract_expires_at(env) : Int64?
        token = access_token(env)
        return nil unless token
        decoded_payload(token).try(&.["exp"]?).try(&.as_i64)
      end

      # Reads the raw access token from the cookie or Authorization header.
      # Delegates to the shared extractor (`Bearer` and `DPoP` schemes;
      # see `HTTP::Helpers#extract_access_token`).
      def self.access_token(env) : String?
        HTTP::Helpers.extract_access_token(env)
      end
    end
  end
end
