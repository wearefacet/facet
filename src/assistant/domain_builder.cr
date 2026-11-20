# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./domain_builder/context"
require "./domain_builder/auth"
require "./domain_builder/system_prompt"
require "./domain_builder/skills"
require "./domain_builder/tools"
require "./domain_builder/routes"

module Facet
  module Assistant
    # The domain-builder assistant surface — a schema architect that runs
    # inside a draft domain and interacts via tool callbacks to create,
    # update, and validate doctype definitions, document view templates,
    # and sample documents.
    #
    # Conversation creation is gated by `write core.DocType` on the
    # originating user's real `AuthContext`. The assistant itself runs as
    # a system-tier principal (`system:assistant`) and bypasses RBAC;
    # draft-domain scoping is enforced inside each tool callback.
    #
    # See `doc/backend/assistant.md` (domain-builder section) for the full
    # design.
    module DomainBuilder
    end
  end
end
