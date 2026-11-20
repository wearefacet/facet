# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../doctype/doctype_definition"
require "../grants"

module Facet
  module Replication
    # Validator for cross-domain field replication.
    #
    # It has two entry points with different enforcement levels:
    #
    # - `validate_invariants` — the hard invariants, enforced at doctype
    #   create/update time. A violation rejects the definition with a 422.
    # - `validate` — the advisory diagnostics, invoked by `Doctype::Check`
    #   (the `/check` endpoint) on demand. Each failure becomes a warning
    #   issue, never a create/update rejection.
    #
    # ## Why the split
    #
    # The advisory checks (grant coverage, source doctype/field existence,
    # type match, draft-source isolation) depend on other domains and would
    # create ordering dependencies between domains (consumer before
    # producer, or before the producer's grant is issued). The runtime
    # replication path already silently no-ops on those broken configs: the
    # registry's `build_binding` drops bindings whose grant is missing or
    # whose `via` field is malformed, and `SyncPull` returns `nil` when the
    # source doctype or document doesn't exist. Surfacing them as `/check`
    # diagnostics lets an author troubleshoot at runtime without blocking
    # iteration.
    #
    # The hard invariants, by contrast, are tag-boundary and one-hop
    # guarantees that must never be authored: a replica-of-replica breaks
    # the exactly-one-hop contract, and replicating a `secret` field copies
    # the secret's marker object into the replica's public content (a
    # tag-boundary bypass). A replica whose tags do not cover the source
    # field's tags is a third tag-boundary bypass: the replica's own tags
    # govern read visibility of the copied value, so a tag the source
    # carries but the replica does not would show the value to roles that
    # cannot read the source. An unqualified `via` reference target (e.g.
    # `doctype: Vault`) also fails closed: it can never resolve a source, so
    # the secret-source check would otherwise be skipped. These are enforced
    # at create/update time.
    #
    # ## Advisory checks performed by `validate`
    #
    # 1. The `via` field must name a `reference`-typed field on the
    #    same doctype.
    # 2. The `via` field must not itself be a replica (no transitive
    #    replication). The source field on the producer side must also
    #    not be a replica.
    # 3. The source doctype is resolved via the reference field's
    #    `doctype` (e.g. `"identity.Person"`).
    # 4. The requested `field` must exist on the source doctype.
    # 5. Tag coverage — the replica field must carry every tag the
    #    source field carries (the same rule the hard gate enforces).
    # 6. The declared `type` must match the source field's type.
    # 7. Grant coverage when the edge is cross-domain: an active
    #    `core.DomainGrant` under the producer domain must admit the
    #    consumer on the source doctype, and the source field's tags
    #    (untagged → `["default"]`) must share at least one name with
    #    the resource entry's granted tags. Distinct diagnostics for no
    #    grant, an inactive grant, a missing doctype entry, and an
    #    uncovered tag. A same-domain edge needs no grant (D7).
    # 8. A live consumer domain must not replicate from a draft source
    #    domain — drafts are excluded from the runtime registry, so such
    #    a binding would be silently inert.
    module Validator
      # Validates all replicate fields in a doctype definition.
      #
      # `consumer_definition` — the doctype being validated (consumer).
      # `db` — database connection for looking up producer doctypes
      #        and domain grants.
      #
      # Returns an array of error strings (empty if valid).

      def self.validate(
        consumer_definition : Doctype::DoctypeDefinition,
        db : DB::Connection,
      ) : Array(String)
        errors = [] of String

        consumer_definition.fields.each do |field_name, field_def|
          rep_config = field_def.replicate
          next if rep_config.nil?

          validate_replicate_field(consumer_definition, field_name, field_def, rep_config, db, errors)
        end

        errors
      end

      # Validates the hard replication invariants that must hold at
      # authoring time (doctype create/update). Unlike `validate`, which
      # produces advisory `/check` diagnostics, these invariants are a hard
      # gate — a violation rejects the definition with a 422.
      #
      # The invariants are:
      #
      # 1. the `via` field must not itself be a replica;
      # 2. the `via` reference target must be qualified — an unqualified
      #    target (e.g. `doctype: Vault`) can never resolve a source, so the
      #    gate fails closed instead of skipping the secret-source check;
      # 3. the source field must not be a replica (no replica-of-replica);
      # 4. the source field must not be a `secret` field;
      # 5. the replica field must carry every tag the source field
      #    carries. The replica's own tags govern read visibility of the
      #    copied value — a tag the source carries but the replica does
      #    not would show the copied value to roles that cannot read the
      #    source.
      #
      # Returns an array of error strings (empty if valid). A well-formed
      # source that cannot be resolved yet (missing source doctype or source
      # field) is left to the advisory diagnostics — no invariant fires on
      # it, so a consumer can land before its producer (B-164).
      def self.validate_invariants(
        definition : Doctype::DoctypeDefinition,
        db : DB::Connection,
      ) : Array(String)
        errors = [] of String

        definition.fields.each do |field_name, field_def|
          rep_config = field_def.replicate
          next if rep_config.nil?

          # 1. The `via` field must not itself be a replica.
          via_field = definition.fields[rep_config.via]?
          if via_field.try(&.replicated?)
            errors << "Replicate field '#{field_name}': 'via' field '#{rep_config.via}' is itself a replicated field. Cannot replicate through a replica."
            next
          end

          # 2. An unqualified `via` target can never resolve a source, so the
          # secret-source check below would never run. Fail closed with the
          # same message `/check` shows (F09-02). A well-formed source that
          # does not exist yet stays advisory (B-164).
          if target = unqualified_via_target(via_field)
            errors << invalid_source_doctype_error(field_name, target)
            next
          end

          # Resolve the source field. Advisory failures are discarded here —
          # they are surfaced by `validate` on `/check`.
          source_info = resolve_source_info(definition, field_name, rep_config, db, [] of String)
          next if source_info.nil?

          _, _, source_doctype_id, source_field_def = source_info

          # 3. The source field must not be a replica (no replica-of-replica).
          if source_field_def.replicated?
            errors << "Replicate field '#{field_name}': source field '#{rep_config.field}' on '#{source_doctype_id}' is itself a replicated field. Cannot replicate from a replica."
            next
          end

          # 4. The source field must not be a secret field.
          if source_field_def.type.try(&.type_name) == "secret"
            errors << "Replicate field '#{field_name}': source field '#{rep_config.field}' on '#{source_doctype_id}' is a secret field. Cannot replicate a secret."
            next
          end

          # 5. The replica field must carry every tag the source field
          # carries (B-271). The replica's own tags govern read visibility
          # of the copied value — tag-scoped enforcement does not follow
          # the value.
          if error = tag_escape_error(field_name, rep_config, source_doctype_id, source_field_def, field_def)
            errors << error
            next
          end
        end

        errors
      end

      # Validates a single replicate field declaration.
      private def self.validate_replicate_field(
        consumer_def : Doctype::DoctypeDefinition,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        rep_config : Doctype::ReplicateConfig,
        db : DB::Connection,
        errors : Array(String),
      ) : Nil
        # Steps 1-3: resolve source info (via field → source doctype + field)
        source_info = resolve_source_info(consumer_def, field_name, rep_config, db, errors)
        return if source_info.nil?

        source_domain, source_doctype, source_doctype_id, source_field_def = source_info

        # 4. Verify the source field must be a genuine field (not a replica)
        if source_field_def.replicated?
          errors << "Replicate field '#{field_name}': source field '#{rep_config.field}' on '#{source_doctype_id}' is itself a replicated field. Cannot replicate from a replica."
          return
        end

        # 5. Tag coverage — the same rule the hard gate enforces. `/check`
        # repeats it because a producer-side edit that adds a tag to the
        # source field never re-runs the consumer's hard gate.
        if error = tag_escape_error(field_name, rep_config, source_doctype_id, source_field_def, field_def)
          errors << error
        end

        # 6. Verify type match between consumer's declared type and source field type
        consumer_type = field_def.type
        source_type = source_field_def.type

        if consumer_type && source_type
          unless types_match?(consumer_type, source_type)
            errors << "Replicate field '#{field_name}': type mismatch — consumer declares '#{consumer_type.type_name}' but source field '#{rep_config.field}' is '#{source_type.type_name}' on #{source_doctype_id}"
          end
        end

        # 7. Grant coverage when the edge is cross-domain. A same-domain
        # edge needs no grant: the producer and the consumer are the same
        # bounded context, so the author already controls both
        # definitions.
        if source_domain != consumer_def.domain
          grant_errors = verify_grant(db, source_domain, consumer_def.domain, source_doctype, rep_config.field, source_field_def, field_name)
          errors.concat(grant_errors)
        end
      end

      # Builds the tag-escape error for a resolved replicate edge, or nil
      # when the replica field carries every tag of the source field.
      # Untagged fields resolve to `["default"]` (`Grants::DEFAULT_TAG`) —
      # the same rule the grant check and the registry apply. Shared by
      # `validate_invariants` (the hard gate) and `validate_replicate_field`
      # (the advisory diagnostics) so the two paths cannot disagree.
      private def self.tag_escape_error(
        field_name : String,
        rep_config : Doctype::ReplicateConfig,
        source_doctype_id : String,
        source_field_def : Doctype::FieldDefinition,
        replica_field_def : Doctype::FieldDefinition,
      ) : String?
        source_tags = source_field_def.tags || [Grants::DEFAULT_TAG]
        replica_tags = replica_field_def.tags || [Grants::DEFAULT_TAG]
        missing = source_tags.reject { |tag| replica_tags.includes?(tag) }
        return nil if missing.empty?

        "Replicate field '#{field_name}': source field '#{rep_config.field}' on '#{source_doctype_id}' carries tags (#{missing.join(", ")}) that the replica field does not. Add the missing tags to field '#{field_name}' — a replica must carry every tag of its source."
      end

      # Resolves the `via` reference field and fetches the source doctype + field.
      # Returns nil on any failure (error already appended to `errors`).
      # On success returns a tuple of (source_domain, source_doctype, source_doctype_id, source_field_def).
      private def self.resolve_source_info(
        consumer_def : Doctype::DoctypeDefinition,
        field_name : String,
        rep_config : Doctype::ReplicateConfig,
        db : DB::Connection,
        errors : Array(String),
      ) : {String, String, String, Doctype::FieldDefinition}?
        # 1. Resolve the `via` reference field
        via_field = consumer_def.fields[rep_config.via]?
        if via_field.nil?
          errors << "Replicate field '#{field_name}': 'via' field '#{rep_config.via}' does not exist on #{consumer_def.qualified_name}"
          return nil
        end

        unless via_field.reference?
          type_name = via_field.type.try(&.type_name) || "none"
          errors << "Replicate field '#{field_name}': 'via' field '#{rep_config.via}' must be a reference field (got type: #{type_name})"
          return nil
        end

        # 2. Resolve the source doctype
        source_doctype_id = via_field.qualified_doctype
        if source_doctype_id.nil?
          errors << "Replicate field '#{field_name}': reference field '#{rep_config.via}' has no doctype target"
          return nil
        end

        source_domain, source_doctype = parse_qualified_doctype(source_doctype_id)
        if source_domain.nil? || source_doctype.nil?
          errors << invalid_source_doctype_error(field_name, source_doctype_id)
          return nil
        end

        # 4. Fetch the source doctype definition (needs DB — done here since caller has it)
        source_def = fetch_doctype_definition(db, source_domain, source_doctype)
        if source_def.nil?
          errors << "Replicate field '#{field_name}': source doctype '#{source_doctype_id}' not found"
          return nil
        end

        # 4b. Isolation guard: a live consumer domain must not replicate
        # from a draft source domain. Drafts are excluded from the runtime
        # replication registry entirely, so a replicate edge declared on a
        # draft consumer is inert — but a *live* consumer pointing at a
        # draft source would otherwise silently stop working the moment the
        # draft is published/dropped. Reject it at authoring time with a
        # clear error instead. (A draft consumer referencing a draft source
        # is allowed and inert — drafts can't publish replication in practice
        # because both are filtered out at runtime.)
        if draft_domain?(db, source_domain) && !draft_domain?(db, consumer_def.domain)
          errors << "Replicate field '#{field_name}': source domain '#{source_domain}' is a draft — live domains cannot replicate from draft domains"
          return nil
        end

        # 5. Verify the source field exists
        source_field_def = source_def.fields[rep_config.field]?
        if source_field_def.nil?
          errors << "Replicate field '#{field_name}': field '#{rep_config.field}' does not exist on source doctype '#{source_doctype_id}'"
          return nil
        end

        {source_domain, source_doctype, source_doctype_id, source_field_def}
      end

      # Verifies that the producer domain holds an active `core.DomainGrant`
      # admitting the consumer on the source doctype with tag coverage for
      # the source field. Distinct diagnostics per failure shape (no grant /
      # inactive / doctype not granted / tag not covered).
      private def self.verify_grant(
        db : DB::Connection,
        producer_domain : String,
        consumer_domain : String,
        source_doctype : String,
        source_field : String,
        source_field_def : Doctype::FieldDefinition,
        consumer_field_name : String,
      ) : Array(String)
        errors = [] of String
        field_tags = source_field_def.tags || [Grants::DEFAULT_TAG]

        grants = fetch_grants(db, producer_domain, consumer_domain)
        if grants.empty?
          errors << "Replicate field '#{consumer_field_name}': no core.DomainGrant under domain '#{producer_domain}' admitting '#{consumer_domain}' — the consumer's publish files a ticket, or the producer creates one by hand"
          return errors
        end

        unless grants.any?(&.active)
          errors << "Replicate field '#{consumer_field_name}': grant from '#{producer_domain}' to '#{consumer_domain}' exists but is inactive — awaiting the producer's acceptance"
          return errors
        end

        matching = grants.select(&.active).select(&.resources.has_key?(source_doctype))
        if matching.empty?
          errors << "Replicate field '#{consumer_field_name}': active grant from '#{producer_domain}' to '#{consumer_domain}' does not name doctype '#{source_doctype}' in its resources"
          return errors
        end

        covered = matching.any? do |g|
          granted = g.resources[source_doctype]?
          granted.nil? ? false : field_tags.any? { |t| granted.includes?(t) }
        end
        unless covered
          granted_all = matching.flat_map { |g| g.resources[source_doctype]? || [] of String }
          granted_all.uniq!
          errors << "Replicate field '#{consumer_field_name}': field '#{source_field}' tags (#{field_tags.join(", ")}) are not covered by the granted tags on '#{source_doctype}' (granted: #{granted_all.join(", ")})"
        end

        errors
      end

      record ProducerGrant,
        active : Bool,
        resources : Hash(String, Array(String))

      # Fetches the grant documents under the producer domain that admit
      # the consumer. The parent link (`meta.parent_id`) is the producer's
      # bare domain id — the `core.Domain` document id IS the domain name.
      # Returns an empty array when none exist.
      private def self.fetch_grants(
        db : DB::Connection,
        producer_domain : String,
        consumer_domain : String,
      ) : Array(ProducerGrant)
        rows = db.query_all(
          <<-SQL,
            SELECT g.content->>'active' AS active,
                   g.content->>'consumer_domain' AS consumer_id,
                   g.content->'resources' AS resources
            FROM projections g
            WHERE g.domain = 'core' AND g.doc_type = 'DomainGrant' AND g.deleted_at IS NULL
              AND g.meta->>'parent_id' = $1
          SQL
          producer_domain,
        ) { |rs| {rs.read(String?), rs.read(String?), rs.read(JSON::Any?)} }

        grants = [] of ProducerGrant
        rows.each do |active, consumer_id, resources_raw|
          consumer = consumer_id.try { |c| c.starts_with?("core.Domain.") ? c["core.Domain.".size..] : c }
          next unless consumer == consumer_domain
          resources = Grants::Validator.parse_resources(resources_raw)
          next if resources.nil?
          mask = resources.to_h { |entry| {entry.doctype, entry.tags} }
          grants << ProducerGrant.new(active: active == "true", resources: mask)
        end
        grants
      end

      # Returns the `via` field's reference target when it is unqualified
      # (e.g. `Vault` instead of `domain.Vault`), or nil. An unqualified
      # target can never resolve a source doctype.
      private def self.unqualified_via_target(via_field : Doctype::FieldDefinition?) : String?
        return nil unless via_field.try(&.reference?)
        target = via_field.try(&.qualified_doctype)
        return nil if target.nil?
        parse_qualified_doctype(target).first.nil? ? target : nil
      end

      private def self.invalid_source_doctype_error(field_name : String, target : String) : String
        "Replicate field '#{field_name}': invalid source doctype '#{target}'"
      end

      # Parses a qualified doctype string into {domain, doctype}.
      # e.g. "identity.Person" → {"identity", "Person"}
      private def self.parse_qualified_doctype(qualified : String) : {String?, String?}
        parts = qualified.split('.', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          {nil, parts[0]?}
        end
      end

      # Checks if two field types are compatible for replication.
      private def self.types_match?(a : Doctype::FieldType, b : Doctype::FieldType) : Bool
        a.type_name == b.type_name
      end

      # Fetches a doctype definition from the projections table.
      private def self.fetch_doctype_definition(
        db : DB::Connection,
        domain : String,
        doctype : String,
      ) : Doctype::DoctypeDefinition?
        doctype_id = "#{domain}.#{doctype}"
        Doctype::DefinitionStore.fetch(db, doctype_id)
      end

      # ── Draft isolation helpers ────────────────────────────────────

      # Reads the `draft` flag from a domain's `core.Domain` projection.
      # Fail-closed: a missing row or a non-`true` value returns `false`.
      # Public so the registry's runtime filter and the validator's
      # authoring-time check share a single definition of "is this domain a draft".
      def self.draft_domain?(db : DB::Connection, domain : String) : Bool
        row = db.query_one?(
          <<-SQL,
            SELECT content->>'draft' FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
              AND deleted_at IS NULL
          SQL
          domain,
        ) do |rs|
          rs.read(String?)
        end

        row == "true"
      end
    end
  end
end
