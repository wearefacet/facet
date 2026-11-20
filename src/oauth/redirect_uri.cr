# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "uri"
require "../util/redirect_uri"

module Facet
  module OAuth
    # Redirect-URI request-time matching for the `app.App` `redirect_uris`
    # field, and the OAuth-facing delegates to the shared shape rule.
    #
    # ## Shared shape rule (`Util::RedirectUri`)
    #
    # One entry is an absolute `https` URI on any host, or an absolute
    # `http` URI on a loopback host (`localhost`, any `*.localhost`
    # subdomain, `127.0.0.1`, `::1`): no fragment, no userinfo, no query,
    # host required. The only permitted wildcard is a `*` port, and only
    # on an `http` loopback host (RFC 8252 §7.3: the OS assigns the local
    # listener's port, so a native client cannot pin it). A `*` anywhere
    # else — scheme, host, path — is rejected.
    #
    # The rule lives in `Util::RedirectUri` as the single source of truth;
    # `valid_shape?` and `https_or_loopback?` below delegate to it, and so
    # do the `util.valid_redirect_uri` Lua binding (the app.App authoring
    # gate) and the RFC 7591 register endpoint. B-154: an `http` entry on a
    # non-loopback host would deliver the authorization code over
    # plaintext, so the scheme is now conditional on the host at both
    # enforcement points.
    #
    # ## Request-time match (`match?`)
    #
    # A presented `redirect_uri` matches when it equals a registered entry
    # exactly, or when a registered entry carries the `*` loopback port and
    # the presented URI has the same scheme (`http`) and host with any port
    # — including the default / absent one. A registered path pins the
    # presented path; a registered entry without a path matches any path.
    # The presented URI never carries a query or fragment (the shared
    # parser rejects both). Matching parses through the shared rule and
    # adds no rejections of its own.
    module RedirectUri
      # True when `uri` is an acceptable `redirect_uris` entry — delegates
      # to the shared rule (`Util::RedirectUri`).
      def self.valid_shape?(uri : String) : Bool
        Util::RedirectUri.valid_shape?(uri)
      end

      # True when the entry targets `https` anywhere, or `http` on a
      # loopback host — the admission rule for a client-supplied redirect
      # URI (RFC 7591 registration). Delegates to the shared rule.
      def self.https_or_loopback?(uri : String) : Bool
        Util::RedirectUri.https_or_loopback?(uri)
      end

      # True when the presented redirect URI matches the registered list —
      # exact string equality on any entry, or the `*` loopback-port rule.
      def self.match?(registered : Array(String), presented : String) : Bool
        return true if registered.includes?(presented)

        presented_parsed = Util::RedirectUri.parse(presented) || return false
        registered.any? do |entry|
          entry_parsed = Util::RedirectUri.parse(entry) || next false
          next false unless entry_parsed.port == "*"
          next false unless entry_parsed.scheme == "http"
          next false unless Util::RedirectUri.loopback_host?(entry_parsed.host)
          next false unless entry_parsed.scheme == presented_parsed.scheme
          next false unless entry_parsed.host == presented_parsed.host

          # A registered path pins the presented path; an absent (or bare
          # root) path matches any.
          entry_path = entry_parsed.path
          entry_path.empty? || entry_path == "/" ? true : entry_path == presented_parsed.path
        end
      end
    end
  end
end
