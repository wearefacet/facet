# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./field_type"
require "./operator"
require "./definition_error"
require "./field_definition"
require "./action_definition"
require "./children_definition"
require "./sidecar_ref"
require "./named_scope"
require "./identifier_definition"
require "./yaml_helper"

module Facet
  module Doctype
    # Full definition of a document type in the Facet system.
    #
    # A doctype describes:
    # - its **identity** (`doctype`, `domain`, `schema_version`)
    # - its **fields** (primitives, children, references)
    # - its **references** (cross‑domain / self‑references)
    # - its **actions** (valid lifecycle transitions)
    # - its **scopes** (named, reusable predicates over its own fields;
    #   referenced from RBAC permissions as `$<name>`)
    # - whether it is an **aggregate root** or a **member** of another
    #
    # ### Validation rules
    #
    # - `doctype` must be CamelCase alphanumeric, cannot start with a digit.
    # - `domain` must be lower_case alphanumeric, cannot start with a digit.
    # - `schema_version` is an integer ≥ 1.
    # - `actions` cannot be named `"validate"`, `"create"`, or `"update"`
    #   (these are reserved).
    struct DoctypeDefinition
      # ── Identity ──────────────────────────────────────────────────────

      # The doctype name, always CamelCase (e.g. `"WorkOrder"`).
      getter doctype : String

      # The domain this doctype belongs to (e.g. `"production"`, `"hr"`).
      getter domain : String

      # Schema version — bumped on breaking changes. Drives lazy migration
      # on read.
      getter schema_version : Int32 = 1

      # Whether this doctype is an aggregate root (owns the transaction
      # boundary, lock target, and RBAC scope). A doctype is exactly one
      # of two things: a root (`aggregate_root: true`) or an owned child
      # (`aggregate_root: false` plus `member_of`).
      getter aggregate_root : Bool = false

      # The parent doctype this doctype is an owned child of
      # (e.g. `"WorkOrder"`). Set only together with
      # `aggregate_root: false`; composition must be mutual — the parent
      # declares a matching `children:` entry (see `Doctype::Composition`).
      getter member_of : String?

      # ── Description ────────────────────────────────────────────────────

      # A human‐readable description of what this doctype represents.
      getter description : String?

      # Optional human display label for this doctype (e.g. "Companies").
      # The name the interface shows; when nil or empty, every surface
      # falls back to the bare `doctype` name. Presentation only — never
      # part of the version gate's data shape. The core.DocType seed
      # schema declares the field, and the definition row's own projection
      # label prefers it over the qualified name.
      getter label : String?

      # Optional icon identifier drawn from the UI's Lucide icon set.
      # When nil (or not a known icon), the frontend falls back to the
      # default diamond mark.
      getter icon : String?

      # Optional human plural label for this doctype (e.g. "contacts",
      # "company memberships"). Used by the app consent preview and the
      # client snippet. When nil, the frontend falls back to a naive
      # pluraliser on the doctype name.
      getter plural_label : String?

      # Optional doctype-level accent color (CSS hex, e.g. `#1565C0`).
      # Presentation metadata the app shell reads; when nil, the frontend
      # falls back to its default doctype color. The core.DocType seed
      # schema declares the field.
      getter color : String?

      # Optional doctype-level sensitivity flag. When true, grants on this
      # doctype are highlighted in the permissions editor and consent
      # preview so the person granting consent sees that access is logged.
      # Defaults to false. Field-level sensitivity is not expressed here;
      # this flag is the coarse doctype-level signal the app wizard reads.
      getter sensitive : Bool = false

      # Optional navigation visibility flag. Meaningful only for child
      # doctypes (`member_of` set): when `true`, the child appears in the
      # sidebar navbar as a top-level entry despite being composition-owned.
      # Defaults to false — children are reached through their parent's
      # relations surface. Aggregate roots are always visible; the flag is
      # ignored for them.
      getter nav_visible : Bool = false

      # ── Identifier ─────────────────────────────────────────────────────

      # Optional sequential identifier configuration. When nil, document IDs
      # are generated as ULIDs.
      getter identifier : IdentifierDefinition?

      # ── Fields ────────────────────────────────────────────────────────

      # The fields of this doctype, keyed by field name.
      getter fields : Hash(String, FieldDefinition) = {} of String => FieldDefinition

      # ── Actions ───────────────────────────────────────────────────────

      # Lifecycle actions that can be applied to documents of this type.
      # Keyed by action name. Each action has a script reference and argument definitions.
      # Action names cannot include `"validate"`, `"create"`, or `"update"`.
      getter actions : Hash(String, ActionDefinition) = {} of String => ActionDefinition

      # ── Children (composition tree) ────────────────────────────────────

      # Child relationships defining the composition tree.
      # Keys are relationship names (e.g. "career_events"), values describe
      # the target doctype and cardinality.
      # Children are stored as **separate projection rows** linked via
      # `parent_id`, enabling cascade delete and nested HTTP routing.
      getter children : Hash(String, ChildrenDefinition) = {} of String => ChildrenDefinition

      # ── Sidecars (cross-domain attachments) ───────────────────────────

      # Whether this doctype is a sidecar: a system-managed attachment
      # doctype (e.g. `core.Comment`) that attaches to host documents
      # through a reference field instead of `parent_id` composition.
      # Sidecar doctypes live in the `core` domain and are created only
      # through the host's nested route.
      getter sidecar : Bool = false

      # Sidecar relationships declared on a host doctype. Keys are segment
      # names used in the nested HTTP route (e.g. "comments"), values
      # describe the qualified sidecar doctype and the reference column on
      # it that points back at this doctype's documents.
      getter sidecars : Hash(String, SidecarRef) = {} of String => SidecarRef

      # Optional custom-surface id on a sidecar doctype (e.g. `"comment"`).
      # Presentation belongs to the type: one declaration serves every host.
      # The frontend resolves the id through its surface registry; an absent
      # or unknown id falls back to the basic DVT surface. Only meaningful
      # with `sidecar: true` (enforced by `Doctype::Validation`).
      getter surface : String?

      # ── Search (compound search corpus) ─────────────────────────────

      # A Jinja2 template rendered at mutation time into the `search` column
      # on the projection (e.g. `"{{ first_name }} {{ last_name }}"`). Used
      # for fast trigram-based substring search (`ILIKE '%term%'`) over the
      # accent-folded corpus. Optional — when nil, the corpus falls back to
      # the document id and the computed display_name.
      getter search : String?

      # ── Display name (template for the projection's `display_name` column) ──

      # A Jinja2 template string whose `{{ field }}` / `{{ path.to.field }}`
      # expressions are resolved against the document content at mutation
      # time and stored on the projection row. Reference fields are
      # auto-resolved to the referenced document's stored `display_name`.
      # Optional — when nil, `display_name` is not computed and the column
      # stays null.
      getter display_name : String?

      # ── Migrations ──────────────────────────────────────────────────────

      # Version-to-function mapping for schema migration.
      # Keys are source version strings (e.g. "1"), values are Lua export
      # function names (e.g. "migrate_from_1").
      # When a document is read at schema_version N and the definition is
      # at schema_version M > N, each migration from N to M-1 runs in order.
      getter migrations : Hash(String, String) = {} of String => String

      # ── Script ─────────────────────────────────────────────────────────

      # Optional Lua script source that defines lifecycle hooks
      # (`create()`, `update()`, `delete()`).
      getter script : String?

      # Named, server-defined predicates over this doctype's own fields.
      # Permissions reference them by `"$<name>"`; the enforcer expands the
      # alias to the `where` map at enforcement time. See `NamedScope`.
      getter scopes : Hash(String, NamedScope) = {} of String => NamedScope

      # Returns `true` if this doctype has a script attached.
      def script? : Bool
        !@script.nil?
      end

      # ── Constants ─────────────────────────────────────────────────────

      # Actions reserved by the system and unavailable for user-defined actions.
      # Single source of truth — referenced by Doctype::Validation as well.
      RESERVED_ACTIONS = {"validate", "create", "update", "delete", "migrate", "snapshot", "history", "rollback"}

      # Top-level keys `from_json` reads. Any other top-level key in the
      # body is rejected at parse time (surfaces as a 422 on create and
      # update) — a silently dropped key would store a definition that no
      # longer matches what the author wrote, while the call still
      # answered success.
      KNOWN_KEYS = %w[
        doctype domain schema_version aggregate_root member_of description
        label icon color plural_label sensitive nav_visible fields actions
        children sidecar sidecars surface search display_name migrations
        script scopes identifier
      ]

      # Keys `parse_identifier` reads inside the `identifier` block.
      IDENTIFIER_KEYS = %w[template genonly]
      DOCTYPE_RE      = /^[A-Z][a-zA-Z0-9]*$/
      # Permissive at the parse level: allows `_`-prefixed draft domain names.
      # Strict enforcement of the live-domain naming convention
      # (`^[a-z][a-z0-9\-]*$`) happens in `Doctype::Validation.validate_domain_name`,
      # which rejects `_`-prefixed names. Draft domains use the relaxed
      # `validate_domain_name_draft` instead. Keeping the parse-level regex
      # permissive avoids blocking struct deserialisation for draft doctypes
      # before the draft-mode branch in `Doctype::Update` can reach them.
      # The character class permits both `_` and `-`, but the strict validators
      # above reject `_` outside the leading draft prefix, so only `-` survives
      # in a live domain name.
      DOMAIN_RE = /^[a-z_][a-z0-9_\-]*$/

      # ── JSON deserialisation ──────────────────────────────────────────

      # Parse from a raw JSON string.
      def self.from_json(string : String) : self
        from_json(JSON.parse(string))
      end

      # Parse from a raw YAML string.
      #
      # NOTE: this entrypoint does NOT expand the YAML `!read_file` directive.
      # `!read_file` resolution requires a file context (to locate the YAML
      # file's own directory, which is the jail root). Callers parsing a
      # fixture file on disk must go through `Facet::Util::YamlInclude.parse_file`
      # (used by `Facet::Domain::Portable::Archive.read_entry_yaml`, the spec
      # fixture helpers, and `load_doctype_schema`).
      Doctype.yaml_entrypoint

      # Parse from a parsed JSON::Any value.
      def self.from_json(raw : JSON::Any) : self
        # The definition must be an object. A JSON-typed body of any other
        # shape (array, scalar, null) answers a 422 naming the got-type —
        # `JSON::Any#[]?` would otherwise raise a bare `RuntimeError` and
        # surface as an HTTP 500.
        raw_h = raw.as_h?
        unless raw_h
          raise DefinitionError.new(
            "doctype definition must be a JSON object (got #{json_kind(raw)})"
          )
        end

        StrictKeys.reject_unknown!(raw_h, KNOWN_KEYS, "doctype definition")

        doctype_val = parse_identity(raw)
        domain_val = parse_domain(raw)
        schema_version = parse_schema_version(raw)
        aggregate_root = optional_bool(raw, "aggregate_root") || false
        member_of_val = parse_member_of(raw)
        description_val = optional_string(raw, "description")
        # An empty-string label is an absent label: the frontend falls back to
        # the doctype name, and the projection templates render the bare name
        # instead of a blank audit label. (Crinja `{% if %}` treats "" as
        # truthy, so the template fallback cannot catch it.)
        label_val = optional_string(raw, "label")
        icon_val = optional_string(raw, "icon")
        color_val = parse_color(raw)
        plural_label_val = optional_string(raw, "plural_label")
        sensitive_val = optional_bool(raw, "sensitive") || false
        nav_visible_val = optional_bool(raw, "nav_visible") || false
        fields_val = parse_fields(raw)
        actions_val = parse_actions(raw)
        children_val = parse_children(raw)
        sidecar_val = optional_bool(raw, "sidecar") || false
        sidecars_val = parse_sidecars(raw)
        surface_val = optional_string(raw, "surface")
        migrations_val = parse_migrations(raw)
        scopes_val = parse_scopes(raw)
        script_val = optional_string(raw, "script")
        search_val = parse_search(raw)
        display_name_val = parse_display_name(raw)
        identifier_val = parse_identifier(raw)

        new(
          doctype: doctype_val,
          domain: domain_val,
          schema_version: schema_version,
          aggregate_root: aggregate_root,
          member_of: member_of_val,
          description: description_val,
          label: label_val,
          icon: icon_val,
          color: color_val,
          plural_label: plural_label_val,
          sensitive: sensitive_val,
          nav_visible: nav_visible_val,
          fields: fields_val,
          actions: actions_val,
          children: children_val,
          sidecar: sidecar_val,
          sidecars: sidecars_val,
          surface: surface_val,
          migrations: migrations_val,
          scopes: scopes_val,
          script: script_val,
          search: search_val,
          display_name: display_name_val,
          identifier: identifier_val,
        )
      end

      private def self.parse_identity(raw : JSON::Any) : String
        doctype_raw = raw["doctype"]?
        if doctype_raw.nil?
          raise DefinitionError.new("Missing required field 'doctype'")
        end
        doctype_val = doctype_raw.as_s?
        unless doctype_val
          raise DefinitionError.new(
            "'doctype' must be a string (CamelCase name, e.g. 'WorkOrder') (got #{json_kind(doctype_raw)})"
          )
        end
        unless doctype_val.matches?(DOCTYPE_RE)
          raise DefinitionError.new(
            "doctype must be CamelCase alphanumeric and cannot start with a digit (got: #{doctype_val})"
          )
        end
        doctype_val
      end

      private def self.parse_domain(raw : JSON::Any) : String
        domain_raw = raw["domain"]?
        if domain_raw.nil?
          raise DefinitionError.new("Missing required field 'domain'")
        end
        domain_val = domain_raw.as_s?
        unless domain_val
          raise DefinitionError.new(
            "'domain' must be a string (lowercase name, e.g. 'production') (got #{json_kind(domain_raw)})"
          )
        end
        unless domain_val.matches?(DOMAIN_RE)
          raise DefinitionError.new(
            "domain must be lowercase alphanumeric with dashes and cannot start with a digit (got: #{domain_val})"
          )
        end
        domain_val
      end

      private def self.parse_schema_version(raw : JSON::Any) : Int32
        version_raw = raw["schema_version"]?
        return 1 if version_raw.nil?

        schema_version = version_raw.as_i?
        unless schema_version
          raise DefinitionError.new(
            "'schema_version' must be an integer >= 1 (got #{json_kind(version_raw)})"
          )
        end
        if schema_version < 1
          raise DefinitionError.new(
            "schema_version must be >= 1 (got: #{schema_version})"
          )
        end
        schema_version
      end

      private def self.parse_member_of(raw : JSON::Any) : String?
        member_of_raw = raw["member_of"]?
        return nil if member_of_raw.nil?

        member_of_val = member_of_raw.as_s?
        unless member_of_val
          raise DefinitionError.new(
            "'member_of' must be a string (CamelCase name) (got #{json_kind(member_of_raw)})"
          )
        end
        unless member_of_val.matches?(DOCTYPE_RE)
          raise DefinitionError.new(
            "member_of must be CamelCase alphanumeric (got: #{member_of_val})"
          )
        end
        member_of_val
      end

      # Names the JSON kind of a raw value for shape-error messages.
      # Delegates to the shared definition-grammar helper so every parser
      # renders the got-type with the same wording.
      private def self.json_kind(value : JSON::Any) : String
        StrictKeys.json_kind(value)
      end

      # Reads an optional string property. The canonical optional-text
      # parser for the definition grammar: absent key → nil, empty string →
      # nil (an empty value is an absent value — the same doctrine as
      # `label`, so no consumer ever has to handle "" beside nil), raises
      # when present but not a string — a wrong-typed value must answer
      # 422, never silently drop (same contract as `parse_search` /
      # `parse_color`).
      private def self.optional_string(raw : JSON::Any, key : String) : String?
        value = raw[key]?
        return nil if value.nil?
        unless text = value.as_s?
          raise DefinitionError.new("'#{key}' must be a string (got #{json_kind(value)})")
        end
        return nil if text.empty?
        text
      end

      # Same contract as `optional_string` for boolean properties. The nil
      # check must be explicit — truthiness (`unless flag = ...`) would also
      # fire on a legitimate `false`, which is falsey in Crystal.
      private def self.optional_bool(raw : JSON::Any, key : String) : Bool?
        value = raw[key]?
        return nil if value.nil?
        flag = value.as_bool?
        if flag.nil?
          raise DefinitionError.new("'#{key}' must be a boolean (got #{json_kind(value)})")
        end
        flag
      end

      # Shared map-parsing shape for `fields`, `children`, `sidecars`, and
      # `scopes`: read the named object from `raw`, parse each entry with the
      # block, and return an empty hash when the key is absent.
      #
      # Both shapes are guarded: a non-object section or a non-object entry
      # raises a `DefinitionError` naming the key and the got-type — the
      # unguarded casts raise `TypeCastError` / `RuntimeError`, which no
      # create/update rescue catches, surfacing as an HTTP 500 (B-12).
      private def self.parse_named_map(raw : JSON::Any, key : String, & : (String, JSON::Any) -> T) : Hash(String, T) forall T
        parsed = {} of String => T
        if section = raw[key]?
          section_h = section.as_h?
          unless section_h
            raise DefinitionError.new(
              "'#{key}' must be an object keyed by name (got #{json_kind(section)})"
            )
          end
          section_h.each do |name, item_raw|
            unless item_raw.as_h?
              raise DefinitionError.new(
                "'#{key}' entry '#{name}' must be an object (got #{json_kind(item_raw)})"
              )
            end
            parsed[name] = yield(name, item_raw)
          end
        end
        parsed
      end

      private def self.parse_fields(raw : JSON::Any) : Hash(String, FieldDefinition)
        parse_named_map(raw, "fields") { |name, field_raw| FieldDefinition.from_json(field_raw, name) }
      end

      private def self.parse_children(raw : JSON::Any) : Hash(String, ChildrenDefinition)
        parse_named_map(raw, "children") { |name, child_raw| ChildrenDefinition.from_json(child_raw, "child '#{name}'") }
      end

      private def self.parse_sidecars(raw : JSON::Any) : Hash(String, SidecarRef)
        parse_named_map(raw, "sidecars") { |name, sidecar_raw| SidecarRef.from_json(sidecar_raw, "sidecar '#{name}'") }
      end

      private def self.parse_actions(raw : JSON::Any) : Hash(String, ActionDefinition)
        actions_val = {} of String => ActionDefinition
        if actions_raw = raw["actions"]?
          actions_h = actions_raw.as_h?
          unless actions_h
            raise DefinitionError.new(
              "'actions' must be an object keyed by action name (got #{json_kind(actions_raw)})"
            )
          end
          actions_h.each do |action_name, action_raw|
            if RESERVED_ACTIONS.includes?(action_name)
              raise DefinitionError.new(
                "Action '#{action_name}' is reserved and cannot be used"
              )
            end
            unless action_raw.as_h?
              raise DefinitionError.new(
                "'actions' entry '#{action_name}' must be an object (got #{json_kind(action_raw)})"
              )
            end
            actions_val[action_name] = ActionDefinition.from_json(action_raw, "action '#{action_name}'")
          end
        end
        actions_val
      end

      private def self.parse_scopes(raw : JSON::Any) : Hash(String, NamedScope)
        parse_named_map(raw, "scopes") { |name, scope_raw| NamedScope.from_json(name, scope_raw) }
      end

      # Parses the `search` template string. Returns nil when absent or
      # empty — an empty template is no template. Raises when the value is
      # present but not a string — a leftover
      # array-form definition must fail loudly, not silently lose search.
      private def self.parse_search(raw : JSON::Any) : String?
        search_raw = raw["search"]?
        return nil if search_raw.nil?

        unless value = search_raw.as_s?
          raise DefinitionError.new("search must be a string (a Jinja2 template, e.g. \"{{ field }}\")")
        end
        value.empty? ? nil : value
      end

      # Parses the optional doctype-level `color`. Returns nil when absent
      # or empty. Raises when the value is present but not a string — a
      # non-string
      # color must fail loudly, not silently lose the value (same contract
      # as `parse_search`).
      private def self.parse_color(raw : JSON::Any) : String?
        color_raw = raw["color"]?
        return nil if color_raw.nil?

        unless value = color_raw.as_s?
          raise DefinitionError.new("color must be a string (CSS hex, e.g. \"#1565C0\")")
        end
        value.empty? ? nil : value
      end

      # Parses the `display_name` template string. Returns nil when absent
      # or empty — an empty template is no template. Raises when the value
      # is present but not a string — a wrong-typed
      # value must fail loudly, not silently drop the template on create
      # or wipe the stored one on update (same contract as `parse_search`).
      private def self.parse_display_name(raw : JSON::Any) : String?
        display_name_raw = raw["display_name"]?
        return nil if display_name_raw.nil?

        unless value = display_name_raw.as_s?
          raise DefinitionError.new("display_name must be a string (a Jinja2 template, e.g. \"{{ field }}\")")
        end
        value.empty? ? nil : value
      end

      # Parses the `identifier` block. Returns nil when absent.
      private def self.parse_identifier(raw : JSON::Any) : IdentifierDefinition?
        id_raw = raw["identifier"]?
        return nil if id_raw.nil?

        id_h = id_raw.as_h?
        unless id_h
          raise DefinitionError.new(
            "'identifier' must be an object with a 'template' (got #{json_kind(id_raw)})"
          )
        end
        StrictKeys.reject_unknown!(id_h, IDENTIFIER_KEYS, "identifier")

        template_raw = id_h["template"]?
        if template_raw.nil?
          raise DefinitionError.new("identifier.template is required and must not be empty")
        end
        template = template_raw.as_s?
        if template.nil? || template.empty?
          raise DefinitionError.new(
            "identifier.template must be a non-empty string (got #{json_kind(template_raw)})"
          )
        end

        genonly = optional_bool(id_raw, "genonly") || false
        IdentifierDefinition.new(template, genonly)
      end

      private def self.parse_migrations(raw : JSON::Any) : Hash(String, String)
        migrations_val = {} of String => String
        if migrations_raw = raw["migrations"]?
          migrations_h = migrations_raw.as_h?
          unless migrations_h
            raise DefinitionError.new(
              "'migrations' must be an object mapping schema version to Lua function name (got #{json_kind(migrations_raw)})"
            )
          end
          migrations_h.each do |version_str, func_name_raw|
            unless func_name = func_name_raw.as_s?
              raise DefinitionError.new(
                "'migrations' entry for version '#{version_str}' must be a string (Lua function name) (got #{json_kind(func_name_raw)})"
              )
            end
            migrations_val[version_str] = func_name
          end
        end
        migrations_val
      end

      def initialize(
        @doctype : String,
        @domain : String,
        @schema_version : Int32 = 1,
        @aggregate_root : Bool = false,
        @member_of : String? = nil,
        @description : String? = nil,
        @label : String? = nil,
        @icon : String? = nil,
        @color : String? = nil,
        @plural_label : String? = nil,
        @sensitive : Bool = false,
        @nav_visible : Bool = false,
        @fields : Hash(String, FieldDefinition) = {} of String => FieldDefinition,
        @actions : Hash(String, ActionDefinition) = {} of String => ActionDefinition,
        @children : Hash(String, ChildrenDefinition) = {} of String => ChildrenDefinition,
        @sidecar : Bool = false,
        @sidecars : Hash(String, SidecarRef) = {} of String => SidecarRef,
        @surface : String? = nil,
        @migrations : Hash(String, String) = {} of String => String,
        @scopes : Hash(String, NamedScope) = {} of String => NamedScope,
        @script : String? = nil,
        @search : String? = nil,
        @display_name : String? = nil,
        @identifier : IdentifierDefinition? = nil,
      )
      end

      # Returns a copy of this definition with `migrations` replaced. Used by
      # `Doctype::Update`, which carries the stored migration map across a
      # same-version edit so the PUT body cannot drop it (B-301).
      def with_migrations(migrations : Hash(String, String)) : self
        DoctypeDefinition.new(
          doctype: doctype,
          domain: domain,
          schema_version: schema_version,
          aggregate_root: aggregate_root,
          member_of: member_of,
          description: description,
          label: label,
          icon: icon,
          color: color,
          plural_label: plural_label,
          sensitive: sensitive,
          nav_visible: nav_visible,
          fields: fields,
          actions: actions,
          children: children,
          sidecar: sidecar,
          sidecars: sidecars,
          surface: surface,
          migrations: migrations,
          scopes: scopes,
          script: script,
          search: search,
          display_name: display_name,
          identifier: identifier,
        )
      end

      # ── Query helpers ──────────────────────────────────────────────────

      # Returns `true` if this doctype is a child (non‑root).
      def child_doctype? : Bool
        !@aggregate_root && !@member_of.nil?
      end

      # Returns the list of field names that are references (from `fields`).
      def reference_field_names : Array(String)
        @fields.select { |_, field| field.reference? }.keys
      end

      # Returns the list of child relationship names (keys from `children`).
      def child_field_names : Array(String)
        @children.keys
      end

      # Returns the list of computed field names.
      def computed_field_names : Array(String)
        @fields.select { |_, field| field.computed? }.keys
      end

      # Returns the list of replicated field names.
      def replicated_field_names : Array(String)
        @fields.select { |_, field| field.replicated? }.keys
      end

      # Returns the fully qualified identifier: `"domain.doctype"`.
      def qualified_name : String
        "#{@domain}.#{@doctype}"
      end

      # ── JSON serialisation ──────────────────────────────────────────────

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field("doctype", @doctype)
          builder.field("domain", @domain)
          builder.field("schema_version", @schema_version)
          builder.field("aggregate_root", @aggregate_root)

          serialize_optional_metadata(builder)

          if @sensitive
            builder.field("sensitive", true)
          end

          serialize_nav_visible(builder)
          serialize_sidecars(builder)
          serialize_surface(builder)

          builder.field("fields") do
            builder.object do
              @fields.each do |name, field|
                builder.field(name, field)
              end
            end
          end

          if s = @search
            builder.field("search", s)
          end

          if dn = @display_name
            builder.field("display_name", dn)
          end

          builder.field("actions") do
            builder.object do
              @actions.each do |name, action|
                builder.field(name, action)
              end
            end
          end

          serialize_collections(builder)

          if s = @script
            builder.field("script", s)
          end

          if id = @identifier
            builder.field("identifier") do
              builder.object do
                builder.field("template", id.template)
                builder.field("genonly", id.genonly?)
              end
            end
          end
        end
      end

      # Emits `member_of`, `description`, `label`, `icon`, `color`, and
      # `plural_label`, each only when set — same wire contract as
      # `sensitive`.
      private def serialize_optional_metadata(builder : JSON::Builder) : Nil
        if m = @member_of
          builder.field("member_of", m)
        end

        if d = @description
          builder.field("description", d)
        end

        if l = @label
          builder.field("label", l)
        end

        if i = @icon
          builder.field("icon", i)
        end

        if c = @color
          builder.field("color", c)
        end

        if p = @plural_label
          builder.field("plural_label", p)
        end
      end

      # Emits the named map collections — `children`, `migrations`, and
      # `scopes` — each only when non-empty, same wire contract as
      # `sidecars`.
      private def serialize_collections(builder : JSON::Builder) : Nil
        unless @children.empty?
          builder.field("children") do
            builder.object do
              @children.each do |name, child|
                builder.field(name, child)
              end
            end
          end
        end

        unless @migrations.empty?
          builder.field("migrations") do
            builder.object do
              @migrations.each do |version_str, func_name|
                builder.field(version_str, func_name)
              end
            end
          end
        end

        unless @scopes.empty?
          builder.field("scopes") do
            builder.object do
              @scopes.each do |name, scope|
                builder.field(name, scope)
              end
            end
          end
        end
      end

      # Emits `nav_visible` only when true — same wire contract as `sensitive`.
      private def serialize_nav_visible(builder : JSON::Builder) : Nil
        if @nav_visible
          builder.field("nav_visible", true)
        end
      end

      # Emits `surface` only when set — same wire contract as `sensitive`.
      private def serialize_surface(builder : JSON::Builder) : Nil
        if sf = @surface
          builder.field("surface", sf)
        end
      end

      # Emits `sidecar` / `sidecars` only when set — same wire contract as
      # `sensitive` / `children`.
      private def serialize_sidecars(builder : JSON::Builder) : Nil
        if @sidecar
          builder.field("sidecar", true)
        end

        unless @sidecars.empty?
          builder.field("sidecars") do
            builder.object do
              @sidecars.each do |segment, ref|
                builder.field(segment, ref)
              end
            end
          end
        end
      end
    end
  end
end
