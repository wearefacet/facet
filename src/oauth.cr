# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./oauth/code_store"
require "./oauth/client_info"
require "./oauth/register"
require "./oauth/dpop"
require "./oauth/replay_cache"
require "./oauth/redirect_uri"
require "./oauth/authorize"
require "./oauth/token"
require "./oauth/refresh"
require "./oauth/rate_limiter"
require "./oauth/discovery"
require "./oauth/cors"
require "./oauth/origin_cache"
require "./oauth/routes"

module Facet
  # Namespace for the Facet App authorization flow.
  #
  # Implements OAuth 2.0 Authorization Code with PKCE — scoped to Facet
  # `app.App` registrations only. The endpoints live under `/OAuth/...`
  # (an uppercase first segment — application route, not a domain id), and
  # this is *not* a general-purpose OAuth server:
  # it issues tokens for internal, Facet-registered applications.
  #
  # Apps are internal to the organization that runs Facet (bespoke frontends,
  # sometimes agent-generated). They are not adversarial. The grant on the
  # `app.App` document is the ceiling; the elected role is the floor; the
  # effective permission at request time is `grant ∩ role`, computed by
  # `RBAC::GrantResolver` and enforced via `RBAC::AuthContext#app_grant`.
  #
  # `grant_type=refresh_token` reuses the shared `IAM::RedisSession`
  # machinery for token rotation + reuse detection; per-app session
  # revocation surfaces on the next refresh, and the token endpoint is rate
  # limited.
  module OAuth
    Log = ::Log.for("facet.oauth")
  end
end
