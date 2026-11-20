# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet::Mutation
  # Computes a diff between two JSON values.
  #
  # The diff is returned as a `JsonDiff::Result` containing:
  # - `set`: entries with a `path` (array of keys) and a `value` or `patch`
  # - `unset`: paths (array of keys) that were removed
  #
  # For string-to-string changes on long strings (above `PATCH_THRESHOLD`),
  # the `set` entry carries a `patch` (line-based unified diff) instead of
  # the full `value`. This keeps mutation-log rows small for edits to
  # `longtext` fields (markdown bodies, etc.). The patch is applied at
  # projection time by `jsonb_apply_diff` (PL/pgSQL) and at replay time by
  # `Mutation::JsonDiff.apply_diff` (Crystal) — the two mirrors of the
  # diff pipeline.
  #
  # ### Usage
  #
  # ```
  # a = JSON.parse(%({"name": "Alice", "age": 30}))
  # b = JSON.parse(%({"name": "Alice", "age": 31, "city": "Paris"}))
  # diff = Mutation::JsonDiff.diff(a, b)
  # diff.set   # => [{path: ["age"], value: 31}, {path: ["city"], value: "Paris"}]
  # diff.unset # => []
  # ```
  module JsonDiff
    # Minimum string length (in characters) before the diff engine
    # considers producing a line-based patch instead of a full `value`.
    PATCH_THRESHOLD = 256

    # Number of unchanged context lines kept around each hunk.
    CONTEXT_LINES = 3

    # A single hunk in a unified diff.
    struct Hunk
      getter old_start : Int32
      getter old_count : Int32
      getter new_start : Int32
      getter new_count : Int32
      getter lines : Array(String)

      # `lines` are the raw lines (without the leading marker char) but
      # **include** the trailing newline. Stored this way so the JSON
      # serialization matches git's unified-diff convention:
      # `"-removed line\n"`, `"+added line\n"`, `" context line\n"`,
      # and a final line without `\n` (matching "no newline at end").
      def initialize(
        @old_start : Int32,
        @old_count : Int32,
        @new_start : Int32,
        @new_count : Int32,
        @lines : Array(String),
      )
      end
    end

    # A line-based patch consisting of one or more hunks.
    struct Patch
      getter hunks : Array(Hunk)

      def initialize(@hunks : Array(Hunk))
      end

      # True if this patch has no hunks.
      def empty? : Bool
        @hunks.empty?
      end

      def to_json(builder : JSON::Builder)
        builder.object do
          builder.field("hunks") do
            builder.array do
              @hunks.each do |h|
                builder.object do
                  builder.field("old_start", h.old_start)
                  builder.field("old_count", h.old_count)
                  builder.field("new_start", h.new_start)
                  builder.field("new_count", h.new_count)
                  builder.field("lines") do
                    builder.array do
                      hunk_lines = h.lines
                      hunk_lines.each { |l| builder.string(l) }
                    end
                  end
                end
              end
            end
          end
        end
      end

      def to_json : String
        JSON.build { |b| to_json(b) }
      end

      # Parses a `Patch` from its JSON representation (as emitted by
      # `#to_json`). Raises on a malformed shape — a corrupt patch in a
      # mutation row must fail loudly, not silently drop edits.
      def self.from_json(patch_json : JSON::Any) : Patch
        hunks = [] of Hunk
        (patch_json["hunks"]? || JSON::Any.new([] of JSON::Any)).as_a.each do |h|
          lines = h["lines"]?.try(&.as_a.map(&.as_s)) || [] of String
          hunks << Hunk.new(
            old_start: h["old_start"].as_i,
            old_count: h["old_count"].as_i,
            new_start: h["new_start"].as_i,
            new_count: h["new_count"].as_i,
            lines: lines,
          )
        end
        Patch.new(hunks)
      end
    end

    # A single set entry — carries either a `value` or a `patch`.
    # Exactly one of `value` / `patch` is non-nil. The JSON serializer
    # emits `value` when present, otherwise `patch`.
    struct SetEntry
      getter path : Array(String)
      getter value : JSON::Any?
      getter patch : Patch?

      def initialize(@path : Array(String), @value : JSON::Any)
        @patch = nil
      end

      def initialize(@path : Array(String), @patch : Patch)
        @value = nil
      end
    end

    # The result of computing a JSON diff.
    struct Result
      getter set : Array(SetEntry)
      getter unset : Array(Array(String))

      def initialize(@set = [] of SetEntry, @unset = [] of Array(String))
      end

      # Returns `true` if there are no differences.
      def empty? : Bool
        @set.empty? && @unset.empty?
      end

      # Converts the result to a JSON-compatible representation.
      def to_json(builder : JSON::Builder)
        builder.object do
          builder.field("set") do
            builder.array do
              @set.each do |entry|
                builder.object do
                  builder.field("path") do
                    builder.array { entry.path.each { |key| builder.string(key) } }
                  end
                  if p = entry.patch
                    builder.field("patch") { p.to_json(builder) }
                  else
                    v = entry.value
                    if v.nil?
                      builder.field("value") { builder.null }
                    else
                      builder.field("value", v)
                    end
                  end
                end
              end
            end
          end
          builder.field("unset") do
            builder.array do
              @unset.each do |path|
                builder.array { path.each { |key| builder.string(key) } }
              end
            end
          end
        end
      end

      # Converts the result to a JSON string.
      def to_json : String
        JSON.build { |builder| to_json(builder) }
      end

      # Parses a `Result` from its JSON representation (as emitted by
      # `#to_json` and stored in a mutation row's `arguments`). Raises on
      # a malformed shape — a corrupt diff in a mutation row must fail
      # loudly, not silently drop edits.
      def self.from_json(diff : JSON::Any) : Result
        set = [] of SetEntry
        (diff["set"]?.try(&.as_a?) || [] of JSON::Any).each do |entry|
          path = entry["path"].as_a.map(&.as_s)
          if entry.as_h.has_key?("patch")
            set << SetEntry.new(path, Patch.from_json(entry["patch"]))
          else
            set << SetEntry.new(path, entry["value"]? || JSON::Any.new(nil))
          end
        end
        unset = (diff["unset"]?.try(&.as_a?) || [] of JSON::Any).map(&.as_a.map(&.as_s))
        Result.new(set, unset)
      end
    end

    # Computes the diff between two JSON values.
    #
    # Returns a `Result` describing what changed from `old` to `new`.
    def self.diff(old : JSON::Any, new : JSON::Any) : Result
      result = Result.new
      compute_diff(old, new, [] of String, result)
      result
    end

    # Returns the set of top-level field names that differ between two
    # documents: fields added or modified, plus fields removed. Shared by
    # the update and action pipelines to decide which computed fields to
    # re-run and which unique constraints to re-check.
    def self.changed_fields(original : JSON::Any, updated : JSON::Any) : Set(String)
      orig_hash = original.as_h
      upd_hash = updated.as_h

      changed = Set(String).new

      # Fields added or modified
      upd_hash.each do |k, v|
        orig_v = orig_hash[k]?
        if orig_v.nil? || orig_v != v
          changed << k
        end
      end

      # Fields removed
      orig_hash.each do |k, _|
        unless upd_hash.has_key?(k)
          changed << k
        end
      end

      changed
    end

    # Recursively computes the diff between two JSON values.
    private def self.compute_diff(
      old : JSON::Any,
      new : JSON::Any,
      prefix : Array(String),
      result : Result,
    ) : Nil
      # If both are objects, compare their keys recursively.
      if old.raw.is_a?(Hash) && new.raw.is_a?(Hash)
        old_obj = old.as_h
        new_obj = new.as_h

        # Keys present in the old but not in the new → unset
        old_obj.each do |key, _|
          unless new_obj.has_key?(key)
            result.unset << (prefix + [key])
          end
        end

        # Keys present in the new but not in the old → set
        new_obj.each do |key, value|
          unless old_obj.has_key?(key)
            result.set << SetEntry.new(prefix + [key], value)
          end
        end

        # Keys present in both → recurse
        new_obj.each do |key, value|
          if old_obj.has_key?(key)
            compute_diff(old_obj[key], value, prefix + [key], result)
          end
        end
      elsif old == new
        # Values are identical → nothing to do
        nil
      else
        # Values differ (or type changed) → emit set
        # For string-to-string diffs on long strings, emit a patch.
        if old.raw.is_a?(String) && new.raw.is_a?(String)
          entry = build_string_set_entry(prefix, old.as_s, new.as_s)
          result.set << entry
        else
          result.set << SetEntry.new(prefix, new)
        end
      end
    end

    # Builds a `SetEntry` for a string-to-string change.
    #
    # - Below `PATCH_THRESHOLD` characters, or if the patch is not smaller
    #   than the full value, fall back to a plain value entry.
    # - Otherwise, compute a line-based patch and emit it.
    # - For type changes involving strings (e.g. number → string), the
    #   patch is never appropriate; this path only triggers for
    #   string → string.
    private def self.build_string_set_entry(
      path : Array(String),
      old_str : String,
      new_str : String,
    ) : SetEntry
      if old_str.size < PATCH_THRESHOLD || new_str.size < PATCH_THRESHOLD
        return SetEntry.new(path, JSON::Any.new(new_str))
      end

      patch = build_line_patch(old_str, new_str)
      if patch.empty? || patch_json_size(patch) >= new_str.size
        return SetEntry.new(path, JSON::Any.new(new_str))
      end

      SetEntry.new(path, patch)
    end

    # Computes the byte size of the JSON representation of a patch.
    # Used to decide whether the patch is actually smaller than the
    # full replacement value.
    private def self.patch_json_size(patch : Patch) : Int32
      patch.to_json.size
    end

    # ── Line-based diffing ──────────────────────────────────────────────

    # Splits a string into lines, preserving the trailing newline on each
    # line (including the last line if it ends with `\n`). A trailing
    # empty string is NOT appended (matching how `String.lines` works
    # without the final empty element). The final entry does not carry
    # a trailing newline when the source didn't end with one.
    private def self.split_lines(str : String) : Array(String)
      return [] of String if str.empty?

      lines = [] of String
      cursor = 0
      while idx = str.index('\n', cursor)
        lines << str[cursor..idx]
        cursor = idx + 1
      end
      if cursor < str.size
        lines << str[cursor..]
      end
      lines
    end

    # Computes a line-based unified patch from `old_str` to `new_str`.
    # Returns an empty `Patch` if there are no changes.
    private def self.build_line_patch(old_str : String, new_str : String) : Patch
      old_lines = split_lines(old_str)
      new_lines = split_lines(new_str)
      ops = lcs_diff(old_lines, new_lines)
      hunks = group_into_hunks(ops)
      Patch.new(hunks)
    end

    # Represents one line operation in a line diff.
    private enum LineOp
      Equal
      Remove
      Add
    end

    # LCS line diff — returns an `Array({LineOp, String})` describing how
    # to transform `old_lines` into `new_lines`. Runs in O(n*m) time and
    # memory on the line count.
    private def self.lcs_diff(old_lines : Array(String), new_lines : Array(String))
      n = old_lines.size
      m = new_lines.size

      # Build the LCS length table.
      # dp[i][j] = LCS length of old_lines[i..] and new_lines[j..]
      dp = Array.new(n + 1) { Array.new(m + 1, 0) }
      (n - 1).step(by: -1, to: 0) do |i|
        (m - 1).step(by: -1, to: 0) do |j|
          if old_lines[i] == new_lines[j]
            dp[i][j] = dp[i + 1][j + 1] + 1
          else
            dp[i][j] = Math.max(dp[i + 1][j], dp[i][j + 1])
          end
        end
      end

      ops = [] of {LineOp, String}
      i = 0
      j = 0
      while i < n && j < m
        if old_lines[i] == new_lines[j]
          ops << {LineOp::Equal, old_lines[i]}
          i += 1
          j += 1
        elsif dp[i + 1][j] >= dp[i][j + 1]
          ops << {LineOp::Remove, old_lines[i]}
          i += 1
        else
          ops << {LineOp::Add, new_lines[j]}
          j += 1
        end
      end
      while i < n
        ops << {LineOp::Remove, old_lines[i]}
        i += 1
      end
      while j < m
        ops << {LineOp::Add, new_lines[j]}
        j += 1
      end
      ops
    end

    # Returns the number of Equal ops contiguous from `from` (inclusive)
    # up to `to` or until a non-Equal op is encountered.
    private def self.count_leading_equals(
      ops : Array({LineOp, String}),
      from : Int32,
      limit : Int32 = Int32::MAX,
    ) : Int32
      count = 0
      i = from
      while i < ops.size && ops[i][0] == LineOp::Equal && count < limit
        count += 1
        i += 1
      end
      count
    end

    # Walks `ops` from index 0 up to (but not including) `end_idx`,
    # accumulating old/new line positions.
    private def self.line_positions_at(
      ops : Array({LineOp, String}),
      end_idx : Int32,
    ) : {Int32, Int32}
      old_pos = 0
      new_pos = 0
      (0...end_idx).each do |i|
        case ops[i][0]
        when .equal?
          old_pos += 1
          new_pos += 1
        when .remove?
          old_pos += 1
        when .add?
          new_pos += 1
        end
      end
      {old_pos, new_pos}
    end

    # Builds the serialized hunk lines (with ` `/`-`/`+` prefixes) for
    # ops in `[pre_start, post_end)`, returning `{lines, old_count, new_count}`.
    private def self.build_hunk_lines(
      ops : Array({LineOp, String}),
      pre_start : Int32,
      post_end : Int32,
    ) : {Array(String), Int32, Int32}
      lines = [] of String
      old_count = 0
      new_count = 0
      (pre_start...post_end).each do |i|
        op, line = ops[i]
        case op
        when .equal?
          lines << " " + line
          old_count += 1
          new_count += 1
        when .remove?
          lines << "-" + line
          old_count += 1
        when .add?
          lines << "+" + line
          new_count += 1
        end
      end
      {lines, old_count, new_count}
    end

    # Computes the 1-based `{old_start, new_start}` for a hunk window
    # beginning at op index `pre_start`, with `old_count` lines consumed
    # on the old side and `new_count` on the new side.
    private def self.hunk_starts(
      ops : Array({LineOp, String}),
      pre_start : Int32,
      old_count : Int32,
      new_count : Int32,
    ) : {Int32, Int32}
      old_pos, new_pos = line_positions_at(ops, pre_start)
      # 1-based start for the first line in the hunk window.
      old_start = old_count == 0 ? old_pos : old_pos + 1
      new_start = new_count == 0 ? new_pos : new_pos + 1
      {old_start, new_start}
    end

    # Groups a flat list of line operations into unified-diff hunks with
    # `CONTEXT_LINES` lines of context around each changed region.
    # Two change regions separated by fewer than `2*CONTEXT_LINES + 1`
    # equal lines are merged into one hunk (matches git's behavior).
    private def self.group_into_hunks(
      ops : Array({LineOp, String}),
    ) : Array(Hunk)
      hunks = [] of Hunk
      idx = 0
      while idx < ops.size
        # Skip leading equals.
        if ops[idx][0] == LineOp::Equal
          idx += 1
          next
        end

        # Extend the change region through non-Equal ops and short Equal
        # gaps that should merge into this hunk.
        change_start = idx
        while idx < ops.size
          if ops[idx][0] != LineOp::Equal
            idx += 1
            next
          end
          # Equal gap: decide whether to merge the next change region
          # or terminate the hunk here.
          gap_len = count_leading_equals(ops, idx)
          if gap_len >= 2 * CONTEXT_LINES + 1
            break # gap is large enough to split hunks
          end
          idx += gap_len
        end
        changes_end = idx

        old_pos, _new_pos = line_positions_at(ops, change_start)
        # Preceding context.
        ctx_before = Math.min(CONTEXT_LINES, old_pos)
        pre_start = change_start - ctx_before
        # Trailing context.
        trailing = count_leading_equals(ops, changes_end, CONTEXT_LINES)
        post_end = changes_end + trailing

        hunk_lines, old_count, new_count = build_hunk_lines(ops, pre_start, post_end)
        old_start, new_start = hunk_starts(ops, pre_start, old_count, new_count)

        hunks << Hunk.new(
          old_start: old_start,
          old_count: old_count,
          new_start: new_start,
          new_count: new_count,
          lines: hunk_lines,
        )
        idx = post_end
      end

      hunks
    end

    # ── Patch application (Crystal mirror) ──────────────────────────────

    # Applies a `Patch` to an old string, producing the new string.
    # Raises `ArgumentError` if any context or removed line does not
    # match the old string (cheap correctness check so a stale patch
    # fails loudly rather than producing garbage).
    def self.apply_patch(old_str : String, patch : Patch) : String
      old_lines = split_lines(old_str)
      out_lines = [] of String
      old_idx = 0

      patch.hunks.each do |hunk|
        # Validate / skip unchanged lines before the hunk.
        # `hunk.old_start` is 1-based; convert to 0-based index.
        # For pure insertions (old_count == 0), old_start points at the
        # line *after* which to insert (0 means before line 1).
        target_idx = hunk.old_count == 0 ? hunk.old_start : hunk.old_start - 1

        if target_idx < old_idx
          raise ArgumentError.new(
            "Patch hunk out of order: old_start #{hunk.old_start} moves backwards"
          )
        end

        # Copy unchanged lines up to the hunk.
        while old_idx < target_idx
          if old_idx >= old_lines.size
            raise ArgumentError.new(
              "Patch hunk old_start #{hunk.old_start} exceeds old line count #{old_lines.size}"
            )
          end
          out_lines << old_lines[old_idx]
          old_idx += 1
        end

        # Apply each line of the hunk.
        hunk_lines = hunk.lines
        hunk_lines.each do |raw|
          marker = raw[0]?
          content = raw.size > 1 ? raw[1..] : ""
          case marker
          when ' '
            validate_old_line(old_lines, old_idx, content, hunk)
            out_lines << content
            old_idx += 1
          when '-'
            validate_old_line(old_lines, old_idx, content, hunk)
            old_idx += 1
          when '+'
            out_lines << content
          else
            raise ArgumentError.new(
              "Invalid patch line marker #{marker.inspect} in hunk at old_start #{hunk.old_start}"
            )
          end
        end
      end

      # Copy remaining lines after the last hunk.
      while old_idx < old_lines.size
        out_lines << old_lines[old_idx]
        old_idx += 1
      end

      out_lines.join
    end

    # Inverts a patch: applying the result to `apply_patch(s, p)` returns
    # `s`. Each hunk swaps `old_start`/`new_start`, `old_count`/`new_count`,
    # and the `-`/`+` markers on every line (context lines unchanged). The
    # count-swapped starts keep the position conventions intact: a pure
    # insertion (`old_count = 0`) inverts to a pure deletion whose start
    # stays in the "line after which" form, and vice versa.
    #
    # Used by diff composition (`compose`) to recover a pre-edit value
    # from the middle content without hunk algebra.
    def self.invert(patch : Patch) : Patch
      hunks = patch.hunks.map do |h|
        lines = h.lines.map do |raw|
          marker = raw[0]?
          case marker
          when '-'
            "+#{raw.size > 1 ? raw[1..] : ""}"
          when '+'
            "-#{raw.size > 1 ? raw[1..] : ""}"
          else
            raw
          end
        end
        Hunk.new(
          old_start: h.new_start,
          old_count: h.new_count,
          new_start: h.old_start,
          new_count: h.old_count,
          lines: lines,
        )
      end
      Patch.new(hunks)
    end

    # Validates that `old_lines[old_idx]` matches `expected`, raising
    # `ArgumentError` (with context) on mismatch.
    private def self.validate_old_line(
      old_lines : Array(String),
      old_idx : Int32,
      expected : String,
      hunk : Hunk,
    ) : Nil
      if old_idx >= old_lines.size
        raise ArgumentError.new(
          "Patch hunk at old_start #{hunk.old_start} expects line #{old_idx + 1} but old text has only #{old_lines.size} lines"
        )
      end
      actual = old_lines[old_idx]
      if actual != expected
        raise ArgumentError.new(
          "Patch context mismatch at old line #{old_idx + 1}: expected #{expected.inspect} but got #{actual.inspect}"
        )
      end
    end

    # ── Diff composition ───────────────────────────────────────────────

    # Composes two consecutive diffs: `first` maps `X → Y`, `second` maps
    # `Y → Z`; the returned result maps `X → Z` directly. Write-time
    # coalescing stores the composed diff on the merged mutation row, so a
    # replay from any earlier state lands on `Z` (see
    # `doc/backend/mutation.md` → Write-time coalescing).
    #
    # `middle` is the content between the two writes (`Y` — the projection
    # content before the second write). It is required only when both diffs
    # patch the same path; the composition then recovers `X.P` by inverting
    # the first patch against `Y.P` and re-diffs `X.P → Z.P` through the
    # normal differ, so hunk grouping stays consistent. Raises
    # `ArgumentError` when a patch∘patch path arises with a `nil` `middle`
    # or a non-string value at the path — a programming error, since the
    # only caller always holds the middle content.
    #
    # Entry order in the composed `set` array is application order:
    # `first`'s untouched entries precede `second`'s entries, so a prefix
    # relation between paths (a whole-subtree set in one diff, a nested set
    # in the other) applies sequentially, exactly as the two original
    # writes did.
    def self.compose(first : Result, second : Result, middle : JSON::Any?) : Result
      touched = Set(Array(String)).new
      second.set.each { |entry| touched << entry.path }
      second.unset.each { |path| touched << path }

      set = [] of SetEntry
      unset = [] of Array(String)

      # first's entries that second does not touch (exact path) — kept as-is.
      first.set.each do |entry|
        set << entry unless touched.includes?(entry.path)
      end
      first.unset.each do |path|
        unset << path unless touched.includes?(path)
      end

      # second's entries, merged with first's where the paths match.
      second.set.each do |entry|
        set << compose_entry(first, entry, middle)
      end
      unset.concat(second.unset)

      Result.new(set, unset)
    end

    # Composes one `second` set entry with `first`'s entry for the same
    # path (when present), per the composition table:
    #
    # | second's entry | first's entry | composed |
    # | --- | --- | --- |
    # | unset path P | — | `unset P` |
    # | set P to a literal | — | `set P = value` (second wins) |
    # | patch P | absent or unset | keep second's patch (`X.P = Y.P`) |
    # | patch P | literal V | `set P = apply_patch(V, patch)` — a literal |
    # | patch P | patch | invert first against middle, re-diff `X.P → Z.P` |
    def self.compose_entry(first : Result, second_entry : SetEntry, middle : JSON::Any?) : SetEntry
      first_entry = first.set.find { |e| e.path == second_entry.path }

      second_patch = second_entry.patch
      return second_entry unless second_patch

      first_value = first_entry.try(&.value)
      if first_value
        # Y.P is the literal first set — apply the second patch to it.
        unless str = first_value.as_s?
          raise ArgumentError.new(
            "Cannot compose a text patch at path #{second_entry.path}: the previous diff set a non-string value"
          )
        end
        return SetEntry.new(second_entry.path, JSON::Any.new(apply_patch(str, second_patch)))
      end

      first_patch = first_entry.try(&.patch)
      unless first_patch
        # first did not touch P (or unset it — unreachable via the differ
        # because a removed base forces a literal): X.P = Y.P, so the
        # second patch applies to the base unchanged.
        return second_entry
      end

      # patch ∘ patch: recover X.P by inverting the first patch against
      # Y.P, then let the differ decide patch vs literal for X.P → Z.P.
      middle_value = middle
      unless middle_value
        raise ArgumentError.new(
          "Cannot compose patch over patch at path #{second_entry.path}: the middle content is required"
        )
      end
      middle_at = dig_at_path(middle_value, second_entry.path)
      unless middle_at && (y_str = middle_at.as_s?)
        raise ArgumentError.new(
          "Cannot compose patch over patch at path #{second_entry.path}: no string at the path in the middle content"
        )
      end
      x_str = apply_patch(y_str, invert(first_patch))
      z_str = apply_patch(y_str, second_patch)
      build_string_set_entry(second_entry.path, x_str, z_str)
    end

    # ── Diff application (Crystal mirror) ───────────────────────────────

    # Applies a JsonDiff to a JSON value.
    # Mirrors the PL/pgSQL `jsonb_apply_diff` function. `Audit::Rollback`
    # uses this when it replays `update` mutations in Crystal.
    def self.apply_diff(target : JSON::Any, diff : JSON::Any) : JSON::Any
      result = target

      # Apply "set" entries
      if set_arr = diff["set"]?
        set_arr.as_a.each do |entry|
          path = entry["path"].as_a.map(&.as_s)
          if entry.as_h.has_key?("patch")
            # Line-based patch on an existing string at this path.
            existing = dig_at_path(result, path)
            unless existing && (str = existing.as_s?)
              raise ArgumentError.new(
                "Cannot apply text patch at path #{path}: existing value is not a string"
              )
            end
            patched = apply_patch(str, Patch.from_json(entry["patch"]))
            result = set_at_path(result, path, JSON::Any.new(patched))
          else
            value = entry["value"]
            result = set_at_path(result, path, value)
          end
        end
      end

      # Apply "unset" entries
      if unset_arr = diff["unset"]?
        unset_arr.as_a.each do |entry|
          path = entry.as_a.map(&.as_s)
          result = unset_at_path(result, path)
        end
      end

      result
    end

    # Walks a JSON tree following a path of keys, returning the value
    # at that path or `nil` if any segment is missing.
    private def self.dig_at_path(target : JSON::Any, path : Array(String)) : JSON::Any?
      current = target
      path.each do |key|
        h = current.as_h?
        return nil if h.nil?
        return nil unless h.has_key?(key)
        current = h[key]
      end
      current
    end

    # Sets a value at a nested path in a JSON tree.
    # Creates intermediate objects as needed.
    private def self.set_at_path(target : JSON::Any, path : Array(String), value : JSON::Any) : JSON::Any
      if path.empty?
        return value
      end

      obj = target.as_h?
      return target if obj.nil?

      key = path.first
      rest = path[1..]

      if rest.empty?
        new_h = obj.dup
        new_h[key] = value
        return JSON::Any.new(new_h)
      end

      existing = obj[key]?
      nested = existing || JSON::Any.new({} of String => JSON::Any)
      new_h = obj.dup
      new_h[key] = set_at_path(nested, rest, value)
      JSON::Any.new(new_h)
    end

    # Removes a key at a nested path in a JSON tree.
    private def self.unset_at_path(target : JSON::Any, path : Array(String)) : JSON::Any
      if path.empty?
        return target
      end

      obj = target.as_h?
      return target if obj.nil?

      key = path.first
      rest = path[1..]

      unless obj.has_key?(key)
        return target
      end

      new_h = obj.dup

      if rest.empty?
        new_h.delete(key)
        return JSON::Any.new(new_h)
      end

      existing = obj[key]
      new_h[key] = unset_at_path(existing, rest)
      JSON::Any.new(new_h)
    end
  end
end
