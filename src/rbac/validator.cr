# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../util/identifier"
require "../error"
require "./scope_predicate"
require "./context_set"

module Facet
  module RBAC
    # Authoring-time validator for RBAC permission definitions and named scopes.
    #
    # Called from `Document::Create`/`Document::Update` for `iam.Roles`
    # documents (permission validation) and from `Doctype::Create`/`Update`
    # for `scopes:` blocks (named-scope validation). Every failure is a hard
    # error at authoring time — fail closed and loud.
    #
    # Checks performed:
    #
    # ## `validate_permissions`
    # 1. Action vocabulary — `write` is a grant-side alias only. The role
    #    vocabulary is `read`/`create`/`update`/`delete`/`*`/a named action.
    #    A `write` line matches no operation, so it is refused here.
    # 2. Path locality — all nodes in a permission's `on` share one domain.
    # 3. Wildcard path (`*.*` only — admin role).
    # 4. Scope reference — if `scope` is present and not `$all`, it must name
    #    a `$<named_scope>` alias. The alias must be declared on the leaf
    #    doctype definition's `scopes:` block. Resolves via `DefinitionStore`
    #    (DB-backed).
    #
    # ## `validate_named_scopes`
    # Each `where` entry is parsed into a `ScopePredicate` (the same parser
    # the enforcers use) and validated:
    # 1. Field names in `where` exist on the doctype, or are the reserved
    #    `$parent_id` token. The operator suffix is stripped first.
    # 2. The operator is valid for the field's type — it must appear in the
    #    union of `FilterCapability#operators` over the field's declared
    #    `filters`. `$parent_id` accepts only `Eq`/`Ne` (a string id).
    # 3. Value references: `$self`, `$null`, `$organizational_unit` always
    #    valid; `$<context_set>` must be declared in the domain's
    #    `context_sets`; literals allowed.
    # 4. `$null` combines only with `Eq` — with `Ne` it is meaningless and
    #    with any other operator it has no defined semantics.
    # 5. `$<context_set>` values support only `Eq`, `Ne`, `Match`,
    #    `StartsWith` — comparison operators on comma-joined dependency
    #    values are ill-defined.
    #
    # ## `validate_context_set_definitions`
    # 1. The dependency DAG is acyclic.
    # 2. The `select` field and each `where` key are SQL-safe identifiers
    #    (or the reserved `$parent_id` token). These are interpolated into
    #    `content->>'field'` expressions at resolution time, so a malicious
    #    field name is a SQL injection vector.
    # 3. Each parsed `where` predicate passes the value-grammar checks (3–5
    #    above). Field-existence / operator-vs-field-type checks need the
    #    `from` doctype definition and run when it is fetchable (see
    #    `validate_context_set_definitions_for`).
    module Validator
      # Validates the permissions array from a role's content.
      #
      # `db` is used to fetch the target doctype definitions via
      # `Doctype::DefinitionStore` so that unknown scope aliases fail closed
      # at authoring time. If the target doctype definition is missing
      # (e.g. the role references a doctype that has not been registered
      # yet), the scope reference is rejected — forward references to
      # unregistered doctypes are not allowed.
      def self.validate_permissions(
        permissions_raw : Array(JSON::Any),
        db : DB::Connection,
        errors : Array(ValidationError),
      ) : Nil
        permissions_raw.each_with_index do |perm_raw, idx|
          begin
            perm = Permission.from_json(perm_raw)
          rescue ex : ArgumentError
            errors << ValidationError.new(
              field: nil,
              message: "Permission ##{idx}: #{ex.message}",
              code: "rbac",
            )
            next
          end

          validate_action_vocabulary(perm, idx, errors)
          validate_path_locality(perm, idx, errors)
          validate_scope_reference(perm, db, idx, errors)
        end
      end

      # Grant-side action aliases that the role side never expands. A role
      # line carrying one of these names is accepted by the grammar but
      # matches no operation (`Permission#matches_action?` is exact
      # equality), so every call it should allow is refused with a 403 that
      # looks like a grant bug. Refuse the line at authoring time instead.
      # A named action is legitimate — a doctype declares it — so only the
      # known aliases are refused.
      GRANT_ONLY_ACTIONS = {"write" => "create/update"}

      # Refuses a role permission whose action is a grant-only alias.
      private def self.validate_action_vocabulary(
        perm : Permission,
        idx : Int32,
        errors : Array(ValidationError),
      ) : Nil
        fix = GRANT_ONLY_ACTIONS[perm.action]?
        return unless fix

        errors << ValidationError.new(
          field: nil,
          message: "Permission ##{idx}: '#{perm.action}' is not a role action (reserved set: " \
                   "read, create, update, delete, *, or a named action). '#{perm.action}' is an " \
                   "app-grant alias only — use '#{fix}' on the role line.",
          code: "rbac",
        )
      end

      # Convenience wrapper that returns the errors array (empty on success)
      # so callers can use the standard `return Error.new(...) unless empty?`
      # pattern without boilerplate.
      def self.validate_permissions_for(
        permissions_raw : Array(JSON::Any),
        db : DB::Connection,
      ) : Array(ValidationError)
        errors = [] of ValidationError
        validate_permissions(permissions_raw, db, errors)
        errors
      end

      # Collects the scoped-create lint warnings for a role's permission
      # lines. A line whose action is the literal `create` and whose scope is
      # non-empty is legal — the scope is an intent channel that a Lua create
      # hook (`ctx.actor.scope`) or a Crystal create gate reads — but the
      # RBAC enforcer itself never enforces it (no row exists at create
      # time). Each such line produces one warning, so role authors see the
      # duty the line carries. Advisory only — never a hard error; an error
      # would break the intent-channel lines the seeded roles rely on.
      #
      # Pure — no DB connection. The `$all` sentinel collapses to
      # unrestricted at parse time, so an explicit `$all` never warns.
      # Wildcard actions are ignored. Malformed lines are skipped —
      # `validate_permissions` already reports them as errors.
      def self.scoped_create_warnings(
        permissions_raw : Array(JSON::Any),
        warnings : Array(ValidationError),
      ) : Nil
        permissions_raw.each_with_index do |perm_raw, idx|
          begin
            perm = Permission.from_json(perm_raw)
          rescue ArgumentError
            next
          end

          next unless perm.action == "create"
          next if perm.unrestricted?

          warnings << ValidationError.new(
            field: nil,
            message: "Permission ##{idx} (create #{perm.domain}.#{perm.path.join(".")}): " \
                     "the scope is not enforced by the RBAC enforcer (no row exists at create time). " \
                     "A Lua create hook (ctx.actor.scope) or the operation's create gate must implement it.",
            code: "rbac",
          )
        end
      end

      # Convenience wrapper that returns the warnings array (empty when no
      # permission line carries a scoped create).
      def self.scoped_create_warnings_for(permissions_raw : Array(JSON::Any)) : Array(ValidationError)
        warnings = [] of ValidationError
        scoped_create_warnings(permissions_raw, warnings)
        warnings
      end

      # Validates all context set definitions within a domain.
      #
      # This does NOT need a DB connection — it operates on the parsed
      # context set configuration and the in-memory set map.
      #
      # Checks:
      # 1. The dependency DAG is acyclic.
      # 2. The `select` field and each `where` key are SQL-safe identifiers
      #    (or the reserved `$parent_id` token). These are interpolated into
      #    `content->>'field'` expressions at resolution time, so a malicious
      #    field name is a SQL injection vector.
      def self.validate_context_set_definitions(
        context_sets_raw : JSON::Any?,
        domain_name : String,
        parsed_sets : Hash(String, ContextSet),
        errors : Array(ValidationError),
        from_definitions : Hash(String, Doctype::DoctypeDefinition?)? = nil,
      ) : Nil
        return if context_sets_raw.nil? || context_sets_raw.as_h?.nil?

        # Field-name validation (SQL-injection guard). The reserved
        # `$doc_id` token is accepted alongside `$parent_id`: it projects the
        # row's own `projections.id` column at resolution time.
        parsed_sets.each do |set_name, defn|
          unless valid_context_field?(defn.select_field)
            errors << ValidationError.new(
              field: nil,
              message: "Context set '#{set_name}' in domain '#{domain_name}': select field '#{defn.select_field}' is not a valid SQL-safe identifier (expected lower_case_with_underscores or camelCase, or the reserved '$parent_id'/'$doc_id' token)",
              code: "context_set",
            )
          end
          defn.where.each_key do |field|
            unless valid_context_field?(field)
              errors << ValidationError.new(
                field: nil,
                message: "Context set '#{set_name}' in domain '#{domain_name}': where field '#{field}' is not a valid SQL-safe identifier (expected lower_case_with_underscores or camelCase, or the reserved '$parent_id'/'$doc_id' token)",
                code: "context_set",
              )
            end
          end
        end

        # Predicate validation — same value grammar and operator matrix as
        # named scopes. Field existence and operator-vs-field-type checks
        # run against the `from` doctype definition when available.
        parsed_sets.each do |set_name, defn|
          from_defn = from_definitions.try(&.[defn.from]?)
          validate_where_predicates(
            defn.where, "Context set '#{set_name}' in domain '#{domain_name}'",
            "context_set", from_definition: from_defn, errors: errors,
            domain_context_sets: parsed_sets,
          )
        end

        # Check for cycle in the dependency DAG
        parsed_sets.each_key do |set_name|
          visited = Set(String).new
          check_cycles(set_name, parsed_sets, visited, errors)
        end
      end

      # Convenience wrapper: fetches a domain's content, extracts and parses
      # its context sets, then validates. When the `from` doctype of a set is
      # registered, its definition is passed in so the `where` predicates are
      # also checked against the field's declared operator surface.
      def self.validate_context_set_definitions_for(
        db : DB::Connection,
        domain_name : String,
      ) : Array(ValidationError)
        domain_content = ContextResolver.fetch_domain_content(db, domain_name)
        parsed_sets = ContextResolver.extract_context_sets(domain_content)
        errors = [] of ValidationError

        from_definitions = parsed_sets.each_with_object({} of String => Doctype::DoctypeDefinition?) do |(name, defn), acc|
          acc[defn.from] = Doctype::DefinitionStore.fetch(db, "#{domain_name}.#{defn.from}")
        end

        validate_context_set_definitions(domain_content, domain_name, parsed_sets, errors, from_definitions)
        errors
      end

      # Validates the `scopes:` block declared on a doctype definition.
      #
      # Called from `Doctype::Create`/`Update` after `Doctype::Validation`
      # passes. `domain_context_sets` is the parsed `context_sets` of the
      # domain this doctype belongs to — used to resolve `$<context_set>`
      # references inside a named scope's `where` clause.
      #
      # Each `where` entry is parsed into a `ScopePredicate` (shared with the
      # enforcers) and checked: field exists (or reserved `$parent_id`),
      # operator valid for the field's declared filters, value grammar, and
      # the `$null` / `$<context_set>` operator restrictions. See the module
      # doc comment for the full check list.
      def self.validate_named_scopes(
        definition : Doctype::DoctypeDefinition,
        domain_context_sets : Hash(String, ContextSet),
        errors : Array(ValidationError),
      ) : Nil
        definition.scopes.each do |scope_name, named|
          validate_where_predicates(
            named.where,
            "Named scope '#{scope_name}' on #{definition.qualified_name}",
            "named_scope",
            from_definition: definition,
            errors: errors,
            domain_context_sets: domain_context_sets,
          )
        end
      end

      # Convenience wrapper: fetches the domain's `context_sets`, then calls
      # `validate_named_scopes`. Returns a `ValidationError` array (empty on success)
      # so callers can use the standard `return Error.new(...) unless empty?`
      # pattern without boilerplate.
      def self.validate_named_scopes_for(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
      ) : Array(ValidationError)
        domain_content = ContextResolver.fetch_domain_content(db, definition.domain)
        domain_context_sets = ContextResolver.extract_context_sets(domain_content)
        errors = [] of ValidationError
        validate_named_scopes(definition, domain_context_sets, errors)
        errors
      end

      # Validates the `visible_tags` and `view` tags across a role and its
      # domain's doctypes. Advisory only (warn).
      def self.validate_tags(
        visible_tags : Array(String)?,
        known_tags : Set(String),
        warnings : Array(String),
        context : String = "role",
      ) : Nil
        return if visible_tags.nil?

        visible_tags.each do |tag|
          next if tag == "*" || tag == "default"
          unless known_tags.includes?(tag)
            warnings << "#{context}: unknown tag '#{tag}' (will fail closed if unused)"
          end
        end
      end

      # Builds the set of known tags from a doctype definition's fields.
      def self.known_tags_from_definition(
        definition : Doctype::DoctypeDefinition,
      ) : Set(String)
        tags = Set{"default"}.as(Set(String))
        definition.fields.each_value do |field_def|
          if field_tags = field_def.tags
            field_tags.each { |t| tags << t }
          end
        end
        tags
      end

      # ── Private ────────────────────────────────────────────────────

      # SQL-safety gate for a context set's `select` / `where` field name:
      # a SQL-safe identifier, or one of the reserved tokens. These names
      # are interpolated into SQL expressions at resolution time (see
      # `ScopePredicateSql.field_expr`), so anything outside this set is a
      # SQL-injection vector.
      private def self.valid_context_field?(field : String) : Bool
        return true if field == PARENT_ID_TOKEN || field == DOC_ID_TOKEN
        Util::Identifier.valid_field?(field, allow_parent_token: true)
      end

      # Reserved field-name token on a named scope's `where`. Reads the
      # system-managed parent linkage at `meta->>'parent_id'`.
      PARENT_ID_TOKEN = "$parent_id"

      # Reserved field-name token reading the row's own id
      # (`projections.id`). Accepts the same eq/ne-only restriction as
      # `$parent_id` — the id is a string.
      DOC_ID_TOKEN = "$doc_id"

      # Shared predicate validation for named scopes and context-set `where`
      # clauses. Parses each entry through `ScopePredicateParser` (the same
      # parser the enforcers use — an unknown operator suffix is a hard
      # error) and validates:
      #
      # 1. **Field** — the bare field name (after operator-suffix stripping)
      #    exists on `from_definition`, or is the reserved `$parent_id`
      #    token. Skipped when `from_definition` is nil (context sets whose
      #    `from` doctype is not registered — the SQL-safety check still
      #    applies).
      # 2. **Operator compatibility** — the operator must appear in the
      #    field's derived operator set (the union of its declared
      #    `FilterCapability`s). A field with no declared `filters` accepts
      #    `Eq` only, matching the observable `Document::List` surface where
      #    every known field is equality-filterable. `$parent_id` accepts
      #    only `Eq`/`Ne` (the linkage is a string id).
      # 3. **Value** — literal, `$self`, `$null`, `$organizational_unit`, or
      #    a `$<context_set>` declared in `domain_context_sets`.
      # 4. **`$null`** combines only with `Eq` — with `Ne` it is meaningless
      #    and with any other operator it has no defined semantics.
      # 5. **`$<context_set>`** values support only `Eq`, `Ne`, `Match`,
      #    `StartsWith` — comparison operators on comma-joined dependency
      #    values are ill-defined.
      private def self.validate_where_predicates(
        where : Hash(String, String),
        context : String,
        code : String,
        errors : Array(ValidationError),
        from_definition : Doctype::DoctypeDefinition? = nil,
        domain_context_sets : Hash(String, ContextSet) = {} of String => ContextSet,
      ) : Nil
        where.each do |raw_key, raw_value|
          begin
            bare_field, op_name = Util::FilterSet.parse_filter_key(raw_key)
            operator = Doctype::Operator.parse(op_name)
            value = ScopeValue.parse(raw_value)
          rescue ex : ArgumentError
            errors << ValidationError.new(
              field: nil,
              message: "#{context}: where key '#{raw_key}' is not a valid predicate (#{ex.message})",
              code: code,
            )
            next
          end

          validate_predicate_field(bare_field, operator, context, code, from_definition, errors)
          validate_predicate_value(value, operator, raw_value, context, code, domain_context_sets, errors)
        end
      end

      # Field side of one predicate: the bare name (after operator-suffix
      # stripping) must exist on the doctype, or be a reserved token with an
      # Eq/Ne operator. Skipped when the definition is unavailable.
      private def self.validate_predicate_field(
        bare_field : String,
        operator : Doctype::Operator,
        context : String,
        code : String,
        from_definition : Doctype::DoctypeDefinition?,
        errors : Array(ValidationError),
      ) : Nil
        if bare_field == PARENT_ID_TOKEN || bare_field == DOC_ID_TOKEN
          unless operator.eq? || operator.ne?
            errors << ValidationError.new(
              field: nil,
              message: "#{context}: the reserved field '#{bare_field}' supports only eq/ne (got '#{operator.suffix}')",
              code: code,
            )
          end
          return
        end

        field_def = from_definition.try(&.fields[bare_field]?)
        if from_definition.nil?
          # Definition unavailable (e.g. the `from` doctype is not
          # registered) — the field-existence check cannot run; the
          # SQL-safety check still applies.
          return
        end
        if field_def.nil?
          errors << ValidationError.new(
            field: nil,
            message: "#{context}: where field '#{bare_field}' is not defined on the doctype (allowed: any field on this doctype, or the reserved '$parent_id' token)",
            code: code,
          )
          return
        end

        allowed = field_def.operators
        # A field with no declared `filters` is equality-filterable by
        # `Document::List` — mirror that baseline here.
        allowed = [Doctype::Operator::Eq] if allowed.empty?
        return if allowed.includes?(operator)

        errors << ValidationError.new(
          field: nil,
          message: "#{context}: operator '#{operator.suffix}' on field '#{bare_field}' is not valid for the field's declared filters (allowed: #{allowed.map(&.suffix).join(", ")})",
          code: code,
        )
      end

      # Value side of one predicate: literal, `$self`, `$null`,
      # `$organizational_unit`, or a `$<context_set>` declared in the
      # domain — with the `$null`-only-with-Eq and the
      # context-set-operator-matrix restrictions.
      private def self.validate_predicate_value(
        value : ScopeValue,
        operator : Doctype::Operator,
        raw_value : String,
        context : String,
        code : String,
        domain_context_sets : Hash(String, ContextSet),
        errors : Array(ValidationError),
      ) : Nil
        case value.type
        when ScopeValueType::Literal, ScopeValueType::Self, ScopeValueType::OrganizationalUnit
          nil
        when ScopeValueType::Null
          return if operator.eq?
          errors << ValidationError.new(
            field: nil,
            message: "#{context}: the value '$null' is only valid with eq (got '#{operator.suffix}')",
            code: code,
          )
        when ScopeValueType::ContextSet
          unless operator.eq? || operator.ne? || operator.match? || operator.starts_with?
            errors << ValidationError.new(
              field: nil,
              message: "#{context}: the value '#{raw_value}' (a context-set reference) supports only eq/ne/match/starts_with (got '#{operator.suffix}')",
              code: code,
            )
          end
          ctx_name = value.context_set_name
          return if ctx_name.try { |n| domain_context_sets.has_key?(n) }
          errors << ValidationError.new(
            field: nil,
            message: "#{context}: where value '#{raw_value}' references context set '#{ctx_name}', which is not declared in the domain",
            code: code,
          )
        end
      end

      # Validates that all nodes in a permission's `on` path share one domain.
      # `except` entries carry the same path grammar and are validated at
      # parse time (`Permission.from_json` → `validate_except_entry!`), which
      # `validate_permissions` exercises on every line — a malformed entry
      # surfaces here as a parse error before this method runs.
      private def self.validate_path_locality(
        perm : Permission,
        idx : Int32,
        errors : Array(ValidationError),
      ) : Nil
        # The domain is the first segment of the path.
        # If domain is "*", that's the wildcard — allowed only for admin roles.
        if perm.domain == "*" && perm.path.size == 1 && perm.path[0] == "*"
          return # Wildcard path is valid
        end

        if perm.domain == "*" && perm.path != ["*"]
          errors << ValidationError.new(
            field: nil,
            message: "Permission ##{idx}: wildcard domain '*' can only be used with wildcard path '*' (got: '#{perm.domain}.#{perm.path.join(".")}')",
            code: "rbac",
          )
        end

        # Validate domain format
        unless perm.domain.matches?(/^[a-z][a-z0-9\-]*$/)
          errors << ValidationError.new(
            field: nil,
            message: "Permission ##{idx}: invalid domain '#{perm.domain}' (must be lowercase alphanumeric with dashes)",
            code: "rbac",
          )
        end

        # All path segments must be valid CamelCase doctype names
        perm.path.each do |seg|
          unless seg.matches?(/^[A-Z][a-zA-Z0-9]*$/)
            errors << ValidationError.new(
              field: nil,
              message: "Permission ##{idx}: invalid path segment '#{seg}' (must be CamelCase — for a domain-wide scope use the bare domain, e.g. 'hr')",
              code: "rbac",
            )
          end
        end
      end

      # Validates that a permission's scope references resolve against its
      # target doctype definition.
      private def self.validate_scope_reference(
        perm : Permission,
        db : DB::Connection,
        idx : Int32,
        errors : Array(ValidationError),
      ) : Nil
        # Wildcard permissions (admin) and unrestricted scopes are valid.
        return if perm.unrestricted?
        return if perm.domain == Permission::WILDCARD_DOMAIN

        aliases = perm.scope_aliases
        if aliases.empty?
          # Should not happen after `unrestricted?` returned false, but guard anyway.
          errors << ValidationError.new(
            field: nil,
            message: "Permission ##{idx}: scope is not a valid alias (expected '$<name>' or '$all')",
            code: "rbac",
          )
          return
        end

        doctype_id = "#{perm.domain}.#{perm.path.last}"
        definition = Doctype::DefinitionStore.fetch(db, doctype_id)
        if definition.nil?
          declared_repr = aliases.map { |a| "'$#{a}'" }.join(", ")
          errors << ValidationError.new(
            field: nil,
            message: "Permission ##{idx}: scope #{declared_repr} references doctype '#{doctype_id}', which is not registered",
            code: "rbac",
          )
          return
        end

        aliases.each do |alias_name|
          unless definition.scopes.has_key?(alias_name)
            declared = definition.scopes.keys.empty? ? "(none)" : definition.scopes.keys.join(", ")
            errors << ValidationError.new(
              field: nil,
              message: "Permission ##{idx}: scope '$#{alias_name}' is not declared on doctype '#{doctype_id}' (declared scopes: #{declared})",
              code: "rbac",
            )
          end
        end
      end

      # Checks for cycles in the context set dependency DAG.
      private def self.check_cycles(
        set_name : String,
        parsed_sets : Hash(String, ContextSet),
        visited : Set(String),
        errors : Array(ValidationError),
      ) : Nil
        return unless parsed_sets.has_key?(set_name)

        if visited.includes?(set_name)
          errors << ValidationError.new(
            field: nil,
            message: "Context set dependency cycle detected involving '#{set_name}'",
            code: "context_set",
          )
          return
        end

        visited << set_name
        deps = parsed_sets[set_name]?.try(&.dependencies) || [] of String
        deps.each do |dep_name|
          check_cycles(dep_name, parsed_sets, visited.dup, errors)
        end
      end
    end
  end
end
