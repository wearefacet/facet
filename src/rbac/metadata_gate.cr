# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"

module Facet
  module RBAC
    # Read visibility for the two structural-metadata doctypes.
    #
    # `core.DocType` definitions and `core.Domain` rows are render-time
    # metadata: the application builds the sidebar nav, every form, and
    # every route load from them. A role that holds grants on a doctype's
    # documents but no `read` line on `core.DocType` itself could list and
    # edit those documents through the API, yet every surface that renders
    # them answered a misleading 404, because the definition registry the
    # frontend resolves from (`GET /Api/core/DocType`) came back empty
    # (B-86).
    #
    # The rule is a **union** with the generic gate, so it is monotonic —
    # more permissions never remove visibility. A row is readable when the
    # generic read gate on the metadata doctype allows it OR the metadata
    # gate reaches it:
    #
    # - generic gate **Allowed** — no restriction (the generic path already
    #   serves every row).
    # - generic gate **Denied** — the role holds no `read` line on the
    #   metadata doctype at all; the metadata gate alone decides.
    # - generic gate **Scoped** — the scope clause and the metadata clause
    #   are OR-ed, so a scoped `read core.DocType` line (e.g.
    #   `$domain_editor`) can no longer hide a definition the caller's
    #   document grants reach (B-123).
    #
    # A row is readable when the caller holds any of the four reserved
    # actions on what the row describes:
    #
    # - `core.Domain` row `{domain}` — any permission line whose domain
    #   segment matches, or a wildcard-domain line.
    # - `core.DocType` row `{domain}.{Doctype}` — a line on that doctype
    #   (via `Permission#matches_path?` prefix semantics: the doctype
    #   itself, a domain-wide line, or a wildcard-domain line, minus
    #   `except` carve-outs).
    #
    # Pure permission arithmetic on the row id — a definition row's id IS
    # the qualified `{domain}.{Doctype}` it describes, and a domain row's
    # id IS the domain. No database access, no row content. Preview
    # principals never reach this gate (the `PreviewEnforcer` owns draft
    # domains); the Layer-1 app-grant ceiling applies on the metadata path
    # itself, so an app identity reads structural metadata only when its
    # grant permits `read` on `core.DocType` / `core.Domain`.
    module MetadataGate
      # The reserved actions the "any grant" check accepts. Named actions
      # do not qualify: a role holding only a named action cannot render
      # document surfaces either (its list gate still denies).
      RESERVED_ACTIONS = ["read", "create", "update", "delete"]

      # The definition-plane children of `core.DocType`. These rows ARE the
      # doctype's configuration (its listing surfaces and its presentation
      # templates), so reading the doctype implies reading them. Any other
      # child relationship — a domain's own composition children, a sidecar —
      # is document-plane and needs its own grant.
      DEFINITION_CHILDREN = ["CollectionView", "DocumentView"]

      # True when `(domain, doc_type)` is one of the structural doctypes.
      def self.metadata_doctype?(domain : String, doc_type : String) : Bool
        domain == "core" && (doc_type == "DocType" || doc_type == "Domain")
      end

      # True when the nested-route composition path targets a definition-plane
      # child of a `core.DocType` row — `["DocType", "CollectionView"]` or
      # `["DocType", "DocumentView"]`. Only the two-segment form qualifies: a
      # deeper path addresses documents *under* a view, not the configuration
      # itself.
      def self.definition_child_path?(doctype_path : Array(String)) : Bool
        doctype_path.size == 2 &&
          doctype_path[0] == "DocType" &&
          DEFINITION_CHILDREN.includes?(doctype_path[1])
      end

      # True when the caller may read the configuration of the doctype the
      # composition path descends from. `root_id` is the `core.DocType` row id
      # the nested route started from (the qualified `{domain}.{Doctype}`), so
      # the rule is the same permission arithmetic `definition_readable?`
      # applies — a grant on the described doctype, read through the parent.
      #
      # This is the nested-route twin of B-86: reading `hr.Employee` must serve
      # `core.DocType/hr.Employee/collection_view` too, otherwise the listing
      # renders default columns while the console fills with 403s.
      def self.definition_child_readable?(
        doctype_path : Array(String),
        root_id : String,
        auth_context : AuthContext,
      ) : Bool
        return false unless definition_child_path?(doctype_path)
        return false unless ceiling_allows?(auth_context, doctype_path[1])

        definition_readable?(auth_context, root_id)
      end

      # True when a single structural row (`doc_id`) is readable.
      def self.row_readable?(doc_type : String, doc_id : String, auth_context : AuthContext) : Bool
        return false if auth_context.preview?
        return false unless ceiling_allows?(auth_context, doc_type)

        case doc_type
        when "Domain"  then domain_row_readable?(auth_context, doc_id)
        when "DocType" then definition_readable?(auth_context, doc_id)
        else                false
        end
      end

      # True when the collection answer for a structural list is non-empty
      # for this caller at all — the mirror of the list clause for
      # `ReadEnforcer.read_denied?`, so field aggregates over the
      # structural doctypes answer the same gate state their lists do.
      def self.collection_reachable?(doc_type : String, auth_context : AuthContext) : Bool
        return false if auth_context.preview?
        return false unless ceiling_allows?(auth_context, doc_type)

        perms = reserved_lines(auth_context)
        case doc_type
        when "Domain"
          !perms.empty?
        when "DocType"
          # A nested-only line (path size >= 2) reaches no definition.
          perms.any? { |p| p.domain == Permission::WILDCARD_DOMAIN || p.path.size <= 1 }
        else
          false
        end
      end

      # Builds the WHERE fragment for a structural-metadata list.
      # Returns `{clauses, params}` in the `list_where_clauses` contract:
      # one parenthesised OR clause (empty = no restriction), params in
      # placeholder order starting at `start_idx`.
      def self.list_clause(doc_type : String, auth_context : AuthContext, start_idx : Int32) : {Array(String), Array(::DB::Any)}
        return {["1=0"], [] of ::DB::Any} unless ceiling_allows?(auth_context, doc_type)

        case doc_type
        when "Domain"  then domain_list_clause(auth_context, start_idx)
        when "DocType" then definition_list_clause(auth_context, start_idx)
        else                {["1=0"], [] of ::DB::Any}
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      private def self.permissions(auth_context : AuthContext) : Array(Permission)
        real = auth_context.principal
        return [] of Permission unless real.is_a?(Principal::Real)
        real.active_role.permissions
      end

      # The permission lines that qualify for the "any grant" rule.
      private def self.reserved_lines(auth_context : AuthContext) : Array(Permission)
        permissions(auth_context).select do |p|
          reserved_line?(p) && !structural_target?(p)
        end
      end

      private def self.reserved_line?(perm : Permission) : Bool
        RESERVED_ACTIONS.any? { |action| perm.matches_action?(action) }
      end

      # A line targeted at the structural doctypes themselves (`core.Domain`,
      # `core.DocType`, or a nested path under them) is definition-plane,
      # not document-plane: it implies no document surfaces to render, so
      # it never unlocks structural visibility. A caller holding only such
      # lines keeps the fail-closed empty answer.
      private def self.structural_target?(perm : Permission) : Bool
        perm.domain == "core" && !perm.path.empty? &&
          (perm.path.first == "Domain" || perm.path.first == "DocType")
      end

      # Layer-1 ceiling on the metadata path itself. A `nil` grant passes
      # (the single-nil-test contract); a present grant must permit read.
      private def self.ceiling_allows?(auth_context : AuthContext, doc_type : String) : Bool
        auth_context.app_grant_permits?("read", "core", [doc_type])
      end

      private def self.domain_row_readable?(auth_context : AuthContext, domain_id : String) : Bool
        return false if domain_id.empty?
        reserved_lines(auth_context).any? do |perm|
          perm.domain == Permission::WILDCARD_DOMAIN || perm.domain == domain_id
        end
      end

      private def self.definition_readable?(auth_context : AuthContext, doc_id : String) : Bool
        parts = doc_id.split('.', 2)
        return false unless parts.size == 2
        target_domain, target_doctype = parts[0], parts[1]
        reserved_lines(auth_context).any? do |perm|
          perm.matches_path?(target_domain, [target_doctype])
        end
      end

      private def self.domain_list_clause(auth_context : AuthContext, start_idx : Int32) : {Array(String), Array(::DB::Any)}
        domains = reserved_lines(auth_context).map(&.domain).uniq!
        return {["1=0"], [] of ::DB::Any} if domains.nil? || domains.empty?
        return {[] of String, [] of ::DB::Any} if domains.includes?(Permission::WILDCARD_DOMAIN)

        or_parts = [] of String
        params = [] of ::DB::Any
        idx = start_idx
        domains.each do |domain_id|
          params << domain_id
          or_parts << "id = $#{idx}"
          idx += 1
        end
        {["(#{or_parts.join(" OR ")})"], params}
      end

      # One contribution per permission line, OR-combined:
      # - wildcard domain: every definition minus two-segment `except`
      #   entries (deeper entries subtract child rows of a doctype, never
      #   the definition itself); no entries → the whole collection is
      #   unrestricted;
      # - domain-wide line: `split_part(id, '.', 1) = <domain>` minus the
      #   two-segment except entries inside that domain;
      # - single-segment line: `id = '<domain>.<Doctype>'` (deduped);
      # - deeper (nested) line: no definition contribution — the prefix
      #   semantics of `Permission#matches_path?` reject it for the parent
      #   definition too, so lists and single reads agree.
      private def self.definition_list_clause(auth_context : AuthContext, start_idx : Int32) : {Array(String), Array(::DB::Any)}
        perms = reserved_lines(auth_context)
        return {["1=0"], [] of ::DB::Any} if perms.empty?

        or_parts = [] of String
        params = [] of ::DB::Any
        qualified_ids = [] of String
        idx = start_idx

        perms.each do |perm|
          if perm.domain == Permission::WILDCARD_DOMAIN
            carve_outs = two_segment_excepts(perm)
            if carve_outs.empty?
              return {[] of String, [] of ::DB::Any}
            end
            or_parts << excluded_ids_clause(carve_outs, params, idx)
            idx += carve_outs.size
          elsif perm.path.empty?
            params << perm.domain
            base = "split_part(id, '.', 1) = $#{idx}"
            idx += 1
            carve_outs = two_segment_excepts(perm, within: perm.domain)
            if carve_outs.empty?
              or_parts << base
            else
              or_parts << "(#{base} AND #{excluded_ids_clause(carve_outs, params, idx)})"
              idx += carve_outs.size
            end
          elsif perm.path.size == 1
            qualified = "#{perm.domain}.#{perm.path[0]}"
            next if perm.except_paths.includes?(qualified) || qualified_ids.includes?(qualified)
            qualified_ids << qualified
            params << qualified
            or_parts << "id = $#{idx}"
            idx += 1
          end
        end

        return {["1=0"], [] of ::DB::Any} if or_parts.empty?
        {["(#{or_parts.join(" OR ")})"], params}
      end

      # Except entries of the exact `domain.Doctype` shape — the only form
      # that can exclude a definition row (deeper entries target child
      # rows of the doctype). With `within`, only entries inside that
      # domain count — entries elsewhere sit outside the line's reach.
      private def self.two_segment_excepts(perm : Permission, within : String? = nil) : Array(String)
        perm.except_paths.select do |entry|
          entry.count('.') == 1 && (within.nil? || entry.starts_with?("#{within}."))
        end
      end

      private def self.excluded_ids_clause(entries : Array(String), params : Array(::DB::Any), start_idx : Int32) : String
        parts = entries.map_with_index do |entry, i|
          params << entry
          "id != $#{start_idx + i}"
        end
        parts.size == 1 ? parts.first : "(#{parts.join(" AND ")})"
      end
    end
  end
end
