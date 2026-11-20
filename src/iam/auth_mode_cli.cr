# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../database"
require "../document/update"
require "../rbac"
require "./policy"

module Facet
  module IAM
    # CLI runner for the authentication-mode recovery command
    # (`facet auth:mode {hybrid|oidc_only}`).
    #
    # Patches the `core.SystemSettings` document with the system
    # principal, so the mode is pinned at the document tier — the same
    # save path the settings UI uses, write gate included. This is the
    # documented full-OIDC lockout recovery: when the only enabled IdP is
    # dead and no session survives, the operator restores `hybrid` from
    # the host.
    #
    # The write gate's save-time query keeps this honest in both
    # directions: switching to `oidc_only` still requires one enabled
    # provider document, and switching back to `hybrid` is always
    # allowed. A settings document that does not exist yet (the seed has
    # not run) fails with the standard unknown-doctype `404` surface.
    #
    # Event publication is `CLI.dispatch`'s job: the update enqueues the
    # settings fanout and dispatch flushes the publisher after the
    # command returns, so running servers drop their cached policy at
    # once. The security gates themselves never trust that fanout —
    # `IAM::Policy` reads the document row directly (uncached).
    module AuthModeCLI
      # Applies the mode and prints the outcome. Returns the process exit
      # code.
      def self.run(args : Array(String)) : Int32
        if args.size != 1 || !(args[0] == "hybrid" || args[0] == "oidc_only")
          puts "Error: auth:mode accepts exactly one value: 'hybrid' or 'oidc_only'."
          puts "Usage: facet auth:mode {hybrid|oidc_only}"
          return 1
        end
        mode = args[0]

        Facet::Database.init
        result = Facet::Database.with_db(:read_write) do |db|
          Facet::Document::Update.call(
            db, "core", "SystemSettings", "settings",
            %({"iam": {"auth": {"mode": #{mode.to_json}}}}),
            Facet::RBAC::AuthContext.system,
          )
        end
        Facet::Database.close

        case result
        in Facet::Document::Update::Result
          puts "Authentication mode set to '#{mode}' (pinned on core.SystemSettings)."
          0
        in Facet::ServiceError
          details = result.details.try(&.map { |d| "#{d.field}: #{d.message}" }.join("; "))
          puts "Error (#{result.status}): #{result.message}#{details ? " — #{details}" : ""}"
          1
        end
      end
    end
  end
end
