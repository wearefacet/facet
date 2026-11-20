# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # The doctype used to qualify every `$self` token in named-scope
    # `where` clauses. `$self` always refers to the actioner's account.
    # Reference fields targeting `iam.Account` store the fully qualified
    # form (`iam.Account.<id>`), while plain string fields hold the bare
    # account id (the documented `ctx.root.owner_id = ctx.actor.id`
    # recipe) — a `$self` predicate therefore accepts both forms.
    PRINCIPAL_QUALIFIED_DOCTYPE = "iam.Account"

    # A shared helper that qualifies a bare account id into the storage form
    # used by reference fields targeting `iam.Account`. Used by RBAC scope
    # evaluation (ScopeMatcher) and context set resolution (ContextResolver)
    # as one of the two accepted `$self` forms.
    def self.qualify_principal(account_id : String) : String
      "#{PRINCIPAL_QUALIFIED_DOCTYPE}.#{account_id}"
    end

    # The stored forms a `$self` predicate matches: the bare account id
    # (what a plain string field holds — e.g. a create hook writing
    # `ctx.actor.id`) and the fully qualified `iam.Account.<id>` reference
    # form (what a reference field targeting `iam.Account` stores).
    # Deduplicated when the id already carries the qualified prefix.
    def self.principal_forms(account_id : String) : Array(String)
      qualified = qualify_principal(account_id)
      account_id == qualified ? [qualified] : [account_id, qualified]
    end

    # A typed predicate value used inside a named scope's `where` clause.
    #
    # Named scopes are declared on the doctype definition. Their `where` map
    # is a `field -> ScopeValue` predicate evaluated against a projection's
    # content. The supported value grammar is:
    #
    # - a **literal** (compared verbatim against the field's content value)
    # - `$self` — the actioner's account id (matched against both the bare
    #   id and the qualified `iam.Account.<id>` reference form)
    # - `$<context_set>` — a domain-declared context set, resolved at request
    #   time by `ContextResolver` into a set of values
    # - `$null` — matches rows where the field is absent or JSON null. Lets a
    #   named scope express `IS NULL` predicates (e.g. global rows whose owner
    #   is unassigned), which literal/`$self`/`$<context_set>` cannot express.
    # - `$organizational_unit` — the actioner's own
    #   `iam.Account.organizational_unit` value, fetched at request time by
    #   the enforcers (trusted bypass) and carried on the per-request
    #   `ScopeContext`. Lets a named scope express "rows in my organizational
    #   unit" (e.g. `where: { ou: "$organizational_unit" }`).
    # - the field name `$parent_id` — reserved: reads the system-managed
    #   parent linkage stored at `meta->>'parent_id'`. Used as a *field* on
    #   the left-hand side of a `where` entry, not as a value.
    #
    # Permission scopes are not `ScopeValue`s — a permission
    # references a named scope by alias string (`"$<name>"` or `"$all"`).
    # See `Permission#scope`.
    enum ScopeValueType
      Literal
      Self
      ContextSet
      Null
      OrganizationalUnit
    end

    struct ScopeValue
      getter type : ScopeValueType
      getter raw : String

      # Creates a ScopeValue from a YAML/JSON string value in a named scope.
      def self.parse(raw : String) : self
        if raw == "$self"
          new(ScopeValueType::Self, raw)
        elsif raw == "$null"
          new(ScopeValueType::Null, raw)
        elsif raw == "$organizational_unit"
          new(ScopeValueType::OrganizationalUnit, raw)
        elsif raw.starts_with?("$")
          new(ScopeValueType::ContextSet, raw)
        else
          new(ScopeValueType::Literal, raw)
        end
      end

      def initialize(@type : ScopeValueType, @raw : String)
      end

      # Returns true if this value references a context set (starts with $
      # but is not a reserved token).
      def context_set? : Bool
        @type == ScopeValueType::ContextSet
      end

      # Returns the context set name (without the $ prefix) when applicable.
      def context_set_name : String?
        @raw[1..] if context_set?
      end

      def ==(other : self) : Bool
        @type == other.type && @raw == other.raw
      end
    end
  end
end
