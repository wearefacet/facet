# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Facet::Document::DocURI — canonical document reference.
#
# A `DocURI` is the standard, unique, human-readable string that references
# a single Facet document. It follows the URN syntax (RFC 8141):
#
#   urn:facet:{domain}:{Doctype}:{opaque}
#
# Optionally followed by a q-component that pins the reference to a
# specific historical state of the document:
#
#   urn:facet:{domain}:{Doctype}:{opaque}?state={mutation_ulid}
#
# Examples:
#
#   urn:facet:hr:Employee:01J5X2…
#   urn:facet:core:DocType:hr.Employee      # DocType registration
#   urn:facet:core:Domain:hr                # Domain registration
#   urn:facet:hr:Employee:01J5X2…?state=01J5Y…
#
# `domain` and `Doctype` follow the same naming rules enforced at doctype
# registration (see `Doctype::DoctypeDefinition`). The `opaque` segment is the
# document's locally-unique id — typically a ULID for user documents, the
# qualified `{domain}.{Doctype}` for `core.DocType` registrations, or the
# bare domain name for `core.Domain` registrations.
#
# The URN form is *derivable* from the stored `projections.id`, which is
# the legacy dotted form `{domain}.{Doctype}.{opaque}` (or the legacy
# two-segment `{domain}.{Doctype}` for `core.DocType`/`core.Domain`).
# Use `DocURI.from_projection_id` to derive from storage, and
# `DocURI.to_projection_id` to convert back to the storage form.

module Facet::Document
  struct DocURI
    # URN namespace identifier (RFC 8141 NID).
    NID = "facet"

    # Matches the registered doctype `domain` rule:
    # lowercase alphanumeric with dashes, may start with `_` (draft),
    # cannot start with a digit.
    DOMAIN_RE = /^_?[a-z0-9][a-z0-9\-]*$/

    # Matches the registered doctype `doctype` rule:
    # CamelCase alphanumeric, cannot start with a digit.
    DOCTYPE_RE = /^[A-Z][a-zA-Z0-9]*$/

    # Matches the opaque id portion. Allows any printable ASCII except
    # `:` and `?` (both reserved by the URI grammar). Allows `.` for the
    # `core.DocType`/`core.Domain` qualified-id special case.
    OPAQUE_RE = /^[A-Za-z0-9._-]+$/

    getter domain : String
    getter doctype : String
    getter opaque : String
    getter state : String?

    # Builds a `DocURI`. Does not validate format — use `parse` for input
    # from untrusted sources, or call `valid?` after construction.
    def initialize(@domain : String, @doctype : String, @opaque : String, @state : String? = nil)
    end

    # Convenience for building a canonical URN without going through `parse`.
    def self.build(domain : String, doctype : String, opaque : String, state : String? = nil) : self
      new(domain, doctype, opaque, state)
    end

    # Parses a string into a `DocURI`, or returns `nil` on malformed input.
    #
    # Accepts both the canonical URN form (`urn:facet:hr:Employee:opaque`)
    # and the legacy dotted storage form (`hr.Employee.opaque`,
    # `hr.Employee`), so callers can pass either `meta.uri` or `meta.id`.
    def self.parse(str : String) : self?
      return nil if str.empty?

      # Canonical URN form.
      if str.starts_with?("urn:#{NID}:")
        return parse_urn(str)
      end

      # Legacy dotted storage form: split on `.` and reassemble.
      parse_dotted(str)
    end

    # Derives a `DocURI` from a stored `projections.id`.
    #
    # For regular documents the id is a bare ULID (the opaque segment).
    # Legacy three-segment ids (`domain.Doctype.opaque`) have their prefix
    # stripped for backward compatibility.
    # The two special cases are:
    # - `core.DocType` registrations: id is `{domain}.{Doctype}` (e.g. `hr.Employee`)
    # - `core.Domain` registrations: id is the bare domain name (e.g. `hr`)
    def self.from_projection_id(domain : String, doctype : String, id : String) : self
      # Strip legacy three-segment prefix if present.
      prefix = "#{domain}.#{doctype}."
      if id.starts_with?(prefix)
        return new(domain, doctype, id[prefix.size..-1])
      end
      new(domain, doctype, id)
    end

    # Converts this URI back to the `projections.id` storage form.
    #
    # The two special cases are preserved:
    # - `core.DocType` registrations store the qualified doctype id directly
    #   (e.g. `hr.Employee`).
    # - `core.Domain` registrations store the bare domain name (e.g. `hr`).
    # - All other documents store the opaque id directly (a bare ULID).
    def to_projection_id : String
      @opaque
    end

    # Returns the canonical URN string, including `?state=` when set.
    def to_s(io : IO) : Nil
      io << "urn:" << NID << ":" << @domain << ":" << @doctype << ":" << @opaque
      if s = @state
        io << "?state=" << s
      end
    end

    # True when `domain`, `doctype`, `opaque` all match their respective
    # character-class rules, and when `state` (if present) is non-empty.
    def valid? : Bool
      s = @state
      @domain.matches?(DOMAIN_RE) &&
        @doctype.matches?(DOCTYPE_RE) &&
        @opaque.matches?(OPAQUE_RE) &&
        (s.nil? || !s.empty?)
    end

    # Parses the canonical URN form: `urn:facet:domain:Doctype:opaque[?state=…]`
    private def self.parse_urn(str : String) : self?
      # Strip the `urn:facet:` prefix.
      rest = str[(NID.size + 5)..-1]? # "urn:" + NID + ":"
      return nil if rest.nil? || rest.empty?

      # Split off q-component first, if present.
      state = nil
      if qpos = rest.index('?')
        q = rest[(qpos + 1)..-1]
        rest = rest[0...qpos]
        # Only `state=…` is supported.
        return nil unless q.starts_with?("state=")
        state = q[6..-1]?
        return nil if state.nil? || state.empty?
      end

      # NSS segments: domain, doctype, opaque joined by `:`.
      # The opaque part may contain `.` (for qualified ids) but not `:`.
      parts = rest.split(':', limit: 4)
      return nil unless parts.size == 3
      domain, doctype, opaque = parts
      uri = new(domain, doctype, opaque, state)
      uri.valid? ? uri : nil
    end

    # Parses the legacy dotted storage form.
    #
    # - `domain.Doctype.opaque` → three chunks
    # - `domain.Doctype` (special: doctype id, domain id)
    #   — disambiguated by requiring the doctype name to be CamelCase
    #     and the domain name to be lower_case.
    private def self.parse_dotted(str : String) : self?
      parts = str.split('.')
      case parts.size
      when 3
        domain, doctype, opaque = parts
      when 2
        # `core.DocType` style: opaque == the whole two-segment id.
        domain, doctype = parts
        opaque = str
      else
        return nil
      end

      uri = new(domain, doctype, opaque)
      uri.valid? ? uri : nil
    end
  end
end
