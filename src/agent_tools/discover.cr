# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../doctype/definition_store"
require "../iam/helpers"
require "../agent_tools"
require "./errors"

module Facet
  module AgentTools
    # Discover tool group: schema discovery for an external agent.
    #
    # - `list_domains` — the live (non-draft) domains.
    # - `list_doctypes` — the doctypes of one domain, with descriptions.
    # - `get_schema` — the full definition of one doctype: fields, actions
    #   (with typed args), children, and named scopes. This is the agent's
    #   map of what it can touch; `call_action` discovery flows through the
    #   `actions` map here.
    #
    # Read-only. RBAC: the listing tools are visible to any role with at
    # least one read permission; per-domain row visibility is not filtered
    # here (schema metadata is not user data), but every subsequent
    # `list_documents` / `get_document` call runs through `ReadEnforcer`
    # exactly as on REST.
    module Discover
      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "list_domains",
            description: "List the live domains (bounded contexts) available in Facet. Draft domains are excluded.",
            input_schema: JSON.parse(%({"type": "object", "properties": {}, "required": []})),
            requires: :read,
            handler: ->(ctx : Registry::Context, _args : JSON::Any) { list_domains(ctx) },
          ),
          Registry::Entry.new(
            name: "list_doctypes",
            description: "List the document types of one domain. Pass the domain name from list_domains.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {"domain": {"type": "string"}},
              "required": ["domain"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { list_doctypes(ctx, args) },
          ),
          Registry::Entry.new(
            name: "get_schema",
            description: "Get the full schema of one doctype: fields (types, required, constraints), named actions with their typed arguments, child doctypes, the parent doctype (member_of, on a child), sidecar segments (host-scoped record types attached through the nested routes — e.g. comments or attachments, via create_sidecar/list_sidecars), and named scopes. Read this before creating or updating documents.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":  {"type": "string"},
                "doctype": {"type": "string"}
              },
              "required": ["domain", "doctype"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { get_schema(ctx, args) },
          ),
          Registry::Entry.new(
            name: "whoami",
            description: "Read your own identity and access: the account you act as, the mounted role, its permission manifest (doctype -> actions and scope aliases), and the role's visible tags. Fields whose 'view' tags fall outside visible_tags are omitted from ALL results — a field you do not see is access-controlled, not missing data. Read this before probing permissions by trial and error.",
            input_schema: JSON.parse(%({"type": "object", "properties": {}, "required": []})),
            requires: :none,
            handler: ->(ctx : Registry::Context, _args : JSON::Any) { whoami(ctx) },
          ),
        ]
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.list_domains(ctx : Registry::Context) : JSON::Any
        rows = ctx.db.query_all(
          <<-SQL,
            SELECT id, content->>'description' AS description
            FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND deleted_at IS NULL
              AND (content->>'draft' IS NULL OR content->>'draft' != 'true')
            ORDER BY id ASC
          SQL
          as: {String, String?},
        )
        items = rows.map do |(id, description)|
          h = {"name" => JSON::Any.new(id)}
          h["description"] = JSON::Any.new(description) if description
          JSON::Any.new(h)
        end
        JSON::Any.new({"domains" => JSON::Any.new(items)})
      end

      private def self.list_doctypes(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = string_arg(args, "domain")

        exists = ctx.db.query_one?(
          "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
          domain,
          as: Int32,
        )
        raise NotFound.new("Unknown domain: #{domain}", data: JSON.parse(%({"reason": "not_found"}))) unless exists

        rows = ctx.db.query_all(
          <<-SQL,
            SELECT id, content->>'description' AS description,
                   content->>'member_of' AS member_of
            FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL
              AND content->>'domain' = $1
            ORDER BY id ASC
          SQL
          domain,
          as: {String, String?, String?},
        )
        items = rows.map do |(id, description, member_of)|
          h = {
            "name"   => JSON::Any.new(id),
            "member" => JSON::Any.new(member_of.nil?),
          }
          h["description"] = JSON::Any.new(description) if description
          h["member_of"] = JSON::Any.new(member_of) if member_of
          JSON::Any.new(h)
        end
        JSON::Any.new({"domain" => JSON::Any.new(domain), "doctypes" => JSON::Any.new(items)})
      end

      private def self.get_schema(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = string_arg(args, "domain")
        doctype = string_arg(args, "doctype")
        doctype_id = "#{domain}.#{doctype}"

        definition = Doctype::DefinitionStore.fetch(ctx.db, doctype_id)
        raise NotFound.new("Unknown doctype: #{doctype_id}", data: JSON.parse(%({"reason": "not_found"}))) unless definition

        payload = {
          "doctype"        => JSON::Any.new(definition.doctype),
          "domain"         => JSON::Any.new(definition.domain),
          "schema_version" => JSON::Any.new(definition.schema_version.to_i64),
          "aggregate_root" => JSON::Any.new(definition.aggregate_root),
          "fields"         => fields_json(definition),
          "actions"        => actions_json(definition),
          "children"       => children_json(definition),
          "scopes"         => scopes_json(definition),
        } of String => JSON::Any
        # The child side of the composition link: a doctype with member_of
        # hangs off that parent and lists through parent_id.
        if member_of = definition.member_of
          payload["member_of"] = JSON::Any.new(member_of)
        end
        # The host side of the sidecar link: each segment names a
        # cross-doctype record type attached through the host's nested
        # routes (e.g. comments → create_sidecar / list_sidecars).
        unless definition.sidecars.empty?
          payload["sidecars"] = sidecars_json(definition)
        end
        JSON::Any.new(payload)
      end

      # ── Schema serialization ────────────────────────────────────────────

      private def self.fields_json(definition : Doctype::DoctypeDefinition) : JSON::Any
        h = {} of String => JSON::Any
        definition.fields.each do |name, field|
          h[name] = JSON::Any.new(field_json(field))
        end
        JSON::Any.new(h)
      end

      private def self.field_json(field : Doctype::FieldDefinition) : Hash(String, JSON::Any)
        field_h = {"type" => JSON::Any.new(field.type.try(&.type_name) || "any")} of String => JSON::Any
        field_h["required"] = JSON::Any.new(field.required)
        field_h["collection"] = JSON::Any.new(field.collection)
        field_h["read_only"] = JSON::Any.new(field.read_only?) if field.read_only?
        field_h["write_only"] = JSON::Any.new(field.write_only?) if field.write_only?
        field_h["unique"] = JSON::Any.new(field.unique) if field.unique
        field_h["title"] = JSON::Any.new(field.title) if field.title
        field_h["description"] = JSON::Any.new(field.description) if field.description
        set_optional_field_constraints(field_h, field)
        field_h
      end

      # Emits the optional constraint keys (default/min/max/target/values)
      # shared by the field serializer. Split out to keep both callers under
      # the cyclomatic-complexity threshold.
      private def self.set_optional_field_constraints(field_h : Hash(String, JSON::Any), field : Doctype::FieldDefinition) : Nil
        if d = field.default
          field_h["default"] = d
        end
        if m = field.min
          field_h["min"] = JSON::Any.new(m)
        end
        if m = field.max
          field_h["max"] = JSON::Any.new(m)
        end
        if t = field.qualified_doctype
          field_h["target"] = JSON::Any.new(t)
        end
        if values = field.values
          field_h["values"] = JSON::Any.new(values.map { |v| JSON::Any.new(v.key) })
        end
        if mode = field.mode
          field_h["mode"] = JSON::Any.new(mode)
        end
        if ttl = field.ttl_seconds
          field_h["ttl_seconds"] = JSON::Any.new(ttl)
        end
      end

      private def self.actions_json(definition : Doctype::DoctypeDefinition) : JSON::Any
        h = {} of String => JSON::Any
        definition.actions.each do |name, action|
          args_h = {} of String => JSON::Any
          action.args.each do |arg_name, arg|
            arg_h = {"type" => JSON::Any.new(arg.type.type_name)} of String => JSON::Any
            arg_h["required"] = JSON::Any.new(arg.required) if arg.required
            if d = arg.default
              arg_h["default"] = d
            end
            if values = arg.values
              arg_h["values"] = JSON::Any.new(values.map { |v| JSON::Any.new(v) })
            end
            if m = arg.min
              arg_h["min"] = JSON::Any.new(m)
            end
            if m = arg.max
              arg_h["max"] = JSON::Any.new(m)
            end
            if t = arg.qualified_doctype
              arg_h["target"] = JSON::Any.new(t)
            end
            arg_h["collection"] = JSON::Any.new(arg.collection) if arg.collection
            args_h[arg_name] = JSON::Any.new(arg_h)
          end
          action_h = {"args" => JSON::Any.new(args_h)} of String => JSON::Any
          action_h["event_name"] = JSON::Any.new(action.event_name) if action.event_name
          h[name] = JSON::Any.new(action_h)
        end
        JSON::Any.new(h)
      end

      private def self.children_json(definition : Doctype::DoctypeDefinition) : JSON::Any
        h = {} of String => JSON::Any
        definition.children.each do |rel_name, child|
          h[rel_name] = JSON::Any.new({
            "doctype" => JSON::Any.new(child.doctype),
          })
        end
        JSON::Any.new(h)
      end

      private def self.sidecars_json(definition : Doctype::DoctypeDefinition) : JSON::Any
        h = {} of String => JSON::Any
        definition.sidecars.each do |segment, ref|
          h[segment] = JSON::Any.new({
            "doctype" => JSON::Any.new(ref.doctype),
            "column"  => JSON::Any.new(ref.column),
          } of String => JSON::Any)
        end
        JSON::Any.new(h)
      end

      private def self.scopes_json(definition : Doctype::DoctypeDefinition) : JSON::Any
        h = {} of String => JSON::Any
        definition.scopes.each do |name, scope|
          scope_h = {} of String => JSON::Any
          scope_h["description"] = JSON::Any.new(scope.description) if scope.description
          where_h = {} of String => JSON::Any
          scope.where.each { |k, v| where_h[k] = JSON::Any.new(v) }
          scope_h["where"] = JSON::Any.new(where_h)
          h[name] = JSON::Any.new(scope_h)
        end
        JSON::Any.new(h)
      end

      # ── whoami: the caller's own access manifest ─────────────────────

      # Reports the mounted identity: account, role, the permission manifest
      # (the same data /Api/iam/me serves), and the role's visible tags.
      # An agent reads its grants here instead of inferring them by trial
      # and error. The role content loads through the same qualified-id
      # lookup `find_role_content` serves everywhere — the projection id of
      # a role IS `iam.Roles.<name>` — so the manifest matches every other
      # surface. A missing role projection fails closed with an empty
      # manifest (the listing tools would refuse the call anyway).
      private def self.whoami(ctx : Registry::Context) : JSON::Any
        return JSON::Any.new({} of String => JSON::Any) unless ctx.auth_context.principal.is_a?(RBAC::Principal::Real)
        principal = ctx.auth_context.principal.as(RBAC::Principal::Real)
        active_role = principal.active_role

        account = IAM::Helpers.find_account_by_id(ctx.db, ctx.auth_context.account_id)

        role_content = IAM::Helpers.find_role_content(ctx.db, "iam.Roles.#{active_role.role_id}")
        manifest = role_content ? IAM::Helpers.build_permission_manifest(role_content) : {permissions: nil, scopes: nil}

        payload = {
          "account" => JSON::Any.new({
            "id"           => JSON::Any.new(ctx.auth_context.account_id),
            "display_name" => account ? JSON::Any.new(account[:display_name]) : JSON::Any.new(nil),
          } of String => JSON::Any),
          "role"         => JSON::Any.new(active_role.role_id),
          "visible_tags" => JSON::Any.new(active_role.visible_tags.to_a.sort.map { |t| JSON::Any.new(t) }),
        } of String => JSON::Any
        if perms = manifest[:permissions]
          perms_h = {} of String => JSON::Any
          perms.each do |dt, actions|
            perms_h[dt] = JSON::Any.new(actions.map { |a| JSON::Any.new(a) })
          end
          payload["permissions"] = JSON::Any.new(perms_h)
        end
        if scopes = manifest[:scopes]
          scopes_h = {} of String => JSON::Any
          scopes.each do |dt, by_action|
            by_action_h = {} of String => JSON::Any
            by_action.each do |action, aliases|
              by_action_h[action] = JSON::Any.new(aliases.map { |a| JSON::Any.new(a) })
            end
            scopes_h[dt] = JSON::Any.new(by_action_h)
          end
          payload["scopes"] = JSON::Any.new(scopes_h)
        end
        JSON::Any.new(payload)
      end

      # ── Shared arg helpers ──────────────────────────────────────────────

      # Extracts a required string argument, raising `InvalidParams` with a
      # message that names the offending argument.
      def self.string_arg(args : JSON::Any, key : String) : String
        value = args.as_h?.try(&.[key]?)
        str = value.try(&.as_s?)
        if str.nil? || str.empty?
          raise InvalidParams.new("Missing or invalid argument '#{key}' (expected a non-empty string)",
            data: AgentTools.invalid_params_data(key))
        end
        str
      end

      # Extracts a required argument that must be a JSON object. Names the
      # offending argument when missing. Shared by the write tools
      # (`create_document` content / `update_document` patch) and
      # `create_sidecar`.
      def self.object_arg(args : JSON::Any, key : String) : JSON::Any
        value = args.as_h?.try(&.[key]?)
        unless value && value.as_h?
          raise InvalidParams.new("Missing or invalid argument '#{key}' (expected an object)",
            data: AgentTools.invalid_params_data(key))
        end
        value
      end
    end
  end
end
