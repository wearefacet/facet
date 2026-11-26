# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "uri"
require "socket"
require "../config"

module Facet
  module Webhook
    # Target-URL gate for outbound webhooks (B-76). One rule, three callers:
    #
    # - the authoring Lua hook (`core.Webhook/script.lua`, via the
    #   `util.safe_webhook_url` binding) — a webhook the server would refuse
    #   to dial cannot be created (the B-77 authoring-time pattern);
    # - `Dispatcher#execute` — a rejection classifies the delivery row
    #   `Failed` (a transport classification, so it retries like any other
    #   transport failure);
    # - `Webhook::Test.call` — a rejection answers 422, before any wire.
    #
    # The gate is scheme-aware (the B-77 https rule) and host-aware: the
    # host must resolve, and every resolved address must be public. The
    # deny-list covers loopback, link-local (the cloud-metadata range),
    # RFC-1918 / unique-local private space, carrier NAT, benchmarking /
    # documentation ranges, multicast, and reserved space; IPv4-mapped IPv6
    # (`::ffff:127.0.0.1`) is unmasked and re-judged, so the mapped form
    # cannot smuggle a private v4 target past the v6 checks. A host that
    # matches `webhook.allowed_hosts` — an exact hostname entry, an IP
    # literal, or a CIDR — passes before the deny-list is consulted; that
    # config list is the sanctioned escape hatch for legitimate internal
    # receivers.
    #
    # Hostname entries on the allowlist string-match the URL host, so a
    # pinned internal name needs no DNS at check time. CIDR entries match
    # after resolution, so an allowlisted name cannot smuggle an address
    # change past a literal comparison.
    #
    # Check order: shape → scheme → allowlist → deny-list → pass. The
    # check-time and dial-time lookups are separate, so the transport pins
    # the dial to the checked address (`checked_address` returns the address
    # the gate accepted; `Webhook::Transport` dials that IP while keeping the
    # original hostname for SNI and `Host`), which closes the DNS-rebinding
    # window. Crystal's `HTTP::Client` does not follow redirects, so a 30x
    # answer never widens the target; if redirect following is ever enabled,
    # every hop must re-run this gate and re-pin.
    module TargetCheck
      # Shared rejection texts. The insecure-URL text is the one the
      # dispatcher and `/test` have answered since B-77; the authoring hook
      # uses the same texts so authoring and delivery never disagree about
      # why a URL was refused.
      INSECURE_TARGET_MESSAGE = "insecure webhook target URL rejected — only https is allowed; " \
                                "set webhook.allow_insecure_urls to permit plain http"
      PRIVATE_TARGET_MESSAGE = "webhook target URL rejected — the host resolves to a private, loopback, " \
                               "link-local, or reserved address; internal receivers need a " \
                               "webhook.allowed_hosts entry"
      UNRESOLVED_TARGET_MESSAGE = "webhook target URL rejected — the host does not resolve"
      INVALID_TARGET_MESSAGE    = "webhook target URL is not an absolute http(s) URL with a host"

      # Full gate. Returns `nil` when the URL is safe to dial, else the
      # rejection message. The per-dial callers treat a non-nil result as a
      # transport classification, never as a crash.
      def self.check(url : String) : String?
        uri = URI.parse(url)
        return INVALID_TARGET_MESSAGE unless uri.scheme.in?("http", "https")
        host = uri.host
        return INVALID_TARGET_MESSAGE if host.nil? || host.empty?

        unless Facet::Config.instance.webhook.allow_insecure_urls
          return INSECURE_TARGET_MESSAGE unless uri.scheme == "https"
        end

        host_rejection(host)
      rescue URI::Error
        INVALID_TARGET_MESSAGE
      end

      # Resolves and judges one host for the dial: returns the first address
      # the gate accepts, so `Webhook::Transport` can pin the dial to the
      # address it checked (S9 — closing the DNS-rebinding window between
      # the check-time and dial-time lookups). Returns `nil` when the URL is
      # not an absolute http(s) URL, the host does not resolve, or the host
      # is refused (private, loopback, or reserved and not on the allowlist).
      # The scheme rule stays with `check`; this method judges only where the
      # host points, and the caller runs `check` for the message.
      def self.checked_address(url : String) : Socket::IPAddress?
        uri = URI.parse(url)
        return nil unless uri.scheme.in?("http", "https")
        host = uri.host
        return nil if host.nil? || host.empty?
        resolved = safe_resolved_addresses(host)
        resolved.first?
      rescue URI::Error
        nil
      end

      # The host half of the webhook target rule: true when the URL's host
      # resolves and every resolved address is public or on
      # `webhook.allowed_hosts`; a host that does not resolve answers false.
      # The scheme rule stays in the Lua hook (it needs
      # `util.insecure_urls_allowed` to word its rejection), and the `url`
      # field type already enforces the absolute http(s) shape, so this
      # path judges only where the host points.
      def self.host_safe?(url : String) : Bool
        host = URI.parse(url).host
        return false if host.nil? || host.empty?
        host_rejection(host).nil?
      rescue URI::Error
        false
      end

      # ── Host judgement ───────────────────────────────────────────────

      # Resolves and judges one host. Returns `nil` when every resolved
      # address is public (or the host is allowlisted), else the rejection
      # message. An unresolvable host is refused fail-closed: a webhook
      # that can never deliver is the silent-success class.
      private def self.host_rejection(host : String) : String?
        normalized = normalize_host(host)

        # Hostname allowlist entries pass without DNS — a pinned internal
        # name is an operator decision, not something resolution may
        # second-guess.
        return nil if host_allowlisted?(normalized, nil)

        resolved = resolve(normalized)
        return UNRESOLVED_TARGET_MESSAGE if resolved.empty?

        return nil if host_allowlisted?(normalized, resolved)
        return PRIVATE_TARGET_MESSAGE if resolved.any? { |addr| denied_address?(addr) }

        nil
      end

      # The addresses a dial may pin to, or an empty array when the host is
      # refused. Same judgement as `host_rejection`, but returns the
      # accepted addresses instead of a message so the transport dials an
      # address the gate saw. An allowlisted host returns every resolved
      # address; a hostname-only allowlist entry (no DNS) has no address to
      # pin to and returns an empty array — the transport then dials by name
      # for that operator-approved case.
      private def self.safe_resolved_addresses(host : String) : Array(Socket::IPAddress)
        normalized = normalize_host(host)

        return resolve(normalized) if host_allowlisted?(normalized, nil)

        resolved = resolve(normalized)
        return [] of Socket::IPAddress if resolved.empty?

        return resolved if host_allowlisted?(normalized, resolved)
        return [] of Socket::IPAddress if resolved.any? { |addr| denied_address?(addr) }

        resolved
      end

      # One seam for tests: specs swap this to a canned mapping so the
      # suite never performs real DNS (deterministic under air-gapped or
      # wildcard-resolving resolvers, and free of the multi-second cold
      # NXDOMAIN cost). Production keeps the real resolver.
      class_property resolver : Proc(String, Array(Socket::IPAddress)) = ->(host : String) { TargetCheck.resolve_real(host) }

      private def self.resolve(host : String) : Array(Socket::IPAddress)
        resolver.call(host)
      end

      # The production resolver. IP literals ride `Addrinfo` too — a
      # bracketed v6 literal (`[::1]`, `URI#host`'s form) is not resolvable
      # text, so strip the brackets first. A parseable literal that
      # getaddrinfo still refuses (a scoped form, say) falls through to the
      # stdlib parser.
      def self.resolve_real(host : String) : Array(Socket::IPAddress)
        probe = host.starts_with?('[') && host.ends_with?(']') ? host[1..-2] : host
        if Socket::IPAddress.parse_v4_fields?(probe) || Socket::IPAddress.parse_v6_fields?(probe)
          return [Socket::IPAddress.new(probe, 0)]
        end
        Socket::Addrinfo.resolve(host, "0", nil, Socket::Type::STREAM, Socket::Protocol::TCP).map(&.ip_address)
      rescue Socket::Error
        [] of Socket::IPAddress
      end

      # True when the host matches a `webhook.allowed_hosts` entry: an
      # exact hostname (case-insensitive, trailing dot ignored), an IP
      # literal equal to a resolved address, or a CIDR containing a
      # resolved address. `resolved` is nil only for the pre-resolution
      # string-match pass; CIDR and literal entries are skipped there.
      private def self.host_allowlisted?(host : String, resolved : Array(Socket::IPAddress)?) : Bool
        entries = Facet::Config.instance.webhook.allowed_hosts
        return false if entries.empty?

        entries.any? do |entry|
          if entry.includes?('/')
            next false if resolved.nil?
            parsed = parse_cidr(entry)
            next false if parsed.nil?
            resolved.any? { |addr| parsed.includes?(addr) }
          elsif entry_ip = ip16_bytes_of_text(entry)
            # IP-literal entry (v4 or v6): compare the full 16-byte form,
            # so "127.0.0.1" and "::ffff:7f00:1" are the same entry.
            next false if resolved.nil?
            resolved.any? { |addr| ip16_bytes(addr) == entry_ip }
          else
            normalize_host(entry) == host
          end
        end
      rescue
        # A malformed config entry must never widen the gate — fail closed.
        false
      end

      private def self.normalize_host(host : String) : String
        host = host.downcase
        host = host[0...-1] if host.ends_with?('.') && host.size > 1
        host
      end

      # ── Address classification ───────────────────────────────────────

      # True when the address must not be dialed: loopback, link-local
      # (metadata), private, carrier NAT, benchmarking, documentation,
      # multicast, reserved, or the unspecified address. IPv4-mapped IPv6
      # is unmasked and judged by its embedded IPv4 address.
      private def self.denied_address?(addr : Socket::IPAddress) : Bool
        v4 = ipv4_bytes(addr)
        if v4
          V4_DENY_RANGES.any?(&.includes?(addr))
        else
          bytes16 = ip16_bytes(addr)
          # Unparseable → fail closed. The mapped range (::ffff:0:0/96) is
          # checked here on the 16-byte form: a mapped address carries v4
          # fields, so the v4 branch above never sees it as text.
          return true if bytes16.nil?
          mapped = bytes16[0..9].all?(&.zero?) && bytes16[10] == 0xff && bytes16[11] == 0xff
          if mapped
            V4_DENY_RANGES.any?(&.includes_v4?(bytes16[12, 4]))
          else
            V6_DENY_RANGES.any?(&.includes?(addr))
          end
        end
      end

      # ── Address → bytes ─────────────────────────────────────────────
      #
      # Parsing is delegated to the stdlib (`Socket::IPAddress.parse_v4_fields?
      # / parse_v6_fields?`): they own the full grammar (IPv4-mapped, embedded
      # dotted tails, `::` compression, zone ids) and reject non-canonical
      # forms (octal octets, short v4), so the gate cannot be fooled by a
      # weird-but-parsable spelling of a private address.

      # The address as 4 IPv4 bytes when it is IPv4 or IPv4-mapped IPv6,
      # else nil. `protected` — the range records below call back into the
      # shared parsers, and a nested type inside the same namespace may
      # reach them while outside callers may not.
      protected def self.ipv4_bytes(addr : Socket::IPAddress) : Slice(UInt8)?
        fields = Socket::IPAddress.parse_v4_fields?(addr.address)
        if fields
          bytes = Slice(UInt8).new(4)
          4.times { |i| bytes[i] = fields[i] }
          return bytes
        end

        # IPv4-mapped: the mapped range is checked on the 16-byte form, so
        # this path returns nil and the v6 judge unmasks it.
        nil
      end

      # Any address (v4 or v6) as 16 bytes — a bare IPv4 maps into the
      # IPv4-mapped prefix — or nil when unparseable. Delegates to the text
      # parser so `allowed_hosts` entries and resolved addresses agree on
      # one form. `protected` for the range records, same as `ipv4_bytes`.
      protected def self.ip16_bytes(addr : Socket::IPAddress) : Slice(UInt8)?
        ip16_bytes_of_text(addr.address)
      end

      # Any IP text — bare IPv4, IPv6, or the `::ffff:` mapped spelling — as
      # its 16-byte form, or nil when unparseable. IPv4 maps into the
      # IPv4-mapped prefix, so a bare literal and its `::ffff:` spelling are
      # one address everywhere the 16-byte form is compared: an
      # `allowed_hosts` IP entry matches a host that resolves to it under
      # either spelling (B-84).
      private def self.ip16_bytes_of_text(text : String) : Slice(UInt8)?
        if v4_fields = Socket::IPAddress.parse_v4_fields?(text)
          bytes = Slice(UInt8).new(16)
          bytes[10] = 0xffu8
          bytes[11] = 0xffu8
          4.times { |i| bytes[12 + i] = v4_fields[i] }
          return bytes
        end

        v6_fields = Socket::IPAddress.parse_v6_fields?(text) || return nil
        bytes = Slice(UInt8).new(16)
        8.times do |i|
          g = v6_fields[i]
          bytes[i * 2] = (g >> 8).to_u8
          bytes[i * 2 + 1] = (g & 0xff).to_u8
        end
        bytes
      end

      # ── Range grammar (deny-list + allowlist CIDRs) ──────────────────

      private record V4Range, net : UInt32, prefix : Int32 do
        def includes?(addr : Socket::IPAddress) : Bool
          bytes = TargetCheck.ipv4_bytes(addr)
          return false if bytes.nil?
          includes_v4?(bytes)
        end

        def includes_v4?(bytes : Slice(UInt8)) : Bool
          value = (bytes[0].to_u32 << 24) | (bytes[1].to_u32 << 16) | (bytes[2].to_u32 << 8) | bytes[3].to_u32
          mask = prefix.zero? ? 0u32 : ~0u32 << (32 - prefix)
          (value & mask) == (net & mask)
        end
      end

      private record V6Range, bytes : Slice(UInt8), prefix : Int32 do
        def includes?(addr : Socket::IPAddress) : Bool
          addr_bytes = TargetCheck.ip16_bytes(addr)
          return false if addr_bytes.nil?
          full = prefix.divmod(8)
          return false unless addr_bytes[0, full[0]] == bytes[0, full[0]]
          return true if full[1].zero?
          mask = (0xffu8 << (8 - full[1])) & 0xff
          (addr_bytes[full[0]] & mask) == (bytes[full[0]] & mask)
        end
      end

      private def self.parse_cidr(entry : String) : V4Range | V6Range?
        addr_text, _, prefix_text = entry.partition('/')
        prefix = prefix_text.empty? ? nil : prefix_text.to_i?
        return nil if prefix && prefix < 0

        if bytes = parse_v4_fields(addr_text)
          bits = prefix || 32
          return nil if bits > 32
          net = (bytes[0].to_u32 << 24) | (bytes[1].to_u32 << 16) | (bytes[2].to_u32 << 8) | bytes[3].to_u32
          return V4Range.new(net, bits)
        end

        if bytes = ip16_bytes_of_text(addr_text)
          bits = prefix || 128
          return nil if bits > 128
          return V6Range.new(bytes, bits)
        end

        nil
      end

      # The stdlib v4 field parser, wrapped as a byte slice.
      private def self.parse_v4_fields(text : String) : Slice(UInt8)?
        fields = Socket::IPAddress.parse_v4_fields?(text) || return nil
        bytes = Slice(UInt8).new(4)
        4.times { |i| bytes[i] = fields[i] }
        bytes
      end

      # ── Range grammar (deny-list + allowlist CIDRs) ──────────────────

      private def self.v4_range(text : String) : V4Range
        bytes = parse_v4_fields(text.partition('/')[0])
        raise ArgumentError.new("invalid IPv4 deny/allow range: #{text}") if bytes.nil?
        net = (bytes[0].to_u32 << 24) | (bytes[1].to_u32 << 16) | (bytes[2].to_u32 << 8) | bytes[3].to_u32
        V4Range.new(net, text.partition('/')[2].to_i)
      end

      private def self.v6_range(text : String) : V6Range
        bytes = ip16_bytes_of_text(text.partition('/')[0])
        raise ArgumentError.new("invalid IPv6 deny/allow range: #{text}") if bytes.nil?
        V6Range.new(bytes, text.partition('/')[2].to_i)
      end

      private V4_DENY_RANGES = [
        v4_range("0.0.0.0/8"),       # "this network" / unspecified
        v4_range("10.0.0.0/8"),      # RFC 1918 private
        v4_range("100.64.0.0/10"),   # carrier-grade NAT
        v4_range("127.0.0.0/8"),     # loopback
        v4_range("169.254.0.0/16"),  # link-local — the metadata range
        v4_range("172.16.0.0/12"),   # RFC 1918 private
        v4_range("192.0.0.0/24"),    # IETF protocol assignments
        v4_range("192.0.2.0/24"),    # TEST-NET-1 (documentation)
        v4_range("192.168.0.0/16"),  # RFC 1918 private
        v4_range("198.18.0.0/15"),   # benchmarking
        v4_range("198.51.100.0/24"), # TEST-NET-2 (documentation)
        v4_range("203.0.113.0/24"),  # TEST-NET-3 (documentation)
        v4_range("224.0.0.0/4"),     # multicast
        v4_range("240.0.0.0/4"),     # reserved (incl. broadcast)
      ]

      private V6_DENY_RANGES = [
        v6_range("::/128"),        # unspecified
        v6_range("::1/128"),       # loopback
        v6_range("::ffff:0:0/96"), # IPv4-mapped — unmasked before judging
        v6_range("2001:db8::/32"), # documentation
        v6_range("fc00::/7"),      # unique local
        v6_range("fe80::/10"),     # link-local
        v6_range("ff00::/8"),      # multicast
      ]
    end
  end
end
