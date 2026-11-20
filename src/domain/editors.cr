# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../mutation/client"
require "../rbac"
require "../util/projections"
require "../error"

module Facet
  module Domain
    # Membership primitives for the domain-editor list.
    #
    # A `core.DomainEditor` document grants one account the right to edit one
    # domain's definition surface (its domain document, doctypes, and
    # document views). The RBAC side resolves membership through the
    # `editor_domains` context set on the `core` domain document and the
    # `$domain_editor` named scopes; this module owns the write side and the
    # create-time gate the scopes cannot express:
    #
    # - `member?` — the direct EXISTS check behind the `Doctype::Create`
    #   service gate (scopes are presence-only at create time — the row does
    #   not exist yet).
    # - `grant` — records the creator of a domain as its first editor. Runs
    #   the full create pipeline (guard hook, links, display name, event) so
    #   audit attributes the grant to the real creator; the caller has
    #   already proved `create core.Domain`, so no permission is consulted.
    # - `transfer` — carries editor rows over on publish, so co-editors of a
    #   draft keep their rights on the published domain.
    # - `authorize_doctype_create?` — the layered gate: `All` (wildcard) and
    #   system pass; a `Scoped` caller must be a member of the target
    #   domain.
    # - `authorize_draft_from?` — the same layered gate for
    #   `Domain::Draft.create_from`: a `Scoped` caller must be a member of
    #   the source domain, because drafting from a live domain forks its
    #   definition surface.
    #
    # A dangling `domain` value on a row never matches any scope — the
    # resolution side fails closed by construction. `Scratch.dispose_definitions!`
    # tombstones rows pointing at a dropped domain so the list never carries
    # dead slugs.
    module Editors
      # The doctype backing the list. Must match the seed directory name.
      DOCTYPE = "DomainEditor"

      # Raised when the membership grant fails. Not a `ServiceError` — a
      # grant failure aborts the surrounding domain-creation transaction
      # (exception semantics, like the raw mutation calls beside it).
      class Error < ::Exception
      end

      # Returns true when the account is listed as an editor of the domain.
      # Direct EXISTS on `core.DomainEditor` — the same membership the
      # `$domain_editor` named scope resolves through the `editor_domains`
      # context set, without synthetic-row evaluation.
      def self.member?(db : DB::Connection, domain_id : String, account_id : String) : Bool
        !db.query_one?(
          <<-SQL,
            SELECT 1 FROM projections
            WHERE domain = 'core' AND doc_type = '#{DOCTYPE}'
              AND content->>'domain' = $1
              AND content->>'account' = $2
              AND deleted_at IS NULL
            LIMIT 1
          SQL
          domain_id, RBAC.qualify_principal(account_id),
          as: Int32,
        ).nil?
      end

      # Records `account_id` as an editor of `domain_id`. Called from every
      # domain-creation path right after the domain document exists, so the
      # creator holds editorship without a separate admin step.
      #
      # Skips non-account actioners: internal actors (`system`, `system:*`,
      # spec fixtures) and the reserved `anonymous` identity hold no
      # `iam.Account` row and cannot be editors, and an unseeded database
      # has no `core.DomainEditor` doctype to grant into. Both conditions
      # are the "specs, internal callers" bypass; production creators are
      # always real accounts against a seeded database.
      #
      # Raises on failure (the create pipeline's ServiceError surfaces as an
      # exception) — a grant failure aborts the surrounding domain creation
      # transaction rather than leaving a domain without its creator.
      #
      # The write runs under the system context: the caller has already
      # proved `create core.Domain` (this runs from that path), so the create
      # gate is skipped (`skip_authorization`), and the reference check must
      # not re-impose a read grant the synthetic caller never held. Audit
      # still attributes the mutation to the real creator through the
      # separate `actioner_id` argument.
      def self.grant(db : DB::Connection, domain_id : String, account_id : String, actioner_id : String) : Nil
        return if account_id == "system" || account_id == "anonymous"
        return unless account_registered?(db, account_id)
        return unless doctype_registered?(db)

        content = JSON::Any.new({
          "account" => JSON::Any.new(RBAC.qualify_principal(account_id)),
          "domain"  => JSON::Any.new(domain_id),
        })

        result = Document::Create.create_from_parsed(
          db, "core", DOCTYPE, content,
          RBAC::AuthContext.system, actioner_id,
          skip_authorization: true,
        )
        if result.is_a?(Facet::ServiceError)
          failure = result
          raise Error.new("Recording the domain editor for '#{domain_id}' failed: #{failure.message}")
        end
      end

      # Copies the live editor rows of `from_domain` onto `to_domain`,
      # skipping (account, target) pairs that already exist. Called from
      # `Domain::Publish` after the structure copy — fresh publish and
      # overwrite both — so co-editors of a draft keep their rights on the
      # published domain.
      def self.transfer(db : DB::Connection, from_domain : String, to_domain : String, actioner_id : String) : Nil
        account_refs = db.query_all(
          <<-SQL,
            SELECT content->>'account' FROM projections
            WHERE domain = 'core' AND doc_type = '#{DOCTYPE}'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
          SQL
          from_domain,
          as: String,
        )

        account_refs.each do |ref|
          account_id = bare_account_id(ref)
          next if account_id.nil?
          next if member?(db, to_domain, account_id)
          grant(db, to_domain, account_id, actioner_id)
        end
      end

      # Create-time gate for `Doctype::Create`: the permission scopes cannot
      # bite at create (no row exists), so membership is checked here.
      # `All` (wildcard role) and the system bypass pass; a `Scoped` caller
      # must be a member of the target domain; anything else fails closed.
      def self.authorize_doctype_create?(db : DB::Connection, target_domain : String, auth_context : RBAC::AuthContext) : Bool
        return true if auth_context.system?
        # A preview principal never writes core.DocType — PreviewEnforcer
        # denies the enforcer gate before this runs. Fail closed regardless.
        return false if auth_context.preview?

        case auth_context.can?("create", "core", ["DocType"])
        when RBAC::CanResult::All
          true
        when RBAC::CanResult::Scoped
          member?(db, target_domain, auth_context.account_id)
        else
          false
        end
      end

      # Create-time gate for `Domain::Draft.create_from` (the draft-from-live
      # route): the permission scopes cannot bite at create (no row exists),
      # so membership is checked here. Drafting from a live domain forks its
      # definition surface, so a `Scoped` caller must be a member of the
      # source domain. `All` (wildcard role) and the system bypass pass;
      # anything else fails closed.
      def self.authorize_draft_from?(db : DB::Connection, source_domain : String, auth_context : RBAC::AuthContext) : Bool
        return true if auth_context.system?
        # A preview principal never drafts from a live domain — its
        # capability is scoped to one draft domain. Fail closed regardless.
        return false if auth_context.preview?

        case auth_context.can?("create", "core", ["Domain"])
        when RBAC::CanResult::All
          true
        when RBAC::CanResult::Scoped
          member?(db, source_domain, auth_context.account_id)
        else
          false
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # True when an `iam.Account` projection row exists for the id. A grant
      # to a non-account is meaningless (and would fail the reference
      # existence check), so internal actioners are skipped instead.
      private def self.account_registered?(db : DB::Connection, account_id : String) : Bool
        Util::Projections.exists?(db, "iam", "Account", account_id)
      end

      # True when the `core.DomainEditor` doctype is registered. An
      # unseeded database has no list to grant into — skip instead of
      # failing a domain creation that predates the seed.
      private def self.doctype_registered?(db : DB::Connection) : Bool
        Util::Projections.exists?(db, "core", "DocType", "core.#{DOCTYPE}")
      end

      # Strips the qualified reference prefix (`iam.Account.<id>`) from a
      # stored account value, returning the bare id. The id segment may
      # itself contain dots — split on the first two only.
      private def self.bare_account_id(qualified : String) : String?
        parts = qualified.split('.', 3)
        return nil unless parts.size == 3
        parts[2]
      end
    end
  end
end
