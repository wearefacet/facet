# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../doctype/definition_store"
require "../rbac"
require "../util/diacritic_fold"
require "../util/like_escape"

module Facet
  module Search
    # A term shorter than this (after strip) answers an empty result —
    # never an error. The client applies the same gate before calling.
    MIN_TERM_LENGTH = 2

    # Per-doctype match cap of the search statement. Server-side by
    # decision — the user narrows the query instead of paging.
    PER_DOCTYPE_CAP = 5

    # Overall response cap across all groups. Server-side by decision.
    OVERALL_CAP = 25

    # Depth cap of the child → root composition walk. Composition chains
    # are shallow; the cap also stops a corrupt parent cycle.
    MAX_COMPOSITION_DEPTH = 8

    # One search hit. Labels only — the response never carries document
    # `content`, so no field-maskable value leaves the server. For a hit
    # on a composition child, the root anchor (`root_doctype`, `root_id`,
    # `root_display_name`) is the aggregate root the hit resolves to, and
    # `child_label` is the matched child's own label; for every other hit
    # the anchor is the hit itself and `child_label` is nil.
    record Hit,
      domain : String,
      doc_type : String,
      id : String,
      display_name : String?,
      rank : Float64,
      root_doctype : String,
      root_id : String,
      root_display_name : String?,
      child_label : String?

    # The cross-doctype search engine behind `GET|QUERY /Api/:domain/search`
    # and `GET|QUERY /Api/search`.
    #
    # A domain sits on one database, so the domain-scoped search is one SQL
    # statement. The app-wide search has no cross-database SQL: the readable
    # domains are grouped by their routed database (`Database.group_by_database`),
    # the statement runs once per group, and the groups merge and re-rank here.
    #
    # One statement per database: for every contributing doctype — the caller
    # holds a read grant and the definition declares a non-empty `search`
    # template — one OR-joined branch over `projections`, ranked by trigram
    # similarity and capped per doctype. Composition children resolve their
    # aggregate root inside the same statement (a recursive CTE over
    # `meta->>'parent_id'`), and the root's own read scope is enforced there:
    # a root the caller cannot read, a deleted root, or a broken chain drops
    # the hit. Scope fragments come from `RBAC::ReadEnforcer.list_where_clauses`
    # with placeholder indices threaded across branches and bind parameters.
    module Query
      # Searches one domain. Returns nil when the URL domain does not exist
      # (the route answers a non-disclosing 404), the hits otherwise.
      def self.domain_search(term : String, domain : String, auth_context : RBAC::AuthContext) : Array(Hit)?
        contributions = Database.with_db(:read_only, "core") do |core_db|
          next nil unless domain_exists?(core_db, domain)
          collect(core_db, auth_context) { |owner| owner == domain }
        end
        return nil if contributions.nil?
        return [] of Hit if contributions.empty?

        Database.with_db(:read_only, domain) do |db|
          run_statement(db, contributions, term, auth_context)
        end
      end

      # Searches every live domain: the contributions grouped by routed
      # database, one statement per group, merged and re-ranked in Crystal.
      def self.app_search(term : String, auth_context : RBAC::AuthContext) : Array(Hit)
        contributions = Database.with_db(:read_only, "core") do |core_db|
          collect(core_db, auth_context) { |owner| live_domain?(core_db, owner) }
        end
        return [] of Hit if contributions.empty?

        hits = [] of Hit
        domains = contributions.map(&.domain).uniq!
        Database.group_by_database(domains).each do |group_domains|
          group = contributions.select { |c| group_domains.includes?(c.domain) }
          Database.with_db(:read_only, group_domains.first) do |db|
            hits.concat(run_statement(db, group, term, auth_context))
          end
        end
        merge(hits)
      end

      # Ranks, ties, and caps the merged app-wide hits. Sorting on the
      # full key keeps equal ranks deterministic: domain, doctype, id.
      private def self.merge(hits : Array(Hit)) : Array(Hit)
        hits.sort_by { |h| {-h.rank, h.domain, h.doc_type, h.id} }.first(OVERALL_CAP)
      end

      # True when the domain exists as a live `core.Domain` row.
      private def self.domain_exists?(db : DB::Connection, domain : String) : Bool
        exists = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
          domain,
          as: Int32,
        )
        !exists.nil?
      end

      # True when the domain is live — a `core.Domain` row that is not a
      # draft. Draft domains publish nothing; their doctypes stay out of
      # the app-wide search.
      private def self.live_domain?(db : DB::Connection, domain : String) : Bool
        db.query_one?(
          <<-SQL,
            SELECT 1 FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL
              AND (content->>'draft' IS NULL OR content->>'draft' != 'true')
          SQL
          domain,
          as: Int32,
        ) != nil
      end

      # ── Contributing doctypes ───────────────────────────────────────────

      # One (domain, doctype) pair that joins the statement.
      private record Contribution,
        domain : String,
        doctype : String,
        definition : Doctype::DoctypeDefinition

      # Enumerates the live doctypes whose owning domain passes the block,
      # the caller holds a read grant on, and whose definition declares a
      # non-empty `search` template. Runs on the control-plane database
      # that hosts the `core.DocType` rows.
      private def self.collect(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        &domain_allowed : String -> Bool
      ) : Array(Contribution)
        rows = db.query_all(
          <<-SQL,
            SELECT id, content->>'domain' AS owner
            FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL
            ORDER BY id ASC
          SQL
          as: {String, String?},
        )

        contributions = [] of Contribution
        rows.each do |(id, owner)|
          next if owner.nil?
          parts = id.split('.', 2)
          next unless parts.size == 2
          doctype = parts[1]
          next unless domain_allowed.call(owner)
          next unless readable?(auth_context, owner, doctype)
          definition = Doctype::DefinitionStore.fetch(db, id)
          next if definition.nil?
          search = definition.search
          next if search.nil? || search.empty?
          contributions << Contribution.new(owner, doctype, definition)
        end
        contributions
      end

      # True when the caller holds a read grant — `can?` is not `Denied`.
      # A preview principal cannot call `can?` (it raises by contract);
      # its authorization is purely domain-scoped, so the bound draft
      # domain passes and the enforcer narrows rows at query time.
      private def self.readable?(auth_context : RBAC::AuthContext, domain : String, doctype : String) : Bool
        return true if auth_context.system?
        return domain == auth_context.preview_domain if auth_context.preview?
        !auth_context.can?("read", domain, [doctype]).is_a?(RBAC::CanResult::Denied)
      end

      # ── Statement build and run ─────────────────────────────────────────

      # Builds the statement for one database and runs it.
      private def self.run_statement(
        db : DB::Connection,
        contributions : Array(Contribution),
        term : String,
        auth_context : RBAC::AuthContext,
      ) : Array(Hit)
        sql, params = build_statement(db, contributions, term, auth_context)
        rows = db.query_all(
          sql,
          args: params,
          as: {String, String, String, String?, Float64, String, String, String?, String?},
        )
        rows.map do |(domain, doc_type, id, display_name, score, root_type, root_id, root_display_name, child_label)|
          Hit.new(domain, doc_type, id, display_name, score, root_type, root_id, root_display_name, child_label)
        end
      end

      # Builds the search statement for one database. Placeholder indices
      # thread across branches and bind parameters in one shared array;
      # the folded term and the per-doctype cap bind once and are reused
      # by every branch.
      #
      # Scope fragments of one (domain, doctype) pair are compiled once
      # and cached: a composition root that is itself searchable reuses
      # its branch's fragment SQL and already-bound parameters in the
      # root scope check.
      private def self.build_statement(
        db : DB::Connection,
        contributions : Array(Contribution),
        term : String,
        auth_context : RBAC::AuthContext,
      ) : {String, Array(::DB::Any)}
        params = [] of ::DB::Any
        params << Util::LikeEscape.escape(Util::DiacriticFold.fold(term))
        term_idx = params.size
        params << PER_DOCTYPE_CAP
        cap_idx = params.size

        fragments = {} of Tuple(String, String) => Array(String)
        branches = [] of String
        chain_rows = [] of Tuple(String, String, String)
        root_pairs = [] of Tuple(String, String)

        contributions.each do |c|
          domain_idx = params.size + 1
          params << c.domain
          doctype_idx = params.size + 1
          params << c.doctype

          frag = scope_fragments(db, c.domain, c.doctype, auth_context, params, fragments)
          branches << branch_sql(c, domain_idx, doctype_idx, term_idx, cap_idx, frag)

          member_of = c.definition.member_of
          next if member_of.nil?
          chain, root = walk_chain(c.domain, c.doctype, member_of, db)
          chain_rows.concat(chain)
          root_pairs << {c.domain, root} unless root.nil?
        end

        hits_sql = branches.join("\nUNION ALL\n")
        return plain_statement(hits_sql, params) if chain_rows.empty?
        root_statement(db, hits_sql, chain_rows, root_pairs.uniq, auth_context, params, fragments)
      end

      # Compiles the read-scope fragments of one (domain, doctype) pair
      # once, threading their placeholder indices into the shared params.
      private def self.scope_fragments(
        db : DB::Connection,
        domain : String,
        doctype : String,
        auth_context : RBAC::AuthContext,
        params : Array(::DB::Any),
        cache : Hash(Tuple(String, String), Array(String)),
      ) : Array(String)
        cached = cache[{domain, doctype}]?
        return cached unless cached.nil?

        clauses, frag_params = RBAC::ReadEnforcer.list_where_clauses(
          db, domain, doctype, auth_context, start_idx: params.size + 1)
        params.concat(frag_params)
        cache[{domain, doctype}] = clauses
        clauses
      end

      # One per-doctype branch: a ranked, capped subselect the outer query
      # unions. `is_child` is known at build time from the definition.
      private def self.branch_sql(
        c : Contribution,
        domain_idx : Int32,
        doctype_idx : Int32,
        term_idx : Int32,
        cap_idx : Int32,
        fragments : Array(String),
      ) : String
        scope_sql = fragments.empty? ? "" : " AND (#{fragments.join(" OR ")})"
        is_child = !c.definition.member_of.nil?
        <<-SQL
          (SELECT id, domain, doc_type, display_name, meta->>'parent_id' AS parent_id,
                  #{is_child} AS is_child,
                  similarity(search, $#{term_idx})::float8 AS score
           FROM projections
           WHERE domain = $#{domain_idx} AND doc_type = $#{doctype_idx} AND deleted_at IS NULL
             AND search ILIKE '%' || $#{term_idx} || '%' ESCAPE '\\'#{scope_sql}
           ORDER BY score DESC
           LIMIT $#{cap_idx})
        SQL
      end

      # Walks one doctype's `member_of` chain: the composition rows the
      # statement's recursive CTE may climb, plus the chain-end root when
      # the chain terminates at a doctype that declares no parent. Rows are
      # domain-scoped — composition is same-domain, and two domains may
      # declare same-named doctypes with different parents. A missing
      # definition or a cycle yields no root — the walk cannot prove a
      # readable terminal, so the hit drops (fail closed).
      private def self.walk_chain(
        domain : String,
        doctype : String,
        first_parent : String,
        db : DB::Connection,
      ) : {Array(Tuple(String, String, String)), String?}
        chain = [] of Tuple(String, String, String)
        current = doctype
        parent = first_parent

        while chain.size < MAX_COMPOSITION_DEPTH
          parent_name = parent
          break if parent_name.nil?
          chain << {domain, current, parent_name}
          parent_def = Doctype::DefinitionStore.fetch(db, "#{domain}.#{parent_name}")
          current = parent_name
          return {chain, nil} if parent_def.nil?
          parent = parent_def.member_of
        end

        root = parent.nil? ? current : nil
        {chain, root}
      end

      # ── Statement shapes ────────────────────────────────────────────────

      # The plain shape: every hit is its own root anchor.
      private def self.plain_statement(hits_sql : String, params : Array(::DB::Any)) : {String, Array(::DB::Any)}
        params << OVERALL_CAP
        overall_idx = params.size
        sql = <<-SQL
          WITH hits AS (
            #{hits_sql}
          )
          SELECT h.domain, h.doc_type, h.id, h.display_name, h.score,
                 h.doc_type AS root_type, h.id AS root_id,
                 h.display_name AS root_display_name,
                 NULL::text AS child_label
          FROM hits h
          ORDER BY h.score DESC, h.domain, h.doc_type, h.id
          LIMIT $#{overall_idx}
        SQL
        {sql, params}
      end

      # The root-resolving shape: composition children climb to their
      # aggregate root in a recursive CTE, and the root's own read scope
      # is enforced on the anchor. A child hit without a readable, live,
      # intact root falls out of the final WHERE — nothing reaches the
      # client.
      private def self.root_statement(
        db : DB::Connection,
        hits_sql : String,
        chain_rows : Array(Tuple(String, String, String)),
        root_pairs : Array(Tuple(String, String)),
        auth_context : RBAC::AuthContext,
        params : Array(::DB::Any),
        fragments : Hash(Tuple(String, String), Array(String)),
      ) : {String, Array(::DB::Any)}
        pm_values = chain_rows.map do |(domain, child_dt, parent_dt)|
          domain_idx = params.size + 1
          params << domain
          child_idx = params.size + 1
          params << child_dt
          parent_idx = params.size + 1
          params << parent_dt
          "($#{domain_idx}, $#{child_idx}, $#{parent_idx})"
        end.join(", ")

        root_scope = root_pairs.map do |(domain, doctype)|
          frag = scope_fragments(db, domain, doctype, auth_context, params, fragments)
          domain_idx = params.size + 1
          params << domain
          doctype_idx = params.size + 1
          params << doctype
          root_branch(frag, domain_idx, doctype_idx)
        end.join("\n             OR ")

        # No provable root anywhere (every chain ended at a missing
        # definition): the child hits drop — fail closed — and only the
        # root-doctype hits answer.
        scope_filter = if root_scope.empty?
                         "h.is_child = FALSE"
                       else
                         "h.is_child = FALSE\n             OR (#{root_scope})"
                       end

        params << OVERALL_CAP
        overall_idx = params.size
        sql = <<-SQL
          WITH RECURSIVE
          pm(domain, child_dt, parent_dt) AS (VALUES #{pm_values}),
          hits AS (
            #{hits_sql}
          ),
          walk AS (
            SELECT h.id AS hit_id, h.domain, h.doc_type AS node_type, h.id AS node_id,
                   h.parent_id AS node_parent_id, h.display_name AS node_display_name,
                   0 AS depth
            FROM hits h
            WHERE h.is_child
            UNION ALL
            SELECT w.hit_id, p.domain, p.doc_type, p.id, p.meta->>'parent_id',
                   p.display_name, w.depth + 1
            FROM walk w
            JOIN pm ON pm.domain = w.domain AND pm.child_dt = w.node_type
            JOIN projections p
              ON p.domain = w.domain AND p.doc_type = pm.parent_dt
             AND p.id = w.node_parent_id AND p.deleted_at IS NULL
            WHERE w.depth < #{MAX_COMPOSITION_DEPTH}
          ),
          terminal AS (
            SELECT DISTINCT ON (w.hit_id)
                   w.hit_id, w.domain AS root_domain, w.node_type AS root_type,
                   w.node_id AS root_id, w.node_display_name AS root_display_name
            FROM walk w
            WHERE NOT EXISTS (
              SELECT 1 FROM pm
              WHERE pm.domain = w.domain AND pm.child_dt = w.node_type
            )
            ORDER BY w.hit_id, w.depth DESC
          )
          SELECT h.domain, h.doc_type, h.id, h.display_name, h.score,
                 COALESCE(t.root_type, h.doc_type) AS root_type,
                 COALESCE(t.root_id, h.id) AS root_id,
                 COALESCE(t.root_display_name, h.display_name) AS root_display_name,
                 CASE WHEN h.is_child THEN h.display_name END AS child_label
          FROM hits h
          LEFT JOIN terminal t ON t.hit_id = h.id
          WHERE #{scope_filter}
          ORDER BY h.score DESC, h.domain, h.doc_type, h.id
          LIMIT $#{overall_idx}
        SQL
        {sql, params}
      end

      # One root-doctype scope branch of the final WHERE: the terminal
      # anchor must be a live row of that doctype that satisfies the root
      # doctype's read scope. The fragment SQL runs inside the EXISTS
      # subquery, where the bare `content` / `meta` / `id` references of
      # the enforcer's predicates resolve to the root row.
      private def self.root_branch(fragments : Array(String), domain_idx : Int32, doctype_idx : Int32) : String
        scope_sql = fragments.empty? ? "" : " AND (#{fragments.join(" OR ")})"
        <<-SQL
          (t.root_type = $#{doctype_idx} AND t.root_domain = $#{domain_idx} AND EXISTS (
             SELECT 1 FROM projections root
             WHERE root.id = t.root_id AND root.domain = t.root_domain
               AND root.doc_type = t.root_type#{scope_sql}
           ))
        SQL
      end
    end
  end
end
