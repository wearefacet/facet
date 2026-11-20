# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../agent_tools/skills"

module Facet
  module Assistant
    module Workspace
      # The workspace surface's skill entry point (`list`, `read`, `names`).
      #
      # The corpus lives with the shared catalogue,
      # `src/agent_tools/skills/`; each file's `surfaces` front-matter
      # decides which agent surface serves it. This module filters the
      # corpus to the workspace surface, so the chat-only skills resolve
      # here and the MCP-only visibility rules stay out of the chat.
      module Skills
        SURFACE = "workspace"

        def self.list : Array(SkillFiles::Skill)
          AgentTools::Skills.list_for(SURFACE)
        end

        def self.read(name : String) : SkillFiles::Skill?
          AgentTools::Skills.read_for(SURFACE, name)
        end

        def self.names : Array(String)
          AgentTools::Skills.names_for(SURFACE)
        end
      end
    end
  end
end
