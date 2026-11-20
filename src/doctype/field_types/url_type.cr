# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "uri"

module Facet
  module Doctype
    # Field type for a URL value.
    #
    # Stored as a string. Validation requires an absolute `http` or `https`
    # URL with a host — relative paths and non-web schemes are rejected. The
    # host must be a DNS-style name (letters, digits, dots, hyphens,
    # underscores) or a bracketed IPv6 literal: `URI.parse` alone accepts
    # spaces and stray punctuation inside the authority, which would store
    # values no client can dereference (B-174). The frontend renders the
    # value as an external link (`target="_blank"`).
    #
    # Normalization completes a scheme-less value whose authority is a
    # dotted DNS-style host (plus optional port) with `https://` before
    # validation — the same rule the frontend's url widget applies, so the
    # UI's bare-host convenience (`www.acme.tld`) and a REST client's raw
    # input converge on the identical stored value (B-294). Dotless hosts
    # (`not-a-url`, `localhost:3000`) are never completed: free text and
    # single-label hosts must carry their scheme explicitly, and `validate`
    # refuses them.
    class UrlType < FieldType
      register_type "url"

      # The bare-host shapes that are completed (B-294): a dotted, DNS-style
      # authority with an optional `:port`. The dot separates a host the user
      # means to dereference (`www.acme.tld`, `acme.tld/path`) from free text
      # that merely reads like one (`not-a-url`). Everything outside the
      # charset — whitespace, `!`, `@`, a bare IPv6 literal — is not a host
      # to complete; the scheme-less value passes through and `validate`
      # surfaces the original error.
      private def completable_bare_host?(trimmed : String) : Bool
        authority = trimmed.split(%r{[/?#]}, 2)[0]
        authority.matches?(/\A[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+(:\d+)?\z/)
      end

      # Completes a scheme-less value the same way at every entry point
      # (B-294): `www.acme.tld` is stored as `https://www.acme.tld`, mirroring
      # the frontend's url widget. Returns `value` unchanged when no
      # completion applies — a value that already carries a scheme, a blank
      # string, or a scheme-less value without a dotted host — so `validate`
      # still surfaces the original error.
      def normalize(
        value : JSON::Any,
        field_definition : FieldDefinition,
      ) : JSON::Any
        str = value.as_s?
        return value unless str
        trimmed = str.strip
        return value if trimmed.empty? || trimmed.matches?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        completable_bare_host?(trimmed) ? JSON::Any.new("https://" + trimmed) : value
      end

      # `URI.parse` is lenient about the authority — `"https://exa mple.test/x"`
      # parses with `host == "exa mple.test"`, and `"https://ht!tp://bad url"`
      # with `host == "ht!tp"` — so the character check below is the real
      # host gate. Underscores stay allowed (intranet hostnames); everything
      # outside the DNS-style set (whitespace, `!`, an embedded `:`, …) is a
      # malformed authority, not a host.
      private def valid_host?(host : String) : Bool
        return false if host.matches?(/\s/)
        return host.matches?(/\A\[[0-9a-fA-F:.]+\]\z/) if host.starts_with?("[")

        !host.matches?(/[^A-Za-z0-9._-]/)
      end

      def validate(
        value : JSON::Any,
        field_definition : FieldDefinition,
        path : String,
        errors : Array(ValidationError),
      ) : Nil
        str = require_string(value, path, errors)
        return if str.nil?

        error_params = {"value" => str, "format" => "an absolute http(s) URL"}
        uri = URI.parse(str)
        host = uri.host
        valid = uri.scheme.in?("http", "https") && !host.nil? && !host.empty? &&
                valid_host?(host)
        unless valid
          errors << ValidationError.new(
            field: path,
            message: "is not a valid URL (expected http(s)://...): '#{str}'",
            code: "invalid_format",
            params: error_params,
          )
        end
      rescue URI::Error
        errors << ValidationError.new(
          field: path,
          message: "is not a valid URL: '#{str}'",
          code: "invalid_format",
          params: error_params,
        )
      end
    end
  end
end
