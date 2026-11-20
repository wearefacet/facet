# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "log"
require "../database"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../mutation/client"
require "../mutation/json_diff"
require "../util/script_helpers"
require "../event/publisher"
require "../hooks/definition"
require "./validator"

module Facet
  module Grants
    # Files grant tickets at publish time.
    #
    # After the publish's structure lands, the flow scans the published
    # doctypes and the published hooks for outbound cross-domain edges:
    #
    # 1. Replicate fields whose `via` targets a foreign doctype.
    # 2. Event hooks whose `source.domain` is foreign.
    #
    # Per foreign producer domain, edges are grouped by producer doctype;
    # the producer's current definition supplies each referenced field's
    # tags (untagged fields contribute `default`). Hook edges contribute
    # the doctype under the `default` tag — the fire gate only needs the
    # doctype named; the content projection still masks per tag. A
    # domain-wide hook (no `source.doc_type`) expands over every producer
    # doctype.
    #
    # The consumer-side ticket is then filed or merged inside the
    # producer's subtree — the one bounded foreign write the publish
    # performs, attributed in the audit log through `actioner_id` (O5).
    # Tickets are filed only into live producer domains; draft producers
    # surface as `/check` diagnostics instead.
    #
    # ## Merge and acceptance rules
    #
    # - No existing grant: file one. `active` follows D11 — `true` when
    #   the publisher holds the `activate` named action on
    #   `core.DomainGrant` (the publish route resolves the verdict and
    #   passes it down), `false` otherwise. System-attributed publishes
    #   without a real caller file inactive.
    # - Existing grant, union widens the bundle: an **active** grant drops
    #   to `active: false` (D6) unless the publisher holds the acceptance
    #   right (D11); an inactive grant stays inactive. The merged
    #   resources always land.
    # - Existing grant, union unchanged: touch nothing — a re-publish
    #   with no resource change never re-opens acceptance.
    module PublishTickets
      Log = ::Log.for("facet.grants.publish_tickets")

      # One (producer, doctype) edge with the tags the consumer's edges
      # reference on it. An edge whose tags include `default` pulls the
      # producer's untagged fields.
      record Filing,
        doctype : String,
        tags : Array(String)

      # One producer's ticket outcome, as the publish report renders it.
      # All of the publish's edges into one producer fold into the same
      # grant document (one grant per (consumer, producer) pair), so the
      # acceptance state is per ticket.
      record Ticket,
        producer : String,
        filed : Bool,   # true — a new grant document was created; false — merged into an existing one
        active : Bool,  # the grant's resulting active state
        dropped : Bool, # true — an active grant was widened and dropped to inactive (D6 re-acceptance)
        edges : Array(Filing)

      private record GrantRow,
        id : String,
        active : Bool,
        resources : Array(Validator::ResourceEntry)

      # Files tickets for every outbound cross-domain edge in the
      # published definitions + hooks. `consumer` is the publishing
      # (target) domain; `publisher_holds_acceptance` is the D11 verdict
      # resolved by the route. Runs inside the publish transaction.
      # Returns one `Ticket` per touched producer, for the publish report.
      def self.file(
        db : DB::Connection,
        consumer : String,
        definitions : Array(Doctype::DoctypeDefinition),
        hooks : Array(Hooks::Definition::Hook),
        publisher_holds_acceptance : Bool,
        actioner_id : String,
      ) : Array(Ticket)
        tickets = [] of Ticket

        group_edges(db, consumer, definitions, hooks).each do |producer, per_doctype|
          next unless live_domain?(db, producer)

          edges = per_doctype.map { |doctype, tags| Filing.new(doctype: doctype, tags: tags.to_a) }

          row = fetch_grant_row(db, producer, consumer)
          if row.nil?
            create_grant(db, producer, consumer, resource_pairs(per_doctype), active: publisher_holds_acceptance, actioner_id: actioner_id)
            tickets << Ticket.new(producer: producer, filed: true, active: publisher_holds_acceptance, dropped: false, edges: edges)
            next
          end

          merged, widened = merge_resources(row.resources, resource_pairs(per_doctype))
          next unless widened

          # A widening merge of an active grant needs re-acceptance (D6) —
          # unless the publisher holds the acceptance right (D11). A
          # deactivated grant stays deactivated.
          new_active = row.active ? publisher_holds_acceptance : false
          patch_grant(db, row.id, merged, new_active, actioner_id)
          tickets << Ticket.new(
            producer: producer, filed: false, active: new_active,
            dropped: row.active && !new_active, edges: edges,
          )
        end

        tickets
      end

      # ── Private ─────────────────────────────────────────────────────

      # Scans the published definitions and hooks for outbound cross-domain
      # edges and groups the referenced source fields' tags per (producer,
      # doctype).
      private def self.group_edges(
        db : DB::Connection,
        consumer : String,
        definitions : Array(Doctype::DoctypeDefinition),
        hooks : Array(Hooks::Definition::Hook),
      ) : Hash(String, Hash(String, Set(String)))
        edges = Hash(String, Hash(String, Set(String))).new

        definitions.each do |definition|
          definition.fields.each do |_field_name, field_def|
            rep_config = field_def.replicate
            next if rep_config.nil?

            via_field = definition.fields[rep_config.via]?
            next if via_field.nil?
            source_qualified = via_field.qualified_doctype
            next if source_qualified.nil?

            source_domain, source_doctype = split_qualified(source_qualified)
            next if source_domain.nil? || source_doctype.nil?
            next if source_domain == consumer

            tags = field_tags(db, source_qualified, rep_config.field)
            add_edge(edges, source_domain, source_doctype, tags)
          end
        end

        hooks.each do |hook|
          next if hook.kind != :event
          source_domain = hook.source_domain
          next if source_domain.nil? || source_domain == consumer

          if source_doc_type = hook.source_doc_type
            # The hook admits the doctype as a whole — the fire gate checks
            # `active?` per doctype. `default` is the minimal honest claim;
            # the content projection still masks per tag.
            add_edge(edges, source_domain, source_doc_type, [DEFAULT_TAG])
          else
            # Domain-wide hook — expand over every producer doctype.
            fetch_doctypes_in_domain(db, source_domain).each do |doctype|
              add_edge(edges, source_domain, doctype, [DEFAULT_TAG])
            end
          end
        end

        edges
      end

      private def self.add_edge(
        edges : Hash(String, Hash(String, Set(String))),
        producer : String,
        doctype : String,
        tags : Array(String),
      ) : Nil
        per_doctype = edges[producer] ||= {} of String => Set(String)
        set = per_doctype[doctype] ||= Set(String).new
        tags.each { |t| set << t }
      end

      # Adapts the per-doctype tag sets into the `{doctype, tags}` pairs
      # the create/merge helpers consume.
      private def self.resource_pairs(per_doctype : Hash(String, Set(String))) : Array({String, Array(String)})
        per_doctype.map { |doctype, tags| {doctype, tags.to_a} }
      end

      # Resolves the tags of one source field through the producer's
      # definition. Untagged fields contribute `default`.
      private def self.field_tags(db : DB::Connection, source_qualified : String, source_field : String) : Array(String)
        defn = Doctype::DefinitionStore.fetch(db, source_qualified)
        field = defn.try(&.fields[source_field]?)
        return [DEFAULT_TAG] if field.nil?
        field.tags || [DEFAULT_TAG]
      end

      private def self.fetch_doctypes_in_domain(db : DB::Connection, domain : String) : Array(String)
        db.query_all(
          "SELECT content->>'doctype' FROM projections " \
          "WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL " \
          "AND content->>'domain' = $1",
          domain,
          as: String,
        )
      end

      private def self.split_qualified(qualified : String) : {String?, String?}
        parts = qualified.split('.', 2)
        parts.size == 2 ? {parts[0], parts[1]} : {nil, nil}
      end

      private def self.live_domain?(db : DB::Connection, domain : String) : Bool
        # Mirrors `Grants::Registry.fetch_live_domains`: a domain is live
        # when it exists, is not deleted, and carries `draft != true` — an
        # absent draft key counts as live (NULL passes the registry
        # predicate).
        row = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL " \
          "AND (content->>'draft' IS NULL OR content->>'draft' != 'true')",
          domain,
          as: Int32,
        )
        !row.nil?
      end

      # The grant under the producer admitting the consumer, or nil. The
      # parent link (`meta.parent_id`) is the producer's bare domain id —
      # the `core.Domain` document id IS the domain name. A producer holds
      # one grant per consumer, so the consumer predicate must filter in
      # the SQL (a single-row read would otherwise raise on a producer
      # with two or more grants). `consumer_domain` is stored in two
      # shapes — qualified (`core.Domain.<name>`) by the reference
      # normalization and publish filing, bare by hand-authored grants —
      # both are matched. The expression is the field's btree index
      # (`Index::Planner.compute_reference_desired`), so the lookup stays
      # indexed.
      private def self.fetch_grant_row(db : DB::Connection, producer : String, consumer : String) : GrantRow?
        row = db.query_one?(
          <<-SQL,
            SELECT id,
                   content->>'active' AS active,
                   content->'resources' AS resources
            FROM projections
            WHERE domain = 'core' AND doc_type = 'DomainGrant' AND deleted_at IS NULL
              AND meta->>'parent_id' = $1
              AND content->>'consumer_domain' IN ($2, 'core.Domain.' || $2)
          SQL
          producer, consumer,
        ) { |rs| {rs.read(String), rs.read(String?), rs.read(JSON::Any?)} }
        return nil if row.nil?

        id, active, resources_raw = row
        resources = Grants::Validator.parse_resources(resources_raw) || [] of Validator::ResourceEntry
        GrantRow.new(id: id, active: active == "true", resources: resources)
      end

      # Unions the additions into the existing entries. Returns the merged
      # resource array and whether the union widened the bundle (a new
      # doctype entry, or new tag names on an existing entry).
      private def self.merge_resources(
        existing : Array(Validator::ResourceEntry),
        additions : Array({String, Array(String)}),
      ) : {Array({String, Array(String)}), Bool}
        by_doctype = existing.to_h { |e| {e.doctype, e.tags.to_set} }
        widened = false

        additions.each do |doctype, tags|
          current = by_doctype[doctype]?
          if current.nil?
            by_doctype[doctype] = tags.to_set
            widened = true
          else
            before = current.size
            tags.each { |t| current << t }
            widened = true if current.size > before
          end
        end

        merged = by_doctype.map { |doctype, tags| {doctype, tags.to_a} }
        {merged, widened}
      end

      private def self.create_grant(
        db : DB::Connection,
        producer : String,
        consumer : String,
        resources : Array({String, Array(String)}),
        active : Bool,
        actioner_id : String,
      ) : Nil
        content = grant_content(consumer, resources, active)
        doc_id = Util::ScriptHelpers.ulid
        mut_id = Mutation::Client.create(
          db, "core", "DomainGrant",
          doc_id: doc_id,
          content: content.to_json,
          meta: %({"parent_id": #{producer.to_json}}),
          actioner_id: actioner_id,
        )
        Event::Publisher.enqueue(
          domain: "core", doc_type: "DomainGrant", doc_id: doc_id,
          event: "created", mutation_id: mut_id, actioner_id: actioner_id,
        )
      end

      private def self.patch_grant(
        db : DB::Connection,
        grant_id : String,
        resources : Array({String, Array(String)}),
        active : Bool,
        actioner_id : String,
      ) : Nil
        current = Mutation::Client.fetch_content(db, "core", "DomainGrant", grant_id)

        # Patch shape: the resources array replaces wholesale, the active
        # flag flips when the D6/D11 verdict differs from the stored one.
        desired = current.as_h?.try(&.dup) || {} of String => JSON::Any
        desired["resources"] = JSON.parse(resources.map { |doctype, tags| {doctype: doctype, tags: tags} }.to_json)
        desired["active"] = JSON::Any.new(active)

        diff = Mutation::JsonDiff.diff(current, JSON::Any.new(desired))
        return if diff.empty?

        mut_id = Mutation::Client.update(
          db, "core", "DomainGrant", grant_id,
          diff_json: diff.to_json,
          actioner_id: actioner_id,
        )
        Event::Publisher.enqueue(
          domain: "core", doc_type: "DomainGrant", doc_id: grant_id,
          event: "updated", mutation_id: mut_id, actioner_id: actioner_id,
        )
      end

      private def self.grant_content(consumer : String, resources : Array({String, Array(String)}), active : Bool) : JSON::Any
        JSON.parse(%({
          "consumer_domain": "core.Domain.#{consumer}",
          "resources": #{resources.map { |doctype, tags| {doctype: doctype, tags: tags} }.to_json},
          "active": #{active}
        }))
      end
    end
  end
end
