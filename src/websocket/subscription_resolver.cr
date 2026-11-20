# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../error"
require "../event"
require "../http/nested_path_resolver"
require "../http/helpers"
require "../rbac/read_enforcer"
require "../rbac/auth_context"

module Facet
  module Websocket
    # Resolves a resource path to its fanout channel and authorises the
    # requesting principal via RBAC.
    #
    # ## Path grammar
    #
    #   /domain/Doctype                  → collection subscription
    #   /domain/Doctype/:id              → root document
    #   /domain/Doctype/:id/:rel/:child  → nested child document
    #
    # A two-segment path subscribes to the whole doctype collection channel.
    # The subscribe-time check for a collection is the app-grant + role
    # ceiling (`read` not `Denied`); the per-emit row-level RBAC filter in
    # `Websocket::Manager#dispatch` is the authoritative check. Deeper even
    # segment counts (a trailing relationship name = list-of-children) are
    # rejected. The special path `/notifications` is a self-subscription: it
    # maps to the caller's own per-account fanout channel (see
    # `notifications_channel`) and is handled by `Connection` before
    # document resolution runs.
    #
    # ## Fanout channel format
    #
    #   fanout:{domain}.{doc_type}           (collection)
    #   fanout:{domain}.{doc_type}:{doc_id}  (single document)
    #
    # This matches the format emitted by `Event::Manager#publish_resource_event`.
    class SubscriptionResolver
      # Successful resolution: the fanout channel to subscribe to.
      #
      # For a collection subscription, `doc_id` is nil and the channel has
      # no `:id` suffix. `collection?` tells the caller to enforce the
      # per-doctype subscriber cap at register time.
      struct Resolved
        getter domain : String
        getter doc_type : String
        getter doc_id : String?
        getter? collection : Bool
        getter fanout_channel : String

        def initialize(@domain : String, @doc_type : String, @doc_id : String? = nil, @collection : Bool = false)
          @fanout_channel = if @collection
                              "fanout:#{@domain}.#{@doc_type}"
                            else
                              "fanout:#{@domain}.#{@doc_type}:#{@doc_id}"
                            end
        end
      end

      # Resolve a resource path to its fanout channel and check RBAC read
      # access. Returns `Resolved` on success or `Error` on failure.
      def self.resolve_and_authorize(
        db : DB::Connection,
        path : String,
        auth_context : RBAC::AuthContext,
      ) : Resolved | Facet::ServiceError
        # Split and validate the path
        segments = path.split('/').reject(&.empty?)

        if segments.size < 2
          return Facet::ServiceError.new(400, "Path must include at least a domain and a doctype: #{path}")
        end

        domain = segments[0]

        # Domain gate: reject subscriptions to excluded domains
        unless Facet::Config.instance.domain_enabled?(domain)
          return Facet::ServiceError.new(404, "Not found")
        end
        root_doctype = segments[1]

        # Collection subscription: exactly two segments.
        if segments.size == 2
          authorized = collection_subscribe_authorized?(domain, root_doctype, auth_context)
          unless authorized
            return Facet::ServiceError.new(403, "not found or forbidden")
          end

          return Resolved.new(domain, root_doctype, collection: true)
        end

        # Even number of segments above two = trailing relationship name =
        # collection — list-of-children subscriptions stay unsupported.
        if segments.size.even?
          return Facet::ServiceError.new(400, "Collection subscriptions are not supported: #{path}")
        end

        root_id = segments[2]
        rest_segments = segments[3..]

        # For a root document path (exactly 3 segments), resolve directly
        # without delegating to NestedPathResolver (which requires at least one
        # rest segment for tree walking).
        if rest_segments.empty?
          doc_type = root_doctype
          doc_id = root_id
        else
          # Use NestedPathResolver to walk the composition tree for nested paths
          resolved = HTTP::NestedPathResolver.resolve(db, domain, root_doctype, root_id, rest_segments)

          case resolved
          in HTTP::NestedPathResolver::Resolved
            # Only single-document mode (Get) is supported
            if resolved.mode.list?
              return Facet::ServiceError.new(400, "Collection subscriptions are not supported: #{path}")
            end

            target = resolved.target
            resolved_doc_type = target.doc_type
            resolved_doc_id = target.doc_id

            unless resolved_doc_type && resolved_doc_id
              return Facet::ServiceError.new(500, "Missing doc_type or doc_id in resolution")
            end

            doc_type = resolved_doc_type
            doc_id = resolved_doc_id
          in Facet::ServiceError
            return Facet::ServiceError.new(resolved.status, resolved.message)
          end
        end

        # RBAC read check
        authorized = RBAC::ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)
        unless authorized
          return Facet::ServiceError.new(403, "not found or forbidden")
        end

        Resolved.new(domain, doc_type, doc_id)
      end

      # Subscribe-time gate for a collection subscription: the app grant
      # must permit `read` on the doctype, and the principal's role ceiling
      # must not deny it. This gates who may OPEN the subscription; the
      # per-emit row-level check in `Websocket::Manager#dispatch` is the
      # authoritative filter.
      #
      # Preview principals are rejected: `AuthContext#can?` does not support
      # them, and their capability model has no collection semantics.
      # Non-disclosing: every denial surfaces as the same "not found or
      # forbidden" error the single-document path uses.
      private def self.collection_subscribe_authorized?(
        domain : String,
        doc_type : String,
        auth_context : RBAC::AuthContext,
      ) : Bool
        return false if auth_context.preview?
        return false unless auth_context.app_grant_permits?("read", domain, [doc_type])

        !auth_context.can?("read", domain, [doc_type]).is_a?(RBAC::CanResult::Denied)
      end

      # Resolve a path to a fanout channel string (no DB or RBAC — used for
      # unsubscribe where the channel is already held). Returns `nil` if the
      # path is invalid.
      def self.resolve_channel(path : String) : String?
        segments = path.split('/').reject(&.empty?)
        return nil if segments.size < 2
        return "fanout:#{segments[0]}.#{segments[1]}" if segments.size == 2
        return nil if segments.size.even? # collections not supported

        domain = segments[0]
        doc_type = segments[1]
        doc_id = segments[2]
        "fanout:#{domain}.#{doc_type}:#{doc_id}"
      end

      # ── Notifications self-subscription ─────────────────────────────

      # True when the path is the notifications self-subscription. The
      # path never names an account — the channel comes from the caller's
      # own principal, so a client can only ever reach its own channel.
      def self.notifications_path?(path : String) : Bool
        path.split('/').reject(&.empty?) == ["notifications"]
      end

      # True when the caller may hold the notifications self-subscription.
      # App-scoped principals are rejected: the channel is the account's
      # private notification feed, which sits outside the app grant — once
      # app origins can reach `/Ws` at all, that feed would stream across
      # origins with no RBAC on the path. Service and system principals are
      # unaffected (they carry no app grant).
      def self.notifications_authorized?(auth_context : RBAC::AuthContext) : Bool
        auth_context.app_grant.nil?
      end

      # The caller's own notifications fanout channel. No RBAC check is
      # needed: the channel is derived from the authenticated principal,
      # not from the request.
      def self.notifications_channel(auth_context : RBAC::AuthContext) : String
        Event.notifications_fanout_channel(auth_context.principal.account_id)
      end
    end
  end
end
