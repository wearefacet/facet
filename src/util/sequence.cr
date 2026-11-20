# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Sequential identifier generation from a template.
    #
    # Templates use `#` for auto-incrementing digit groups and `{year}`,
    # `{month}`, `{day}` for time-based variables. Variables always reflect
    # the **current** time — when a variable changes (e.g. year rolls over),
    # digit groups to the right of that variable reset to zero.
    #
    # Counter groups start at 1 (not 0) so the first document has a
    # human-friendly "0001" rather than "0000".
    #
    # ```
    # # First document
    # Facet::Util::Sequence.next("INV-{year}-####", nil)
    # # => NextResult("INV-2026-0001", overflow: false)
    #
    # # Subsequent document (same year)
    # Facet::Util::Sequence.next("INV-{year}-####", "INV-2026-0099")
    # # => NextResult("INV-2026-0100", overflow: false)
    #
    # # Year rollover: variable changed, digit groups reset
    # Facet::Util::Sequence.next("INV-{year}-####", "INV-2025-0099")
    # # => NextResult("INV-2026-0001", overflow: false)
    #
    # # Overflow
    # Facet::Util::Sequence.next("INV-#", "INV-9")
    # # => NextResult(nil, overflow: true)
    # ```
    module Sequence
      # Maximum width of a single digit group. Groups wider than this
      # cannot be represented as Int64 during increment.
      MAX_DIGIT_WIDTH = 18

      private enum SegmentType
        Literal
        Variable
        Digits
      end

      private record Segment, type : SegmentType, value : String, width : Int32

      # Result of a `next` call.
      struct NextResult
        # The generated identifier, or nil on overflow.
        getter value : String?

        # True when all digit groups were exhausted.
        getter? overflow : Bool

        def initialize(@value : String?, @overflow : Bool)
        end
      end

      # Generates the next sequential identifier for the given template.
      #
      # Pass `nil` for *current_value* to generate the first identifier
      # (variables filled from `Time.utc`, digit groups set to 1).
      # Pass the previous identifier to generate the next one.
      #
      # Raises `ArgumentError` if the template is invalid (no digit groups,
      # unknown variable, digit group too wide) or if *current_value* does
      # not match the template pattern.
      def self.next(template : String, current_value : String?) : NextResult
        segments = compile(template)

        if current_value.nil?
          value = build_first(segments)
          NextResult.new(value, overflow: false)
        else
          values = match(segments, current_value)
          var_changed, new_values = update_variables_to_current(segments, values)

          if var_changed
            value = rebuild(segments, new_values)
            NextResult.new(value, overflow: false)
          else
            value, overflow = increment(segments, values)
            NextResult.new(value, overflow: overflow)
          end
        end
      end

      # Compiles a template string into an ordered list of segments.
      private def self.compile(template : String) : Array(Segment)
        segments = [] of Segment
        i = 0

        while i < template.size
          case template[i]
          when '#'
            i = parse_digit_group(template, i, segments)
          when '{'
            i = parse_variable(template, i, segments)
          else
            i = parse_literal(template, i, segments)
          end
        end

        unless segments.any? { |s| s.type == SegmentType::Digits }
          raise ArgumentError.new(
            "Template must contain at least one '#' digit group (the auto-increment counter): " \
            "#{template.inspect} (see doc/backend/util-sequence.md)",
          )
        end

        segments
      end

      # Parses a consecutive run of '#' characters as a digit group segment.
      # Returns the new cursor position (past the last '#').
      private def self.parse_digit_group(template : String, start : Int32, segments : Array(Segment)) : Int32
        i = start
        while i < template.size && template[i] == '#'
          i += 1
        end
        width = i - start
        if width > MAX_DIGIT_WIDTH
          raise ArgumentError.new("Digit group width #{width} exceeds maximum #{MAX_DIGIT_WIDTH}")
        end
        segments << Segment.new(SegmentType::Digits, "#" * width, width)
        i
      end

      # Parses a `{variable}` token. Returns the new cursor position.
      private def self.parse_variable(template : String, start : Int32, segments : Array(Segment)) : Int32
        end_idx = template.index('}', start)
        raise ArgumentError.new("Unclosed '{' in template: #{template.inspect}") unless end_idx
        var_name = template[start + 1...end_idx]

        width = case var_name
                when "year"  then 4
                when "month" then 2
                when "day"   then 2
                else
                  raise ArgumentError.new(
                    "Unknown variable {#{var_name}} (valid variables: {year}, {month}, {day}) " \
                    "in template: #{template.inspect}",
                  )
                end

        segments << Segment.new(SegmentType::Variable, "{#{var_name}}", width)
        end_idx + 1
      end

      # Parses literal text until the next '#' or '{'. Returns the new cursor.
      private def self.parse_literal(template : String, start : Int32, segments : Array(Segment)) : Int32
        i = start
        while i < template.size
          break if template[i] == '#' || template[i] == '{'
          i += 1
        end
        segments << Segment.new(SegmentType::Literal, template[start...i], 0)
        i
      end

      # Builds the first identifier: variables from `Time.utc`, digit groups
      # start at 1 (rightmost group set to 1, others zero-filled).
      private def self.build_first(segments : Array(Segment)) : String
        now = Time.utc
        new_values = Array(String).new
        seg_to_cap = build_seg_to_cap(segments)

        segments.each do |seg|
          case seg.type
          when SegmentType::Literal
            # no capture group for literals
          when SegmentType::Variable
            new_values << format_variable(seg.value, now)
          when SegmentType::Digits
            new_values << "0" * seg.width
          end
        end

        # Set the rightmost digit group to 1, others stay at 0.
        set_rightmost_digit_to_one(segments, seg_to_cap, new_values)

        rebuild(segments, new_values)
      end

      # Sets the rightmost digit group value to 1 (padded to width).
      private def self.set_rightmost_digit_to_one(segments : Array(Segment), seg_to_cap : Array(Int32?), new_values : Array(String)) : Nil
        (segments.size - 1).downto(0) do |si|
          if segments[si].type == SegmentType::Digits
            ci = seg_to_cap[si].as(Int32)
            new_values[ci] = "1".rjust(segments[si].width, '0')
            break
          end
        end
      end

      # Formats a variable token to its value at the given time.
      private def self.format_variable(var_name : String, time : Time) : String
        case var_name
        when "{year}"  then time.year.to_s
        when "{month}" then time.month.to_s.rjust(2, '0')
        when "{day}"   then time.day.to_s.rjust(2, '0')
        else
          raise ArgumentError.new("Unknown variable #{var_name}")
        end
      end

      # Matches *current_value* against the template's regex and returns
      # the extracted capture group values (variables and digits, in order).
      private def self.match(segments : Array(Segment), current_value : String) : Array(String)
        regex = String.build do |io|
          io << '^'
          segments.each do |seg|
            case seg.type
            when SegmentType::Literal
              io << Regex.escape(seg.value)
            when SegmentType::Variable, SegmentType::Digits
              io << "(\\d{#{seg.width}})"
            end
          end
          io << '$'
        end

        re = Regex.new(regex)
        md = current_value.match(re)

        unless md
          raise ArgumentError.new("Current value '#{current_value}' does not match template pattern")
        end

        (1..md.size - 1).map { |i| md[i] }.to_a
      end

      # Returns whether any variable segment changed from its stored value
      # to the current time, and a copy of values with variables updated.
      #
      # When a variable changes, all digit groups to the RIGHT of that
      # variable are reset to 1 (rightmost) / 0 (others). This gives a
      # clean counter start when the year/month/day rolls over.
      #
      # Returns `{changed, new_values}`.
      private def self.update_variables_to_current(segments : Array(Segment), values : Array(String)) : {Bool, Array(String)}
        now = Time.utc
        seg_to_cap = build_seg_to_cap(segments)
        new_values = values.dup
        changed = false

        segments.each_with_index do |seg, si|
          next unless seg.type == SegmentType::Variable
          ci = seg_to_cap[si].as(Int32)
          current_val = format_variable(seg.value, now)
          if new_values[ci] != current_val
            new_values[ci] = current_val
            changed = true
            # Reset all digit groups to the right of this variable.
            reset_digits_to_right(si + 1, segments, seg_to_cap, new_values)
          end
        end

        {changed, new_values}
      end

      # Resets digit groups starting from segment index *start_si* to zero,
      # then sets the rightmost digit group to 1.
      private def self.reset_digits_to_right(start_si : Int32, segments : Array(Segment), seg_to_cap : Array(Int32?), new_values : Array(String)) : Nil
        (start_si...segments.size).each do |si|
          if segments[si].type == SegmentType::Digits
            ci = seg_to_cap[si].as(Int32)
            new_values[ci] = "0" * segments[si].width
          end
        end
        set_rightmost_digit_to_one(segments, seg_to_cap, new_values)
      end

      # Builds a segment-index → capture-group-index mapping.
      private def self.build_seg_to_cap(segments : Array(Segment)) : Array(Int32?)
        seg_to_cap = Array(Int32?).new(segments.size, nil)
        cap_idx = 0
        segments.each_with_index do |seg, si|
          unless seg.type == SegmentType::Literal
            seg_to_cap[si] = cap_idx
            cap_idx += 1
          end
        end
        seg_to_cap
      end

      # Increments the digit groups in *values* (rightmost first, with carry).
      # Returns `{nil, true}` on overflow.
      #
      # *values* is indexed by capture-group position (only Variable and Digits
      # segments, not Literals). We build a mapping from segment index to
      # capture-group index so we can look up the right value for each digit
      # segment in the right position.
      private def self.increment(segments : Array(Segment), values : Array(String)) : {String?, Bool}
        seg_to_cap = build_seg_to_cap(segments)
        new_values = values.dup
        carry = true

        # Iterate digit segments right-to-left for carry propagation.
        (segments.size - 1).downto(0) do |si|
          seg = segments[si]
          next unless seg.type == SegmentType::Digits
          ci = seg_to_cap[si].as(Int32)

          current = new_values[ci].to_i64
          current += 1 if carry

          formatted = current.to_s
          if formatted.size > seg.width
            # Overflow: reset this group to zero and carry left.
            new_values[ci] = "0" * seg.width
            carry = true
          else
            new_values[ci] = formatted.rjust(seg.width, '0')
            carry = false
            break
          end
        end

        if carry
          return {nil, true}
        end

        {rebuild(segments, new_values), false}
      end

      # Rebuilds the identifier string from segments and capture-group values.
      private def self.rebuild(segments : Array(Segment), values : Array(String)) : String
        seg_to_cap = build_seg_to_cap(segments)
        String.build do |io|
          segments.each_with_index do |seg, idx|
            case seg.type
            when SegmentType::Literal
              io << seg.value
            else
              io << values[seg_to_cap[idx].as(Int32)]
            end
          end
        end
      end
    end
  end
end
