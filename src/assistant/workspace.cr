# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./workspace/context"
require "./workspace/system_prompt"
require "./workspace/skills"
require "./workspace/registrar"
require "./workspace/routes"

module Facet
  module Assistant
    # The workspace assistant surface — the main-application assistant. It
    # talks about live documents with the caller's own `RBAC::AuthContext`
    # (every tool call runs through `ReadEnforcer` / `WriteEnforcer`
    # exactly like a REST call by that account) and adds frontend-rendered
    # UI tools on top of the shared `AgentTools` catalogue.
    #
    # Conversation creation is gated by the role-level `assistant_access`
    # flag via `Assistant::Access`, and re-checked on every stream.
    #
    # ## Files
    #
    # - `workspace/context.cr` — typed, forging-proof conversation context.
    # - `workspace/system_prompt.cr` + `system_prompt.md` — prompt builder.
    # - `workspace/skills.cr` + `skills/*.md` — on-demand reference corpus.
    # - `workspace/registrar.cr` — wires the agent's tools per kind.
    # - `workspace/routes.cr` — the conversation-creation route.
    module Workspace
    end
  end
end
