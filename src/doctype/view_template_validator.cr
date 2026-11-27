# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "./definition_store"

module Facet
  module Doctype
    # Structural + schema-aware validator for `core.DocumentView` template
    # trees.
    #
    # A view template is a free-form JSON object stored on the
    # `core.DocumentView` `template` field, interpreted entirely by the
    # frontend (see `doc/frontend/workflow.md` → Document View Template).
    # The backend does not enforce a schema at the document layer, so a
    # malformed tree would reach the browser and either render nothing
    # (unknown node type, missing container `children`) or crash the
    # whole form page (an `input-*` node without its `field` binding —
    # every input component reads `template.field` during derived
    # initialisation).
    #
    # This validator walks the tree and reports those failure classes
    # plus shape problems, so they are caught at authoring time:
    #
    # - `:error`   — the frontend cannot render the node or the form
    #                cannot save: missing required property, wrong shape,
    #                an `input` / `input-*` binding that cannot resolve
    #                (dotted path, unknown field) or targets a
    #                container/computed field. Assistant write tools
    #                reject the mutation on any `:error`.
    # - `:warning` — the node renders but degrades (unknown node type,
    #                empty `options`, unusable `relation.source`,
    #                unresolved wrapper `field`, input/field-type
    #                affinity mismatch, an interpolation or relation
    #                column that names no field).
    #
    # When a `DoctypeDefinition` is passed, the walk additionally tracks
    # the *resolution scope* — the set of fields an input at this point
    # of the tree can bind. The root scope is the doctype's fields; an
    # `object` node shifts it to the bound field's properties, an `array`
    # node to the array item properties. Without a definition only the
    # structural checks run (bindings are not checked).
    #
    # With a definition, the walk also resolves the doctype facts a node
    # names: a `children` relation's `rel` against the owning doctype's
    # `children` (or a child's own `member_of`), a `filter` relation's
    # `doctype`, the relation column keys against the row doctype, and the
    # `$field` interpolation tokens of the display nodes against the scope.
    # An unresolvable target is a `:warning` — the renderer degrades on it
    # (empty cell, unknown-relationship placeholder), so the write door
    # stays tolerant. The doctype graph is read through
    # `Doctype::DefinitionStore`; a call that passes no definition never
    # touches it.
    #
    # The property requirements mirror the frontend component registry
    # (`DocumentViewTemplate.svelte`) and the `TemplateNode` union in
    # `frontend/src/lib/template-types.ts`.
    module ViewTemplateValidator
      # A single structural finding. `path` is a dot-separated locator
      # into the template tree (e.g. `template.children.2.field`),
      # following the `ValidationError` field-path convention.
      record Issue, severity : Symbol, path : String, message : String

      # Node type → required property names. A node type absent from the
      # map is unknown to the frontend and is reported as a warning.
      REQUIRED = {
        "tabs"             => ["tabs"],
        "label"            => ["value"],
        "field"            => ["value"],
        "object"           => ["field", "children"],
        "if"               => ["field", "children"],
        "array"            => ["field", "children"],
        "dict"             => ["field", "children"],
        "grid"             => ["layout", "children"],
        "col"              => ["children"],
        "image"            => ["src"],
        "image-artifact"   => ["field"],
        "markdown"         => ["field"],
        "link"             => ["href", "label"],
        "title"            => ["value"],
        "capsule"          => ["value"],
        "hr"               => [] of String,
        "email"            => ["href", "label"],
        "header"           => [] of String,
        "section"          => ["label", "children"],
        "sidebar"          => ["children"],
        "record-meta"      => [] of String,
        "row"              => ["layout", "children"],
        "relation"         => ["label", "doctype", "source"],
        "input"            => ["field"],
        "input-text"       => ["field", "label"],
        "input-datetime"   => ["field", "label"],
        "input-period"     => ["field", "label"],
        "input-dateperiod" => ["field", "label"],
        "input-date"       => ["field", "label"],
        "input-select"     => ["field", "label", "options"],
        "input-toggle"     => ["field", "label"],
        "input-longtext"   => ["field", "label"],
        "input-reference"  => ["field", "label"],
        "input-money"      => ["field", "label"],
        "input-color"      => ["field", "label"],
        "input-file"       => ["field", "label"],
        "input-secret"     => ["field", "label"],
        "input-list"       => ["field", "label"],
      }

      # Field types a scalar `input-*` node cannot edit: containers and
      # computed fields. Binding such a field to a scalar input is an
      # `:error` — the form renders but the payload can never validate
      # (e.g. an `input-text` bound to an `array` field saves a string
      # and the backend rejects it with `invalid_type`).
      private CONTAINER_TYPES = Set{"array", "object", "dictionary", "data"}

      # Field types whose values `input-list` may edit: the list editor
      # is a chip-input for string-like scalars.
      private LIST_ITEM_TYPES = Set{"string", "phone", "url", "color"}

      # Node type → field types it can meaningfully bind. A binding
      # outside the set is a `:warning` (the node renders, but the value
      # may fail validation on save or the wrong control shows).
      private INPUT_AFFINITY = {
        "input-text"       => Set{"string", "url", "phone", "integer", "duration", "enum", "date", "any"},
        "input-longtext"   => Set{"longtext"},
        "input-datetime"   => Set{"datetime"},
        "input-period"     => Set{"period"},
        "input-dateperiod" => Set{"dateperiod"},
        "input-date"       => Set{"date"},
        "input-select"     => Set{"enum"},
        "input-toggle"     => Set{"boolean"},
        "input-reference"  => Set{"reference"},
        "input-money"      => Set{"money"},
        "input-color"      => Set{"color"},
        "input-file"       => Set{"file"},
        "input-secret"     => Set{"secret"},
        "input-list"       => Set{"array"},
      }

      # Display nodes that read a document value through `$field`
      # interpolation, mapped to the property names carrying it. An
      # interpolation token that resolves to no field at the current scope
      # renders nothing (the node stays empty), so the gate reports it as a
      # warning.
      private INTERPOLATED_PROPS = {
        "field"          => ["value"],
        "label"          => ["value"],
        "capsule"        => ["value"],
        "title"          => ["value"],
        "markdown"       => ["field"],
        "header"         => ["title", "subtitle"],
        "link"           => ["label"],
        "email"          => ["label"],
        "image-artifact" => ["alt"],
      }

      # URL-bearing display nodes resolve their target by `$field`
      # interpolation. A token that names a `file` field can never produce a
      # working URL — a file field stores a bare artifact id, not a link —
      # so the node renders a dead link or a broken image in both states
      # (unset and set). Files display through a plain `field` row
      # (download capsule); pictures through an `image-artifact` node.
      private URL_PROPS = {
        "link"  => "href",
        "email" => "href",
        "image" => "src",
      }

      # Field type → the input node the frontend provides for it. Used to
      # phrase affinity warnings as actionable suggestions.
      private PREFERRED_NODE = {
        "string"     => "input-text",
        "url"        => "input-text",
        "phone"      => "input-text",
        "integer"    => "input-text",
        "duration"   => "input-text",
        "enum"       => "input-select",
        "date"       => "input-date",
        "datetime"   => "input-datetime",
        "period"     => "input-period",
        "dateperiod" => "input-dateperiod",
        "boolean"    => "input-toggle",
        "longtext"   => "input-longtext",
        "reference"  => "input-reference",
        "money"      => "input-money",
        "color"      => "input-color",
        "file"       => "input-file",
        "secret"     => "input-secret",
        "array"      => "input-list",
      }

      # Validates a template tree (the parsed `template` field of a
      # `core.DocumentView` document). `nil` is valid — the field is
      # optional. Returns one `Issue` per structural problem.
      #
      # When `definition` is given, input `field` bindings are checked
      # against the doctype schema (unknown fields, dotted paths,
      # container/computed bindings) and wrapper nodes are checked for a
      # resolvable target.
      def self.validate(template : JSON::Any?) : Array(Issue)
        validate(template, nil)
      end

      # :ditto:
      def self.validate(template : JSON::Any?, definition : DoctypeDefinition?) : Array(Issue)
        issues = [] of Issue
        return issues if template.nil?
        scope = definition.try(&.fields)
        walk(template, "template", issues, scope, definition.try(&.qualified_name))
        issues
      end

      # `:error` issues only — the mutation-blocking subset.
      def self.errors(issues : Array(Issue)) : Array(Issue)
        issues.select(&.severity.==(:error))
      end

      # ── Field coverage ───────────────────────────────────────────────

      # Top-level doctype field names referenced anywhere in a template —
      # the input of the `Doctype::Check` field-coverage warning. A name
      # comes from a `field` binding (`input` / `input-*` / `object` /
      # `array` / `dict` / `if` / `markdown` / `image-artifact`), a `$field`
      # interpolation on a display node (`field` / `label` / `capsule` /
      # `title` values, `header` title / subtitle, `link` / `email` label,
      # `image-artifact` alt), or a URL interpolation (`link` / `email`
      # `href`, `image` `src`). A dotted path counts for its first segment
      # (`$address.street` covers `address`). Bindings inside an `object` /
      # `array` / `dict` wrapper resolve against the wrapped field's
      # sub-schema, so they never add root names — the wrapper itself
      # already recorded its root field.
      def self.covered_fields(template : JSON::Any?, definition : DoctypeDefinition) : Set(String)
        covered = Set(String).new
        return covered if template.nil?
        collect_fields(template, definition.fields, nil, covered)
        covered
      end

      # The coverage walk mirrors `walk` — same scope derivation, same
      # early returns for missing / unknown node types (children of a node
      # the frontend cannot render never show a value) — but records names
      # instead of issues, so it stays in step with the node vocabulary.
      private def self.collect_fields(
        node : JSON::Any,
        scope : Hash(String, FieldDefinition)?,
        root : String?,
        covered : Set(String),
      ) : Nil
        obj = node.as_h?
        return if obj.nil?
        type = obj["type"]?.try(&.as_s?)
        return if type.nil? || type.empty? || !REQUIRED.has_key?(type)

        record_bindings(obj, type, covered) if root.nil?
        child_scope, child_root = descend_scope(obj, type, scope, root)
        walk_coverage_children(obj, type, child_scope, child_root, covered)
      end

      # Records the root-level field names a node references: the `field`
      # binding (bare keys and dotted wrapper targets; `markdown.field` is
      # a plain key, not an interpolated string), the `$field`
      # interpolations of the display nodes, and the URL interpolations.
      private def self.record_bindings(
        obj : Hash(String, JSON::Any),
        type : String,
        covered : Set(String),
      ) : Nil
        field = obj["field"]?.try(&.as_s?)
        covered << field.split('.').first if field && !field.empty?

        if props = INTERPOLATED_PROPS[type]?
          props.each do |prop|
            next if prop == "field" # bare key, covered above
            value = obj[prop]?.try(&.as_s?)
            next if value.nil? || value.empty?
            interpolation_tokens(value).each { |token| covered << token.split('.').first }
          end
        end

        if url_prop = URL_PROPS[type]?
          value = obj[url_prop]?.try(&.as_s?)
          if value && !value.empty?
            value.scan(/\$(\w+(?:\.\w+)*)/).each { |m| covered << m[1].split('.').first }
          end
        end
      end

      # Returns the scope and the pinned root field name the node's
      # children resolve against. The descent mirrors `walk`: object /
      # array / dict shift the scope and pin the root field they bind;
      # `if` and layout containers keep both.
      private def self.descend_scope(
        obj : Hash(String, JSON::Any),
        type : String,
        scope : Hash(String, FieldDefinition)?,
        root : String?,
      ) : {Hash(String, FieldDefinition)?, String?}
        child_scope = scope.try { |s| derive_scope(obj, type, "template", [] of Issue, s) }
        child_root = root
        if root.nil? && {"object", "array", "dict"}.includes?(type)
          field = obj["field"]?.try(&.as_s?)
          child_root = field && !field.empty? ? field.split('.').first : nil
        end
        {child_scope, child_root}
      end

      # Recurses the children the way `walk` does — `tabs` entries carry
      # their own `children`; every other node reads the `children` prop.
      private def self.walk_coverage_children(
        obj : Hash(String, JSON::Any),
        type : String,
        child_scope : Hash(String, FieldDefinition)?,
        child_root : String?,
        covered : Set(String),
      ) : Nil
        if type == "tabs"
          obj["tabs"]?.try(&.as_a?).try do |tabs|
            tabs.each do |tab|
              tab.as_h?.try do |h|
                h["children"]?.try(&.as_a?).try do |children|
                  children.each { |child| collect_fields(child, child_scope, child_root, covered) }
                end
              end
            end
          end
        else
          obj["children"]?.try(&.as_a?).try do |children|
            children.each { |child| collect_fields(child, child_scope, child_root, covered) }
          end
        end
      end

      # ── Tree walk ───────────────────────────────────────────────────

      private def self.walk(
        node : JSON::Any,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
        owner : String?,
      ) : Nil
        obj = node.as_h?
        if obj.nil?
          issues << Issue.new(:error, path, "template node at '#{path}' is not an object")
          return
        end

        type = missing_type_issue(obj, path, issues)
        return if type.nil?

        required = REQUIRED[type]?
        if required.nil?
          issues << Issue.new(:warning, path, "unknown template node type '#{type}' — the frontend renders nothing for it")
          return
        end

        required.each do |prop|
          check_required_prop(obj, type, prop, path, issues)
        end

        check_array_layout(obj, type, path, issues)
        check_node_bindings(obj, type, path, issues, scope)
        check_url_interpolation(obj, type, path, issues, scope)

        child_scope = scope.nil? ? nil : derive_scope(obj, type, path, issues, scope)

        case type
        when "tabs"
          walk_tabs(obj, path, issues, scope, owner)
        when "if"
          walk_branch(obj, "else", path, issues, child_scope, owner)
        when "input-select"
          walk_options(obj, path, issues)
        when "relation"
          walk_relation(obj, path, issues, scope, owner)
        end

        # Every container type recurses through `children`; node types
        # without the property simply skip.
        walk_branch(obj, "children", path, issues, child_scope, owner) unless type == "tabs"
      end

      # Emits the missing-discriminator error and returns `nil` when `type`
      # is absent or empty; returns the type string otherwise. The error
      # names the keys the node actually carries — a missing discriminator
      # is almost always a truncated or mis-shaped payload, and the key
      # list decides that in one look.
      private def self.missing_type_issue(obj : Hash(String, JSON::Any), path : String, issues : Array(Issue)) : String?
        type = obj["type"]?.try(&.as_s?)
        return type unless type.nil? || type.empty?
        keys = obj.keys
        hint = keys.empty? ? "the node is empty" : "received keys: #{keys.join(", ")}"
        issues << Issue.new(:error, join(path, "type"), "template node at '#{path}' has no 'type' discriminator (#{hint})")
        nil
      end

      # The read-only display layout of an `array` node. Anything but the
      # two known values would silently render the default, so flag the
      # typo as a warning.
      private def self.check_array_layout(obj : Hash(String, JSON::Any), type : String, path : String, issues : Array(Issue)) : Nil
        return unless type == "array"
        layout = obj["layout"]?.try(&.as_s?)
        return if layout.nil? || layout == "inline" || layout == "stack"
        issues << Issue.new(:warning, join(path, "layout"), "array node layout must be 'inline' or 'stack'")
      end

      # Definition-aware checks for a known node type — dispatches between
      # `input` / `input-*` binding validation, wrapper-target validation,
      # and the `$field` interpolation bindings of the display nodes.
      # Runs only when a doctype definition scopes the walk. The bare `input`
      # node goes through the same binding checks as the specialized
      # `input-*` family; its affinity step is a no-op (the auto node has no
      # affinity set — it dispatches by field type).
      private def self.check_node_bindings(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
      ) : Nil
        return if scope.nil?
        input_node = type == "input" || type.starts_with?("input-")
        if input_node
          check_input_binding(obj, type, path, issues, scope)
          return
        end

        if {"object", "array", "dict", "if"}.includes?(type)
          issue_scope_target(obj, type, path, issues, scope)
        end

        if INTERPOLATED_PROPS.has_key?(type)
          check_interpolation_bindings(obj, type, path, issues, scope)
        end
      end

      # ── Binding checks (definition-aware only) ──────────────────────

      # Validates an `input` / `input-*` node's `field` binding against the
      # current scope. Emits:
      # - `:error` for a dotted path (the form write path binds flat keys
      #   only — a dotted binding saves a stray top-level key),
      # - `:error` for an unknown first segment,
      # - `:error` for a scalar input bound to a container/computed field,
      # - `:warning` for a `read_only` binding (the value can never be saved),
      # - `:warning` for an affinity mismatch (control ↔ field type).
      private def self.check_input_binding(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition),
      ) : Nil
        field = obj["field"]?.try(&.as_s?)
        return if field.nil? || field.empty? # already reported by the required-prop check

        if field.includes?('.')
          issues << Issue.new(:error, join(path, "field"),
            "'#{type}' node binds '#{field}' — dotted field paths are not supported on input nodes; " \
            "wrap the top-level field in an 'object' node and use the bare sub-field name")
          return
        end

        bound = scope[field]?
        if bound.nil?
          issues << Issue.new(:error, join(path, "field"),
            "'#{type}' node binds '#{field}' which is not a defined field at this scope")
          return
        end

        bound_type = bound.type.try(&.type_name)
        if bound.read_only?
          issues << Issue.new(:warning, join(path, "field"),
            "'#{type}' node binds '#{field}' which is read_only — the value can never be saved " \
            "(the patch builder strips it and the backend rejects it)")
        end
        return check_input_list_binding(bound, bound_type, field, path, issues) if type == "input-list"
        return issue_container_binding(type, bound_type, field, path, issues) if container_binding?(bound_type)
        issue_affinity_mismatch(type, bound_type, field, path, issues)
      end

      # Interpolation-target check for the display nodes that read a
      # document value through `$field` interpolation (`markdown.field`,
      # the `value` of `field` / `label` / `capsule` / `title`, a `header`
      # title / subtitle, a `link` / `email` label, an `image-artifact`
      # alt). Definition-aware only: a token that resolves to no field at
      # the current scope is a `:warning` — the node renders nothing for it.
      # The resolution is the same `resolve_scope_field` lookup the `input`
      # binding and the URL interpolation checks use, so dotted tokens
      # descend through declared object properties.
      #
      # `markdown.field` is a plain field key, not an interpolated string:
      # its single token is checked as-is (`field`), with no leading `$`.
      private def self.check_interpolation_bindings(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition),
      ) : Nil
        props = INTERPOLATED_PROPS[type]?
        return if props.nil?

        props.each do |prop|
          value = obj[prop]?.try(&.as_s?)
          next if value.nil? || value.empty?
          tokens = type == "markdown" && prop == "field" ? [value] : interpolation_tokens(value)
          tokens.each do |token|
            next unless resolve_scope_field(token, scope).nil?
            issues << Issue.new(:warning, join(path, prop),
              "'#{type}' node references '#{token}' in '#{prop}' which is not a defined field at this scope — the node renders nothing for it")
            break # one warning per property — the fix is the same for every token
          end
        end
      end

      # `$token` references inside a display string (e.g. `$status`,
      # `$contact.name`). A `$$` escape is not a token.
      private def self.interpolation_tokens(value : String) : Array(String)
        value.scan(/(?<!\$)\$(\w+(?:\.\w+)*)/).map(&.[1])
      end

      # Interpolation-target check for the URL-bearing display nodes
      # (`link` / `email` href, `image` src). Definition-aware only: a
      # `$token` resolving to a `file` field is a `:warning` — the
      # artifact id is not a URL, so the rendered link/image can never
      # resolve. Other field types pass: a `url` (or string) target is a
      # legitimate interpolation source.
      private def self.check_url_interpolation(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
      ) : Nil
        return if scope.nil?
        prop = URL_PROPS[type]?
        return if prop.nil?
        value = obj[prop]?.try(&.as_s?)
        return if value.nil? || value.empty?

        tokens = value.scan(/\$(\w+(?:\.\w+)*)/).map(&.[1])
        tokens.each do |token|
          resolved = resolve_scope_field(token, scope)
          next if resolved.nil?
          next unless resolved.type.try(&.type_name) == "file"
          issues << Issue.new(:warning, join(path, prop),
            "'#{type}' node interpolates '#{token}' of type 'file' into '#{prop}' — " \
            "a file field stores an artifact id, not a URL; show files with a plain " \
            "'field' row and pictures with an 'image-artifact' node")
          break # one warning per node — the fix is the same for every file token
        end
      end

      # A scalar input cannot edit a container/computed field — the
      # payload can never validate. `nil` (typeless definition) counts as
      # unusable too.
      private def self.container_binding?(bound_type : String?) : Bool
        bound_type.nil? || CONTAINER_TYPES.includes?(bound_type)
      end

      private def self.issue_container_binding(
        type : String,
        bound_type : String?,
        field : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        issues << Issue.new(:error, join(path, "field"),
          "'#{type}' node cannot bind '#{field}' (#{container_field_hint(bound_type)})")
      end

      # Warns when the input node's control does not match the bound
      # field's declared type. The suggestion points at the auto `input`
      # node first — it renders the preferred control for the field type —
      # and names the specialized node so the override stays discoverable.
      private def self.issue_affinity_mismatch(
        type : String,
        bound_type : String?,
        field : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        affinity = INPUT_AFFINITY[type]?
        return if affinity.nil?
        return if bound_type.nil? || affinity.includes?(bound_type)

        preferred = PREFERRED_NODE[bound_type]?
        message = "'#{type}' node binds '#{field}' of type '#{bound_type}'"
        message += " — use 'input' — it renders '#{preferred}' for this field type" if preferred
        issues << Issue.new(:warning, join(path, "field"), message)
      end

      # `input-list` binding rules: the target must be an array field;
      # the item type must be a string-like scalar the chip editor can
      # round-trip.
      private def self.check_input_list_binding(
        bound : FieldDefinition,
        bound_type : String?,
        field : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        if bound_type != "array"
          issues << Issue.new(:warning, join(path, "field"),
            "'input-list' node binds '#{field}' of type '#{bound_type}' — the list editor expects an array field")
          return
        end

        item_type = bound.items.try(&.type).try(&.type_name)
        return if item_type.nil? # free-form array — accept
        return if LIST_ITEM_TYPES.includes?(item_type)

        issues << Issue.new(:warning, join(path, "field"),
          "'input-list' node edits '#{field}' whose items are '#{item_type}' — the list editor produces strings")
      end

      # Actionable hint appended to the container-binding error.
      private def self.container_field_hint(bound_type : String?) : String
        case bound_type
        when "array"      then "type 'array' — use an 'input-list' node for string arrays, or an 'array' node with child inputs"
        when "object"     then "type 'object' — use an 'object' wrapper node with child inputs for the sub-fields"
        when "dictionary" then "type 'dictionary' — dictionary fields have no input control"
        when "data"       then "type 'data' — computed fields are read-only"
        else                   "no type definition — the field cannot be edited"
        end
      end

      # Checks a scope-shifting or conditional node's `field` target
      # (`object`, `array`, `dict`, `if`). The target must resolve at the
      # current scope; for `object`/`array`/`dict` it must also be a shape
      # the node can iterate. Unresolved targets are `:warning` (the node
      # renders nothing); a wrong iteration shape is `:warning` too. `if`
      # gets no shape check — it tests truthiness/equality on any field
      # type, so a boolean or array target is a legitimate conditional.
      private def self.issue_scope_target(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition),
      ) : Nil
        return unless {"object", "array", "dict", "if"}.includes?(type)

        field = obj["field"]?.try(&.as_s?)
        return if field.nil? || field.empty?

        resolved = resolve_scope_field(field, scope)
        if resolved.nil?
          issues << Issue.new(:warning, join(path, "field"),
            "'#{type}' node targets '#{field}' which is not a defined field at this scope — the node renders nothing")
          return
        end

        issue_shape_target(resolved, type, field, path, issues)
      end

      # Reports a resolvable wrapper target whose shape family does not
      # match what the node can iterate. `if` is exempt — it conditionally
      # renders on any field type (truthiness or equality), so there is no
      # shape it cannot consume.
      private def self.issue_shape_target(
        resolved : FieldDefinition,
        type : String,
        field : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        return if type == "if"
        bound_type = resolved.type.try(&.type_name)
        expected = case type
                   when "array"
                     "array"
                   else
                     # `object` and `dict` both iterate an object/dictionary target.
                     "object"
                   end
        return if bound_type.nil?
        return if expected == "array" ? bound_type == "array" : {"object", "dictionary"}.includes?(bound_type)

        issues << Issue.new(:warning, join(path, "field"),
          "'#{type}' node targets '#{field}' of type '#{bound_type}' — the wrapper adds no usable scope; the node renders nothing")
      end

      # A free-form field type: its value has no declared shape, so the
      # bindings inside its wrapper are unknown, not wrong. An `object` is
      # not free-form — its declared `properties` are the scope.
      private FREE_FORM_SCOPE_TYPES = Set{"any", "dictionary"}

      # Resolution scope for a node's children. `nil` means "bindings
      # inside cannot be validated" — e.g. a free-form object, a
      # dictionary, or a scalar-array item.
      private def self.derive_scope(
        obj : Hash(String, JSON::Any),
        type : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition),
      ) : Hash(String, FieldDefinition)?
        case type
        when "object"
          derive_object_scope(obj, scope)
        when "array"
          derive_array_scope(obj, scope)
        when "dict"
          derive_dict_scope(obj, scope)
        else
          # `if` and layout containers keep the current scope; everything
          # else (display nodes, relation, …) too.
          scope
        end
      end

      # Scope inside an `object` wrapper: the bound field's declared
      # properties. A free-form object (no properties) yields a scope of
      # unknown bindings, not `nil` — its keys are not declared anywhere, so
      # a child binding there is not provably wrong.
      private def self.derive_object_scope(
        obj : Hash(String, JSON::Any),
        scope : Hash(String, FieldDefinition),
      ) : Hash(String, FieldDefinition)?
        field = obj["field"]?.try(&.as_s?)
        return nil if field.nil? || field.empty?
        resolved = resolve_scope_field(field, scope)
        return nil if resolved.nil?
        return unknown_scope if free_form_scope?(resolved.type.try(&.type_name))
        properties_or_nil(resolved.properties)
      end

      # Scope inside an `array` wrapper: the item schema's declared
      # properties. A scalar item is read as the synthetic `value`; a
      # free-form item yields a scope of unknown bindings.
      private def self.derive_array_scope(
        obj : Hash(String, JSON::Any),
        scope : Hash(String, FieldDefinition),
      ) : Hash(String, FieldDefinition)?
        field = obj["field"]?.try(&.as_s?)
        return nil if field.nil? || field.empty?
        resolved = resolve_scope_field(field, scope)
        return nil if resolved.nil?
        items = resolved.items
        return unknown_scope if items.nil?
        props = properties_or_nil(items.properties)
        return props unless props.nil?
        return unknown_scope if free_form_scope?(items.type.try(&.type_name))
        synthetic_scope("value")
      end

      # Scope inside a `dict` wrapper: the frontend renders each entry
      # through a synthetic document whose only keys are `key` and `value`.
      # The wrapper iterates an object or dictionary value — a free-form
      # object (no declared `properties`) included.
      private def self.derive_dict_scope(
        obj : Hash(String, JSON::Any),
        scope : Hash(String, FieldDefinition),
      ) : Hash(String, FieldDefinition)?
        field = obj["field"]?.try(&.as_s?)
        return nil if field.nil? || field.empty?
        resolved = resolve_scope_field(field, scope)
        return nil if resolved.nil?
        type_name = resolved.type.try(&.type_name)
        return nil unless {"object", "dictionary"}.includes?(type_name)
        synthetic_scope("key", "value")
      end

      # A field type whose value shape the definition does not declare.
      private def self.free_form_scope?(type_name : String?) : Bool
        type_name.nil? || FREE_FORM_SCOPE_TYPES.includes?(type_name)
      end

      # A field with no declared type, used for synthetic scope entries.
      private UNTYPED_FIELD = FieldDefinition.new

      # A scope where every name is valid: the value comes from a source the
      # definition does not describe, so a binding cannot be proven wrong.
      private def self.unknown_scope : Hash(String, FieldDefinition)
        Hash(String, FieldDefinition).new(UNTYPED_FIELD)
      end

      # A scope holding only the synthetic entry names the frontend creates
      # (`key` / `value`). They are untyped — only their existence is known.
      private def self.synthetic_scope(*names : String) : Hash(String, FieldDefinition)
        scope = Hash(String, FieldDefinition).new
        names.each { |name| scope[name] = UNTYPED_FIELD }
        scope
      end

      private def self.properties_or_nil(props : Hash(String, FieldDefinition)?) : Hash(String, FieldDefinition)?
        props.nil? || props.empty? ? nil : props
      end

      # Resolves a (possibly dotted) field name against a scope's field
      # definitions. Dotted descent goes through declared object
      # `properties` only — the same data `ObjectType#validate` uses.
      private def self.resolve_scope_field(name : String, scope : Hash(String, FieldDefinition)) : FieldDefinition?
        segments = name.split('.')
        current = scope[segments[0]]?
        segments.skip(1).each do |segment|
          props = current.try(&.properties)
          return nil if props.nil?
          current = props[segment]?
        end
        current
      end

      # ── Structural checks ───────────────────────────────────────────

      private def self.check_required_prop(
        obj : Hash(String, JSON::Any),
        type : String,
        prop : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        value = obj[prop]?
        prop_path = join(path, prop)
        if value.nil?
          issues << Issue.new(:error, prop_path, "'#{type}' node is missing required '#{prop}'")
          return
        end

        # Shape contract per property kind: containers/tabs/options are
        # arrays, `source` is an object (shape checked by `walk_relation`),
        # everything else must be a usable string.
        case prop
        when "children", "tabs", "options"
          if value.as_a?.nil?
            issues << Issue.new(:error, prop_path, "'#{type}' node property '#{prop}' must be an array")
          end
        when "source"
          # Presence only — `walk_relation` validates the shape.
        else
          s = value.as_s?
          if s.nil? || s.empty?
            issues << Issue.new(:error, prop_path, "'#{type}' node property '#{prop}' must be a non-empty string")
          end
        end
      end

      # `tabs` entries are `{type: "tab", label, children}` descriptors.
      private def self.walk_tabs(
        obj : Hash(String, JSON::Any),
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
        owner : String?,
      ) : Nil
        tabs = obj["tabs"]?.try(&.as_a?)
        return if tabs.nil? # missing/non-array already reported by the required check

        tabs.each_with_index do |tab, i|
          tab_path = "#{join(path, "tabs")}.#{i}"
          h = tab.as_h?
          if h.nil?
            issues << Issue.new(:error, tab_path, "tab entry is not an object")
            next
          end
          label = h["label"]?.try(&.as_s?)
          if label.nil? || label.empty?
            issues << Issue.new(:error, "#{tab_path}.label", "tab entry is missing a 'label'")
          end
          walk_branch(h, "children", tab_path, issues, scope, owner)
        end
      end

      # Validates an optional array property and recurses into it.
      private def self.walk_branch(
        obj : Hash(String, JSON::Any),
        prop : String,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
        owner : String?,
      ) : Nil
        branch = obj[prop]?
        return if branch.nil?
        arr = branch.as_a?
        if arr.nil?
          issues << Issue.new(:error, join(path, prop), "property '#{prop}' must be an array when present")
          return
        end
        arr.each_with_index do |child, i|
          walk(child, "#{join(path, prop)}.#{i}", issues, scope, owner)
        end
      end

      private def self.walk_options(obj : Hash(String, JSON::Any), path : String, issues : Array(Issue)) : Nil
        options = obj["options"]?.try(&.as_a?)
        return if options.nil? # missing/non-array already reported

        if options.empty?
          issues << Issue.new(:warning, join(path, "options"), "input-select has an empty 'options' array — the select renders without choices")
          return
        end

        options.each_with_index do |option, i|
          opt_path = "#{join(path, "options")}.#{i}"
          h = option.as_h?
          if h.nil?
            issues << Issue.new(:error, opt_path, "option entry is not an object")
            next
          end
          ["value", "label"].each do |prop|
            s = h[prop]?.try(&.as_s?)
            if s.nil? || s.empty?
              issues << Issue.new(:error, "#{opt_path}.#{prop}", "option entry is missing a '#{prop}' string")
            end
          end
        end
      end

      # `relation.source` selects the query mode: `children` needs `rel`,
      # `filter` needs `field`. Both must be non-empty strings. When a
      # definition scopes the walk, the target is also resolved against the
      # doctype graph (see `validate_relation_source`).
      private def self.walk_relation(
        obj : Hash(String, JSON::Any),
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
        owner : String?,
      ) : Nil
        source = obj["source"]?
        source_path = join(path, "source")
        h = source.try(&.as_h?)
        if h.nil?
          issues << Issue.new(:error, source_path, "'relation' node 'source' must be an object with a 'kind' of 'children' or 'filter'")
          return
        end

        target = validate_relation_source(obj, h, source_path, issues, owner)
        check_relation_view(obj, path, issues)
        check_relation_editable(obj, h["kind"]?.try(&.as_s?) || "", path, issues)
        check_relation_columns(obj, target, path, issues, scope)
      end

      # A relation column must be an object with a non-empty `key`: the
      # frontend keys both render loops on `col.key`, so a string column or
      # a keyless object makes every row key `undefined` and crashes the
      # table. Both shapes are errors. A column-level `editable: true`
      # toggles the row document's own field; dotted keys resolve their leaf
      # on a referenced document — a different mutation target the toggle
      # does not write — so the flag is a no-op there. Warns so the author
      # is not left with a silent no-op. A repeated `key` renders one column
      # (the frontend keeps the first occurrence), so it warns too.
      #
      # When a definition scopes the walk and the row doctype resolves, a
      # column key that names no field on it warns: the cell renders empty.
      private def self.check_relation_columns(
        obj : Hash(String, JSON::Any),
        target : DoctypeDefinition?,
        path : String,
        issues : Array(Issue),
        scope : Hash(String, FieldDefinition)?,
      ) : Nil
        columns = obj["columns"]?.try(&.as_a?)
        return if columns.nil?

        seen_keys = Set(String).new
        columns.each_with_index do |column, i|
          col_path = "#{join(path, "columns")}.#{i}"
          h = column.as_h?
          if h.nil?
            issues << Issue.new(:error, col_path, "column must be an object with 'key'")
            next
          end

          key = h["key"]?.try(&.as_s?) || ""
          if key.empty?
            issues << Issue.new(:error, "#{col_path}.key", "column is missing a non-empty 'key'")
            next
          end

          if seen_keys.includes?(key)
            issues << Issue.new(:warning, "#{col_path}.key",
              "duplicate relation column '#{key}' — the renderer collapses duplicates to the first occurrence")
          else
            seen_keys << key
          end

          check_relation_column_key(key, col_path, issues, target) unless scope.nil?

          next unless h["editable"]?.try(&.as_bool)
          next unless key.includes?('.')
          issues << Issue.new(:warning, "#{col_path}.editable",
            "relation column '#{key}' is dotted — 'editable' applies to the row document's own fields only; the toggle does not render for this column")
        end
      end

      # Warns when a relation column key resolves to no field on the row
      # doctype. A dotted key resolves through the referenced document's
      # declared object properties; the first segment may also name a
      # `reference` field, whose leaf lives on the referenced doctype and is
      # not resolved here.
      private def self.check_relation_column_key(
        key : String,
        col_path : String,
        issues : Array(Issue),
        target : DoctypeDefinition?,
      ) : Nil
        return if target.nil?
        head = target.fields[key.split('.', 2)[0]]?
        return unless head.nil?
        return if key.includes?('.') # dotted leaf on a reference or object target — not resolved here

        issues << Issue.new(:warning, "#{col_path}.key",
          "relation column '#{key}' names no field on '#{target.qualified_name}' — the cell renders empty")
      end

      # Validates the `source.kind` discriminant and its required payload,
      # then resolves the relation target against the doctype graph.
      # Returns the target definition when it resolves, `nil` otherwise.
      #
      # `children` targets the child declared by `source.rel` on the owning
      # doctype, or on any doctype declaring `member_of` back at the owner (a
      # template authored on the child lists its siblings). `filter` targets
      # the relation's own `doctype`. An unresolvable target is a `:warning`:
      # the renderer prints an unknown-relationship placeholder.
      private def self.validate_relation_source(
        obj : Hash(String, JSON::Any),
        h : Hash(String, JSON::Any),
        source_path : String,
        issues : Array(Issue),
        owner : String?,
      ) : DoctypeDefinition?
        case h["kind"]?.try(&.as_s?) || ""
        when "children"
          rel = h["rel"]?.try(&.as_s?)
          if rel.nil? || rel.empty?
            issues << Issue.new(:error, "#{source_path}.rel", "relation source kind 'children' requires a non-empty 'rel'")
            return nil
          end
          resolve_child_relation(rel, source_path, issues, owner)
        when "filter"
          field = h["field"]?.try(&.as_s?)
          if field.nil? || field.empty?
            issues << Issue.new(:error, "#{source_path}.field", "relation source kind 'filter' requires a non-empty 'field'")
            return nil
          end
          resolve_relation_doctype(obj, source_path, issues)
        else
          issues << Issue.new(:error, "#{source_path}.kind", "relation source 'kind' must be 'children' or 'filter'")
          nil
        end
      end

      # The doctype a `children` relation names by `rel`, looked up on the
      # owning doctype's `children` and on the doctypes declaring
      # `member_of` back at it. Emits a `:warning` when nothing matches.
      private def self.resolve_child_relation(
        rel : String,
        source_path : String,
        issues : Array(Issue),
        owner : String?,
      ) : DoctypeDefinition?
        return nil if owner.nil? # structural-only call — the graph is unavailable

        defn = Database.with_connection(:read_only, "*") do |conn|
          Doctype::DefinitionStore.fetch(conn, owner).as(DoctypeDefinition?)
        end
        if defn.nil?
          issues << Issue.new(:warning, "#{source_path}.rel",
            "relation source names the child relationship '#{rel}' — the owning doctype '#{owner}' is not available to resolve it")
          return nil
        end

        if child = defn.children[rel]?
          child_id = "#{defn.domain}.#{child.doctype}"
          return Database.with_connection(:read_only, "*") do |conn|
            Doctype::DefinitionStore.fetch(conn, child_id).as(DoctypeDefinition?)
          end
        end

        found = resolve_member_child(rel, defn)
        if found.nil?
          issues << Issue.new(:warning, "#{source_path}.rel",
            "relation source names no child relationship '#{rel}' on '#{owner}' — the renderer prints an unknown-relationship placeholder")
        end
        found
      end

      # The doctype declaring the `children` entry named `rel` while also
      # declaring `member_of` back at `parent`. A template authored on a child
      # lists its siblings, so the relationship may be declared on a sibling
      # rather than on the owner itself.
      private def self.resolve_member_child(rel : String, parent : DoctypeDefinition) : DoctypeDefinition?
        rows = Database.with_connection(:read_only, "*") do |conn|
          conn.query_all(
            "SELECT content FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL " \
            "AND content->>'domain' = $1 AND content->>'member_of' = $2",
            parent.domain, parent.doctype,
          ) { |rs| rs.read(JSON::Any) }
        end
        rows.each do |raw|
          candidate = Doctype::DoctypeDefinition.from_json(raw)
          return candidate if candidate.children.has_key?(rel)
        rescue JSON::ParseException
          next
        end
        nil
      end

      # The doctype a `filter` relation lists, read from the relation's own
      # `doctype` property. A missing or unregistered target is a warning.
      private def self.resolve_relation_doctype(
        obj : Hash(String, JSON::Any),
        source_path : String,
        issues : Array(Issue),
      ) : DoctypeDefinition?
        target = obj["doctype"]?.try(&.as_s?)
        return nil if target.nil? || target.empty? # already reported by the required-prop check
        resolved = Database.with_connection(:read_only, "*") do |conn|
          Doctype::DefinitionStore.fetch(conn, target).as(DoctypeDefinition?)
        end
        if resolved.nil?
          issues << Issue.new(:warning, "#{source_path}.field",
            "relation source names no registered doctype '#{target}' to list — the relation renders an unknown-target placeholder")
        end
        resolved
      end

      private def self.check_relation_view(obj : Hash(String, JSON::Any), path : String, issues : Array(Issue)) : Nil
        view = obj["view"]?.try(&.as_s?)
        if view && !%w[capsule inline table].includes?(view)
          issues << Issue.new(:warning, join(path, "view"), "relation 'view' must be 'capsule', 'inline', or 'table' — the frontend falls back to capsule")
        end
      end

      # Inline row editing stages child creates against the parent's
      # nested route — only `children` sources support it. A
      # `filter`-bound relation lists rows the parent does not own, so
      # `editable` would stage rows it cannot persist.
      private def self.check_relation_editable(
        obj : Hash(String, JSON::Any),
        kind : String,
        path : String,
        issues : Array(Issue),
      ) : Nil
        if kind == "filter" && obj["editable"]?.try(&.as_bool)
          issues << Issue.new(:error, join(path, "editable"), "relation 'editable: true' requires source kind 'children' — filter-bound relations are read-only (the parent does not own those rows)")
        end
      end

      private def self.join(path : String, segment : String) : String
        path.empty? ? segment : "#{path}.#{segment}"
      end
    end
  end
end
