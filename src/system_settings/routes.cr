# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../error"
require "../rbac"
require "./service"
require "./mail_test"
require "./assistant_test"

module Facet
  module SystemSettings
    # HTTP surface for the effective system settings.
    #
    # `GET /Api/SystemSettings` — the operator read the settings page uses.
    # Writes go through the standard document update route
    # (`PATCH /Api/core/SystemSettings/settings`), which carries RBAC, the
    # validation split, secret adoption, and the event fanout.
    #
    # `POST /Api/SystemSettings/mail/test` — the settings page's "Send test
    # email" action. One blocking delivery through the saved connector; see
    # `MailTest`.
    #
    # `POST /Api/SystemSettings/assistant/test` — the assistant group's
    # "Send test request" action. One blocking, non-streaming completion
    # through the saved assistant settings; see `AssistantTest`.
    #
    # The GET response carries two members:
    #
    # - `values` — the effective, non-secret values keyed by path. Secret
    #   paths are absent; no credential material ever leaves through this
    #   surface.
    # - `pinned` — the paths the document currently pins (non-null fields,
    #   plus secret paths with a sealed slot). Without it an operator
    #   cannot tell a pinned value from an inherited one.
    #
    # Gated by the standard read enforcer on the doctype. The seed posture
    # is admin-only: the editor and viewer role seeds carve the doctype out
    # of their wildcard read grants, and a denial answers `403`. A missing
    # settings document is tolerated — every key then follows the file.
    module Routes
      def self.register : Nil
        get "/Api/SystemSettings" do |env|
          handle_get(env)
        end

        post "/Api/SystemSettings/mail/test" do |env|
          handle_mail_test(env)
        end

        post "/Api/SystemSettings/assistant/test" do |env|
          handle_assistant_test(env)
        end
      end

      private def self.handle_get(env) : Nil
        auth = Facet::HTTP::Helpers.auth_context(env)

        body : String? = nil
        authorized = Database.with_db(:read_only) do |db|
          unless RBAC::ReadEnforcer.authorized?(db, SystemSettings::DOMAIN, SystemSettings::DOC_TYPE, SystemSettings::DOC_ID, auth)
            next false
          end

          values = Facet::SystemSettings.effective(db)
          pinned = Facet::SystemSettings.pinned(db)
          body = {values: values, pinned: pinned}.to_json
          true
        end

        unless authorized
          Facet::HTTP::Helpers.no_store(env)
          Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
          return
        end

        Facet::HTTP::Helpers.no_store(env)
        Facet::HTTP::Helpers.write_json(env, 200, body)
      end

      # The mail probe. The audience that may edit the settings may test the
      # connector: the update gate on the singleton doctype is the same
      # permission a save needs, so a caller who cannot change the connector
      # cannot make the server open an outbound connection with it either.
      #
      # The response is `200 { adapter, from_address, to }` on success. A
      # `422` means Facet refused before the wire (the connector is 'dev', a
      # malformed address); a `502` carries the transport's own message —
      # the diagnostic the operator pressed the button for.
      #
      # The gate runs before the body is read: a caller who may not change
      # the connector learns nothing about the request shape.
      private def self.handle_mail_test(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        result = Database.with_db do |db|
          unless RBAC::WriteEnforcer.authorize_update(db, DOMAIN, DOC_TYPE, DOC_ID, Facet::HTTP::Helpers.auth_context(env))
            next Facet::ServiceError.new(403, "Forbidden")
          end

          address = parse_test_address(env)
          next address if address.is_a?(Facet::ServiceError)

          MailTest.call(db, address)
        end

        Facet::HTTP::Helpers.no_store(env)

        if result.is_a?(Facet::ServiceError)
          return Facet::HTTP::Helpers.error_response(env, result.status, result.message, result.details)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {
          adapter:      result.adapter,
          from_address: result.from_address,
          to:           result.to,
        })
      end

      # The assistant probe. Same gate story as the mail probe: the
      # audience that may edit the settings may test the connector. No
      # request body — the saved settings are the input.
      #
      # The response is `200 { model, endpoint, reply }` on success. A
      # `422` means Facet refused before the wire (no API key resolves —
      # the unconfigured posture); a `502` carries the transport's own
      # message — the diagnostic the operator pressed the button for.
      private def self.handle_assistant_test(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env)

        result = Database.with_db do |db|
          unless RBAC::WriteEnforcer.authorize_update(db, DOMAIN, DOC_TYPE, DOC_ID, Facet::HTTP::Helpers.auth_context(env))
            next Facet::ServiceError.new(403, "Forbidden")
          end

          AssistantTest.call(db)
        end

        Facet::HTTP::Helpers.no_store(env)

        if result.is_a?(Facet::ServiceError)
          return Facet::HTTP::Helpers.error_response(env, result.status, result.message, result.details)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {
          model:    result.model,
          endpoint: result.endpoint,
          reply:    result.reply,
        })
      end

      # Reads `to` from the JSON body. A missing body or a missing/blank
      # `to` answers `422` — the address shape itself is checked by
      # `MailTest`, which owns the delivery contract. Returns the address or
      # the `ServiceError` to render.
      private def self.parse_test_address(env) : String | Facet::ServiceError
        body = Facet::HTTP::Helpers.require_body(env)
        return Facet::ServiceError.new(422, "Request body is required") if body.nil?

        parsed = begin
          JSON.parse(body)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
        end

        obj = parsed.as_h?
        return Facet::ServiceError.new(422, "Request body must be a JSON object") if obj.nil?

        address = obj["to"]?.try(&.as_s?).try(&.strip)
        return Facet::ServiceError.new(422, "'to' is required") if address.nil? || address.empty?

        address
      end
    end
  end
end
