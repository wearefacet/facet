# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "uri"

module Facet
  module Util
    # The shared OAuth redirect-URI rule: the shape predicate for one
    # `redirect_uris` entry, and the loopback-host predicate behind it.
    #
    # One rule, three consumers:
    #
    # - the `app.App` authoring gate — the `util.valid_redirect_uri` Lua
    #   binding (`Util::ScriptHelpers.valid_redirect_uri?`);
    # - the RFC 7591 register endpoint (`OAuth::Register`);
    # - `OAuth::RedirectUri`, which also owns the request-time `match?`.
    #
    # The rule for one entry (B-154 — the scheme follows the host, so an
    # authorization code is never delivered over plaintext to a remote
    # machine):
    #
    # - `https` on any host, `http` only on a loopback host;
    # - loopback = `localhost`, any `*.localhost` subdomain (RFC 6761 — the
    #   name resolves to the loopback), `127.0.0.1`, `::1`;
    # - no fragment, no userinfo, no query, host required;
    # - the only permitted wildcard is a `*` port, and only on an `http`
    #   loopback host (RFC 8252 §7.3 — the OS assigns the local listener's
    #   port, so a native client cannot pin it). A `*` anywhere else —
    #   scheme, host, path — is rejected.
    #
    # The stdlib `URI.parse` cannot be used here: it rejects the `*`
    # loopback-port form this module accepts.
    module RedirectUri
      # Hosts a loopback redirect may target: the name form and the two IP
      # literals. The `*.localhost` suffix form is accepted in addition —
      # see `loopback_host?`.
      LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "::1"]

      # The RFC 6761 special-use suffix: every `<anything>.localhost` name
      # resolves to the loopback.
      LOOPBACK_SUFFIX = ".localhost"

      # True when `host` names the loopback: the exact entries of
      # `LOOPBACK_HOSTS`, or any `*.localhost` subdomain. `parse`
      # lowercases the host, so the comparison is case-insensitive by
      # construction.
      def self.loopback_host?(host : String) : Bool
        return true if LOOPBACK_HOSTS.includes?(host)
        host.ends_with?(LOOPBACK_SUFFIX) && host.size > LOOPBACK_SUFFIX.size
      end

      # One parsed redirect URI. `port` is the raw port text — digits, `*`,
      # or nil when absent. `host` is lowercased; IPv6 literals arrive
      # without brackets.
      record Parsed, scheme : String, host : String, port : String?, path : String

      # True when `uri` is an acceptable `redirect_uris` entry (see the
      # module doc).
      def self.valid_shape?(uri : String) : Bool
        return false if uri.empty? || uri.matches?(/[[:space:]\x00-\x1f\x7f]/)
        parsed = parse(uri) || return false

        # The scheme follows the host: plaintext http is acceptable only
        # where it stays on one machine — the loopback.
        return false if parsed.scheme == "http" && !loopback_host?(parsed.host)

        port = parsed.port
        if port.nil?
          # Absent port — fine.
        elsif port == "*"
          return false unless parsed.scheme == "http"
        else
          return false unless port.matches?(/\A\d{1,5}\z/) && port.to_i <= 65535
        end

        # The `*` character is permitted only in the port position.
        port == "*" ? uri.count('*') == 1 : !uri.includes?('*')
      end

      # True when the entry targets `https` anywhere, or `http` on a
      # loopback host — the admission rule for a client-supplied redirect
      # URI (RFC 7591 registration). Judges scheme and host only, not the
      # port grammar; pair with `valid_shape?` where the whole rule is
      # needed.
      def self.https_or_loopback?(uri : String) : Bool
        parsed = parse(uri) || return false
        return true if parsed.scheme == "https"
        parsed.scheme == "http" && loopback_host?(parsed.host)
      end

      # Parses an absolute `http(s)` URI into its parts. Public because
      # `OAuth::RedirectUri.match?` reuses the parse for request-time
      # matching. Returns nil when the URI is not acceptable: wrong scheme,
      # missing authority, userinfo, query, or fragment.
      def self.parse(uri : String) : Parsed?
        match = uri.match(/\A(https?):\/\/([^\/?#]*)([^#]*)\z/)
        return nil unless match

        rest = match[3]
        # The remainder after the authority is a path only — a query or a
        # fragment disqualifies the URI.
        return nil unless rest.empty? || rest.starts_with?('/')
        return nil if rest.includes?('?')

        authority = match[2]
        return nil if authority.empty? || authority.includes?('@')

        split = split_authority(authority)
        return nil unless split
        host, port = split
        Parsed.new(match[1], host.downcase, port, rest)
      end

      # Splits `host:port` — IPv6 literals are bracketed, so the port is
      # whatever follows the closing bracket; otherwise the first `:`
      # separates it. An empty port is invalid.
      private def self.split_authority(authority : String) : {String, String?}?
        if authority.starts_with?('[')
          close = authority.index(']')
          return nil unless close
          host = authority[1...close]
          tail = authority[(close + 1)..]
          return nil unless tail.empty? || tail.starts_with?(':')
          port = tail.empty? ? nil : tail[1..]
          return nil if port == ""
          {host, port}
        else
          return nil if authority.includes?('[') || authority.includes?(']')
          head, sep, port = authority.partition(':')
          return nil if !sep.empty? && port.empty?
          {head, sep.empty? ? nil : port}
        end
      end
    end
  end
end
