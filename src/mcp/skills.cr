# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../agent_tools"

module Facet
  module MCP
    # The MCP surface's skill loader (`read_skill`).
    #
    # The workspace assistant advertises its skill corpus in the system
    # prompt; an MCP session has no server-side prompt, and the tool
    # description is the only advertising channel. The `tools/list`
    # definition below is therefore built from the corpus front-matter at
    # request time — its description enumerates the available skills, so
    # discovery costs no extra tool call.
    #
    # The surface filter is hard: only files whose `surfaces` front-matter
    # includes `mcp` resolve here. Chat-only skills and the domain-builder
    # corpus stay unreachable.
    module Skills
      SURFACE = "mcp"

      TOOL_NAME = "read_skill"

      # The corpus skills this surface serves, sorted by name.
      def self.list : Array(SkillFiles::Skill)
        AgentTools::Skills.list_for(SURFACE)
      end

      # The `tools/list` definition, or `nil` when the surface corpus is
      # empty — a surface with no skills advertises no loader. The routes
      # layer appends it after the shared catalogue.
      def self.definition : AgentTools::Definition?
        skills = list
        return nil if skills.empty?

        # The names lead the description so a client that truncates long
        # tool descriptions still forwards the valid values — MCP has no
        # first-class skill concept, so the description is the only place
        # a model learns the corpus. The per-skill descriptions follow for
        # context.
        names = skills.map(&.name)
        described = skills.map { |s| "- #{s.name} — #{s.description}" }.join("\n")
        AgentTools::Definition.new(
          name: TOOL_NAME,
          description: "Read a Facet skill by name. Valid names: #{names.join(", ")}. " \
                       "Skills are short reference documents for the Facet tools; " \
                       "read the relevant one before composing complex filters, " \
                       "aggregates, or relation queries.\n#{described}",
          input_schema: input_schema(names),
        )
      end

      # The `name` property carries an `enum` of the surface's skill names:
      # a machine-readable list that survives client-side truncation of the
      # description, so a model always sees the valid values in the schema.
      private def self.input_schema(names : Array(String)) : JSON::Any
        JSON::Any.new({
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new({
            "name" => JSON::Any.new({
              "type"        => JSON::Any.new("string"),
              "description" => JSON::Any.new("Skill name"),
              "enum"        => JSON::Any.new(names.map { |n| JSON::Any.new(n) }),
            } of String => JSON::Any),
          } of String => JSON::Any),
          "required" => JSON::Any.new([JSON::Any.new("name")]),
        } of String => JSON::Any)
      end

      # Executes `read_skill`. Returns the JSON envelope the routes layer
      # wraps into `content` / `structuredContent` — every tool on this
      # surface answers with an envelope, so the markdown rides as the
      # `body` field instead of the assistants' raw-body convention.
      # Failures raise the shared `AgentTools` taxonomy; the routes'
      # renderer turns them into JSON-RPC errors.
      def self.call(arguments : JSON::Any) : JSON::Any
        name = arguments["name"]?.try(&.as_s?)
        if name.nil? || name.empty?
          raise AgentTools::InvalidParams.new(
            "Missing 'name' argument",
            data: AgentTools.invalid_params_data("name"),
          )
        end

        skill = AgentTools::Skills.read_for(SURFACE, name)
        unless skill
          # Discovery on error: `available` names the skills this surface
          # serves, so a client with a stale cached tools/list can still
          # find the corpus. The list is surface-filtered — it never names
          # a skill this surface does not serve.
          available = AgentTools::Skills.names_for(SURFACE).map { |n| JSON::Any.new(n) }
          raise AgentTools::NotFound.new(
            "Skill '#{name}' not found",
            data: JSON::Any.new({
              "reason"    => JSON::Any.new("not_found"),
              "skill"     => JSON::Any.new(name),
              "available" => JSON::Any.new(available),
            }),
          )
        end

        JSON::Any.new({
          "skill" => JSON::Any.new(skill.name),
          "title" => JSON::Any.new(skill.title),
          "body"  => JSON::Any.new(skill.body),
        } of String => JSON::Any)
      end
    end
  end
end
