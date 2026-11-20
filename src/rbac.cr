# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./rbac/error"
require "./rbac/permission"
require "./rbac/scope_value"
require "./rbac/scope_context"
require "./rbac/scope_predicate"
require "./rbac/context_set"
require "./rbac/active_role"
require "./rbac/principal"
require "./rbac/can_result"
require "./rbac/auth_context"
require "./rbac/metadata_gate"
require "./rbac/scope_matcher"
require "./rbac/scope_expander"
require "./rbac/context_resolver"
require "./rbac/account_loader"
require "./rbac/read_enforcer"
require "./rbac/write_enforcer"
require "./rbac/preview_enforcer"
require "./rbac/field_visibility"
require "./rbac/validator"
require "./rbac/role_authority"
require "./rbac/grant"
require "./rbac/app_scope"
require "./rbac/grant_resolver"

module Facet
  # Namespace for the Role-Based Access Control (RBAC) system.
  #
  # All RBAC logic lives under this module. See `doc/rbac.md` for the
  # full design.
  module RBAC
    VERSION = 1
  end
end
