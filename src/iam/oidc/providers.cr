# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "./provider_store"

module Facet
  module IAM
    module OIDC
      # Provider registry for inbound federated login, backed by
      # `iam.OIDCProvider` documents through `ProviderStore`.
      #
      # The registry is the only place that turns a URL segment (`:provider`
      # in `/auth/oidc/:provider/...`) into a configured provider. When the
      # name is unknown or the provider is disabled, `find` returns nil —
      # the caller cannot distinguish the two cases, which is deliberate:
      # an unknown provider name and a disabled provider deny identically
      # (anti-enumeration).
      #
      # The `client_secret` is never on the record — the token exchange
      # reveals it at use time through `Secrets.reveal` against the
      # provider's document id (`iam.OIDCProvider.{doc_id}`).
      module Providers
        # Returns the enabled provider registered under `name`, or nil when
        # the name is not configured or the provider is disabled.
        def self.find(db : DB::Connection, name : String) : Provider?
          ProviderStore.load(db).find { |provider| provider.name == name }
        end

        # Public listing shape for `GET /Api/iam/oidc/providers` — display
        # names only. The issuer, client id, and client secret never leave
        # the server through this surface.
        def self.summaries(db : DB::Connection) : Array(NamedTuple(name: String, label: String))
          ProviderStore.load(db).map { |provider| {name: provider.name, label: provider.label} }
        end
      end
    end
  end
end
