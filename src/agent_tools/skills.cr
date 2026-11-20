# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../skill_files"

module Facet
  module AgentTools
    # The shared skill corpus, `src/agent_tools/skills/` — short markdown
    # reference documents for the catalogue's tools, served to agent
    # surfaces through each surface's `read_skill` tool.
    #
    # Every file's YAML front-matter carries a required `surfaces`
    # allow-list: the agent surfaces whose `read_skill` serves it
    # (`workspace`, `mcp`). The loader's filter is hard — a surface cannot
    # resolve a skill not tagged for it — which keeps the chat-only
    # etiquette skill unreachable from MCP and keeps this corpus distinct
    # from the domain-builder's draft-scoped corpus
    # (`src/assistant/domain_builder/skills/`, which serves no shared
    # surface).
    #
    # Loading and front-matter parsing live in the shared `SkillFiles`
    # loader; this module pins the directory and the surface vocabulary.
    # The corpus spec (`spec/agent_tools/skills_spec.cr`) fails the suite
    # when a file omits `surfaces` or names an unknown surface.
    module Skills
      # The agent surfaces that serve skill files from this corpus.
      SURFACES = ["workspace", "mcp"]

      # `__DIR__` is `src/agent_tools/`; skills live in the `skills/`
      # subdirectory next to this file.
      DIR = File.join(__DIR__, "skills")

      def self.list_for(surface : String) : Array(SkillFiles::Skill)
        SkillFiles.list_for(DIR, surface)
      end

      def self.read_for(surface : String, name : String) : SkillFiles::Skill?
        SkillFiles.read_for(DIR, surface, name)
      end

      def self.names_for(surface : String) : Array(String)
        list_for(surface).map(&.name)
      end
    end
  end
end
