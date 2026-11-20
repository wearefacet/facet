# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # A single permission line within a role.
    #
    # Grants one action on one doctype-path, optionally restricted by one or
    # more named scopes declared on the leaf doctype. Multiple scopes on a
    # single permission are combined with OR semantics at enforcement time.
    #
    # Wire format:
    #
    #   {"action": "read", "on": "crm.Project"}                            # unrestricted
    #   {"action": "read", "on": "crm.Project", "scope": "$all"}           # explicit unrestricted
    #   {"action": "read", "on": "crm.Project", "scope": "$mine"}         # single named scope (legacy form)
    #   {"action": "read", "on": "crm.Project", "scope": ["$mine"]}       # single named scope (canonical form)
    #   {"action": "read", "on": "crm.Project", "scope": ["$mine", "$global"]}  # OR of named scopes
    #   {"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}  # path carve-out
    #
    # The `scope` field accepts either a single alias string (legacy) or an
    # array of alias strings (canonical). `$all` is the explicit unrestricted
    # sentinel; an absent `scope` is equivalent to `$all`. When `$all` appears
    # in an array, the whole permission collapses to unrestricted.
    #
    # The `except` field subtracts doctype paths from the permission's `on`
    # reach: a target matching an `except` entry never matches the
    # permission, even when it matches `on`. Entries are concrete
    # `domain.Doctype` paths (no wildcards) and prefix-match exactly like
    # `on` — an entry on `core.DocType` also excludes `core.DocType.Comment`.
    # This is pure path arithmetic, not a deny system: it only shrinks what
    # one line matches, so a scoped re-grant on the same paths becomes
    # meaningful alongside a blanket line.
    #
    # Roles cannot author custom query predicates — they can only reference
    # named scopes declared on the target doctype.
    struct Permission
      getter action : String
      getter domain : String
      getter path : Array(String)
      getter scope : Array(String)
      getter except_paths : Array(String)

      # The wildcard action `*` matches all actions.
      WILDCARD_ACTION = "*"

      # The wildcard path `*.*` matches all doctypes in all domains.
      WILDCARD_DOMAIN  = "*"
      WILDCARD_DOCTYPE = "*"

      # The explicit unrestricted scope sentinel.
      ALL_SCOPE = "$all"

      # Parses a permission from a raw JSON hash.
      #
      # `scope` accepts both the legacy single-string form and the canonical
      # array form. The result is always normalised to an `Array(String)`:
      #
      # - absent    → `[]` (unrestricted)
      # - `"$all"`  → `[]` (unrestricted; sentinel collapses)
      # - `"$mine"` → `["$mine"]`
      # - `["$mine"]`                  → `["$mine"]`
      # - `["$all", "$mine"]`          → `[]` (any `$all` collapses to unrestricted)
      def self.from_json(raw : JSON::Any) : self
        h = raw.as_h
        action = h["action"]?.try(&.as_s) || raise ArgumentError.new("Permission missing 'action'")
        on_str = h["on"]?.try(&.as_s) || raise ArgumentError.new("Permission missing 'on'")
        scope = parse_scope(h["scope"]?)
        except_paths = parse_except(h["except"]?)

        parts = on_str.split('.')
        domain = parts[0]
        path = parts[1..]

        new(action: action, domain: domain, path: path, scope: scope, except: except_paths)
      end

      # Normalises a raw `scope` value into an `Array(String)`.
      #
      # Accepts: nil, a single string, or an array of strings. `$all` collapses
      # the whole result to an empty array (unrestricted). Non-string entries
      # in an array form raise `ArgumentError`.
      private def self.parse_scope(raw : JSON::Any?) : Array(String)
        return [] of String if raw.nil?

        case raw.raw
        when String
          s = raw.as_s
          s == ALL_SCOPE ? [] of String : [s]
        when Array
          arr = raw.as_a
          aliases = [] of String
          arr.each do |entry|
            unless entry.raw.is_a?(String)
              raise ArgumentError.new("Permission scope array entries must be strings (got: #{entry.raw.inspect})")
            end
            aliases << entry.as_s
          end
          aliases.any? { |a| a == ALL_SCOPE } ? [] of String : aliases
        else
          raise ArgumentError.new("Permission 'scope' must be a string or an array of strings (got: #{raw.raw.inspect})")
        end
      end

      def initialize(
        @action : String,
        @domain : String,
        @path : Array(String),
        scope : String | Array(String)? = nil,
        except : Array(String)? = nil,
      )
        @scope = normalize_scope(scope)
        @except_paths = except || [] of String
        @except_paths.each { |entry| validate_except_entry!(entry) }
      end

      # Normalises the constructor's `scope` argument into the canonical
      # `Array(String)` form. Accepts the legacy single-string form, the
      # canonical array form, or nil (unrestricted). `$all` collapses to an
      # empty array (unrestricted).
      private def normalize_scope(scope : String | Array(String)?) : Array(String)
        if scope.nil?
          [] of String
        elsif scope.is_a?(String)
          scope == ALL_SCOPE ? [] of String : [scope]
        else
          scope.any? { |s| s == ALL_SCOPE } ? [] of String : scope
        end
      end

      # Returns true if this permission matches the given action.
      def matches_action?(target_action : String) : Bool
        @action == WILDCARD_ACTION || @action == target_action
      end

      # Returns true if this permission targets the given (domain, doctype_path).
      # A target matched by an `except` entry never matches — the entry
      # subtracts from the `on` reach (prefix-matched like `on`).
      def matches_path?(target_domain : String, target_path : Array(String)) : Bool
        return false if matches_except?(target_domain, target_path)

        # Wildcard domain matches everything (the sole exception to domain isolation)
        return true if @domain == WILDCARD_DOMAIN

        # Domain must match exactly
        return false unless @domain == target_domain

        # Path must match: this permission's path must be a prefix of the target path
        # (e.g. permission on "Project" matches "Project.Comment")
        @path.size <= target_path.size && @path.zip(target_path).all? { |a, b| a == b }
      end

      # Returns true if this permission applies to a create action on a given path.
      def covers_create?(target_domain : String, target_path : Array(String)) : Bool
        matches_action?("create") && matches_path?(target_domain, target_path)
      end

      # Returns true if this permission is a wildcard (admin/god-role).
      def wildcard? : Bool
        @action == WILDCARD_ACTION && @domain == WILDCARD_DOMAIN && @path == [WILDCARD_DOCTYPE]
      end

      # Returns true if the permission is unrestricted (no scope or `$all`).
      def unrestricted? : Bool
        @scope.empty?
      end

      # Conservative implication arithmetic: returns `true` when every
      # authorization this permission grants is also granted by *holder* —
      # the pure power test behind role-authoring checks (a rewritten role
      # may only hold lines the previous role or the caller's active role
      # already imply).
      #
      # Rules (any unsupported or uncertain shape returns `false`):
      # - **action** — the holder action is `*` or equals this action.
      # - **reach** — this line's `on` reach is contained by the holder's:
      #   a wildcard holder domain covers everything; otherwise the domains
      #   match and the holder path is a prefix of this path (prefix
      #   semantics mirror `#matches_path?`).
      # - **carve-outs** — every holder `except` entry whose reach
      #   intersects this line's `on` reach must also be excluded here.
      #   Extra `except` entries on this line are fine — they only narrow.
      # - **scope** — an unrestricted holder implies any scope here;
      #   otherwise this line must be scoped and every alias must also
      #   appear on the holder line.
      def implied_by?(holder : Permission) : Bool
        return false unless holder.action == WILDCARD_ACTION || holder.action == @action
        return false unless reach_contained_by?(holder)
        return false unless holder_excepts_contained_by?(holder)
        scope_contained_by?(holder)
      end

      def scope_aliases : Array(String)
        @scope.map { |s| s.starts_with?("$") ? s[1..] : s }
      end

      # Returns a hash representation (useful for logging/debugging).
      # Preserves the aliases verbatim — expansion to a `where` predicate
      # happens at enforcement time, never persisted.
      def to_h : Hash(String, JSON::Any)
        h = {
          "action" => JSON::Any.new(@action),
          "on"     => JSON::Any.new("#{@domain}.#{@path.join(".")}"),
        }
        unless @scope.empty?
          h["scope"] = JSON::Any.new(@scope.map { |s| JSON::Any.new(s) })
        end
        unless @except_paths.empty?
          h["except"] = JSON::Any.new(@except_paths.map { |e| JSON::Any.new(e) })
        end
        h
      end

      # ── Private ─────────────────────────────────────────────────────────

      # True when this line's `on` reach is contained by the holder's reach.
      # A wildcard holder domain covers everything; otherwise the domains
      # must match and the holder path must be a prefix of this path (the
      # same prefix rule `#matches_path?` applies). A wildcard reach here
      # (`*.*`) is contained only by a wildcard holder reach.
      private def reach_contained_by?(holder : Permission) : Bool
        return holder.domain == WILDCARD_DOMAIN if @domain == WILDCARD_DOMAIN
        return true if holder.domain == WILDCARD_DOMAIN

        return false unless holder.domain == @domain
        holder.path.size <= @path.size && holder.path.zip(@path).all? { |a, b| a == b }
      end

      # True when every holder `except` entry that could subtract from this
      # line's reach is also excluded here. An entry intersects this line's
      # `on` reach when it sits inside the same domain (or this reach is
      # the wildcard) and the two paths are prefix-related — only then can
      # the carve-out remove a target this line would otherwise grant.
      private def holder_excepts_contained_by?(holder : Permission) : Bool
        holder.except_paths.all? do |entry|
          entry_domain, entry_path = split_path(entry)
          next true unless intersects_reach?(entry_domain, entry_path)
          @except_paths.includes?(entry)
        end
      end

      # True when a concrete carve-out path overlaps this line's `on` reach.
      # Both prefix directions matter: the entry may sit at or above this
      # path (subtracting the whole subtree) or below it (subtracting a
      # nested branch this reach extends into). A wildcard reach on this
      # line touches every concrete entry.
      private def intersects_reach?(entry_domain : String, entry_path : Array(String)) : Bool
        return true if @domain == WILDCARD_DOMAIN
        return false unless entry_domain == @domain

        smaller, larger = entry_path.size <= @path.size ? {entry_path, @path} : {@path, entry_path}
        smaller.zip(larger).all? { |a, b| a == b }
      end

      # True when the holder's scope grant covers this line's scope grant.
      # An unrestricted holder implies any scope; otherwise this line must
      # itself be scoped and every alias must appear on the holder line.
      private def scope_contained_by?(holder : Permission) : Bool
        return true if holder.unrestricted?
        return false if @scope.empty?

        @scope.all? { |s| holder.scope.includes?(s) }
      end

      # Returns true when the target matches any `except` entry. Entries are
      # concrete `domain.Doctype` paths (validated at parse time) that
      # prefix-match like `on`: an entry on `core.DocType` also excludes
      # `core.DocType.Comment`.
      private def matches_except?(target_domain : String, target_path : Array(String)) : Bool
        @except_paths.any? do |entry|
          entry_domain, entry_path = split_path(entry)
          entry_domain == target_domain &&
            entry_path.size <= target_path.size &&
            entry_path.zip(target_path).all? { |a, b| a == b }
        end
      end

      private def split_path(on_str : String) : {String, Array(String)}
        parts = on_str.split('.')
        {parts[0], parts[1..]}
      end

      # Normalises a raw `except` value into an `Array(String)`. Accepts nil
      # or an array of strings; anything else raises `ArgumentError`.
      private def self.parse_except(raw : JSON::Any?) : Array(String)
        return [] of String if raw.nil?

        case raw.raw
        when Array
          entries = [] of String
          raw.as_a.each do |entry|
            unless entry.raw.is_a?(String)
              raise ArgumentError.new("Permission except array entries must be strings (got: #{entry.raw.inspect})")
            end
            entries << entry.as_s
          end
          entries
        else
          raise ArgumentError.new("Permission 'except' must be an array of 'domain.Doctype' strings (got: #{raw.raw.inspect})")
        end
      end

      # Validates one `except` entry: a concrete `domain.Doctype` path —
      # same grammar as a non-wildcard `on` path, with no `*` anywhere.
      # Enforced at parse time (single source) so both authoring-time role
      # validation and enforcement-time role loading fail loud on a
      # malformed entry instead of silently widening or narrowing the
      # carve-out.
      private def validate_except_entry!(entry : String) : Nil
        parts = entry.split('.')
        if parts.size < 2 || parts.any?(&.empty?)
          raise ArgumentError.new("Permission except entry '#{entry}' must be a 'domain.Doctype' path")
        end
        if parts.any? { |p| p == "*" }
          raise ArgumentError.new("Permission except entry '#{entry}' must be a concrete 'domain.Doctype' path — wildcards are not allowed")
        end
        unless parts[0].matches?(/^[a-z][a-z0-9\-]*$/)
          raise ArgumentError.new("Permission except entry '#{entry}': invalid domain '#{parts[0]}' (must be lowercase alphanumeric with dashes)")
        end
        parts[1..].each do |seg|
          unless seg.matches?(/^[A-Z][a-zA-Z0-9]*$/)
            raise ArgumentError.new("Permission except entry '#{entry}': invalid path segment '#{seg}' (must be CamelCase)")
          end
        end
      end
    end
  end
end
