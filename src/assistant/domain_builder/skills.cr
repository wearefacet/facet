# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../skill_files"

module Facet
  module Assistant
    module DomainBuilder
      # The domain-builder skill corpus, `src/assistant/domain_builder/skills/`.
      #
      # Loading and front-matter parsing live in the shared
      # `SkillFiles` loader; this module pins the directory and
      # keeps the surface's `Skills` entry point (`list`, `read`, `names`).
      module Skills
        # `__DIR__` is `src/assistant/domain_builder/`; skills live in the
        # `skills/` subdirectory next to this file.
        SKILLS_DIR = File.join(__DIR__, "skills")

        def self.list : Array(SkillFiles::Skill)
          SkillFiles.list(SKILLS_DIR)
        end

        def self.read(name : String) : SkillFiles::Skill?
          SkillFiles.read(SKILLS_DIR, name)
        end

        # Returns the array of skill names — used to populate the
        # `enabled_tools` list at conversation-creation time.
        def self.names : Array(String)
          SkillFiles.names(SKILLS_DIR)
        end
      end
    end
  end
end
