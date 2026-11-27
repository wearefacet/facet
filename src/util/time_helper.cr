# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Util
    # Time / timezone helpers.
    #
    # The application stores every timestamp as UTC in tz‑naive PostgreSQL
    # `timestamp` columns (see `doc/backend/workflow.md` → Time / Timezone).
    # These helpers convert ISO‑8601 strings supplied by clients — which may
    # carry a timezone offset — into a canonical UTC RFC‑3339 form before
    # they reach the database or the JSONB content layer, and resolve
    # relative-date filter values (`-7d`, `+1mo6d`, `-20m`, …) against a
    # reference instant.
    module TimeHelper
      # One relative-date component: a magnitude and a unit.
      record RelativeComponent, amount : Int32, unit : Symbol

      # Raised by `parse_relative` when a value looks like a relative date
      # but carries a unit or shape the grammar does not serve.
      class RelativeDateError < Exception
      end

      # The unit letters the relative-date grammar serves, longest first so
      # `mo` is read before `m`. `m` is a **minute**; `mo` is a month.
      RELATIVE_UNITS = [{"mo", :month}, {"y", :year}, {"w", :week}, {"d", :day}, {"h", :hour}, {"m", :minute}, {"s", :second}]

      # The unit letters that only make sense on a datetime (a calendar date
      # has no clock). A relative filter carrying one of these against a
      # `date` field is refused loudly.
      TIME_UNITS = {:hour, :minute, :second}

      # The whole relative-date grammar: an optional sign, then one or more
      # `<digits><unit>` components.
      RELATIVE_RE = /\A([+-])?((?:\d+(?:mo|y|w|d|h|m|s))+)\z/

      # One `<digits><unit>` component, anchored at the cursor.
      RELATIVE_COMPONENT_RE = /\A(\d+)(mo|y|w|d|h|m|s)/

      # Normalizes an ISO‑8601 datetime string to its UTC RFC‑3339 form.
      #
      # Returns `nil` if `value` is not a parseable ISO‑8601 datetime.
      # Callers should fall through to their existing error handling in
      # that case (typically a no‑match clause rather than a 500).
      #
      # Crystal's `Time.parse_iso8601` rejects tz‑naive datetime strings
      # ("2025-01-15T10:30:00" raises `Time::Format::Error`), so every
      # accepted input carries an explicit offset and `.to_utc` is a
      # lossless conversion. Example:
      #
      # ```
      # TimeHelper.to_utc_rfc3339("2025-01-15T10:30:00+02:00")
      # # => "2025-01-15T08:30:00Z"
      # ```
      def self.to_utc_rfc3339(value : String) : String?
        parsed = Time.parse_iso8601(value)
        parsed.to_utc.to_rfc3339
      rescue Time::Format::Error
        nil
      end

      # True when `value` has the shape of the relative-date grammar
      # (`-7d`, `+1mo6d`, `20m`). A string with a relative *prefix* but an
      # unknown unit or a broken component (`-1x`, `-1mo1`) is not a
      # relative date by this test — callers fall through to the ISO‑8601
      # path, which answers no-match, the long-standing contract for a
      # malformed value. Only a well-formed relative value is resolved.
      def self.relative?(value : String) : Bool
        RELATIVE_RE.matches?(value)
      end

      # True when a well-formed relative value carries at least one time
      # unit (`h`, `m`, `s`) — a clock component a calendar date cannot
      # hold. Returns `false` for a value that is not a relative date.
      def self.relative_has_time_unit?(value : String) : Bool
        return false unless relative?(value)
        parse_relative(value).any? { |component| TIME_UNITS.includes?(component.unit) }
      end

      # Parses a relative-date string into its signed components, oldest
      # unit first in the string. The sign applies to the whole string: a
      # leading `-` is "in the past", `+` (or no sign) is "in the future".
      # Raises `RelativeDateError` when `value` is not the grammar.
      #
      # ```
      # TimeHelper.parse_relative("-1mo6d")
      # # => [RelativeComponent.new(-1, :month), RelativeComponent.new(-6, :day)]
      # ```
      def self.parse_relative(value : String) : Array(RelativeComponent)
        match = RELATIVE_RE.match(value)
        raise RelativeDateError.new("'#{value}' is not a relative date") unless match

        sign = match[1]? == "-" ? -1 : 1
        rest = match[2]
        components = [] of RelativeComponent
        while rest.size > 0
          component = RELATIVE_COMPONENT_RE.match(rest)
          raise RelativeDateError.new("'#{value}' has an unknown relative-date unit") unless component
          amount = component[1].to_i? || 0
          # Magnitudes larger than an Int32 second count are meaningless for
          # a filter bound; refuse rather than overflow.
          raise RelativeDateError.new("'#{value}' has a relative-date magnitude out of range") if amount > Int32::MAX
          unit = RELATIVE_UNITS.find! { |(token, _)| token == component[2] }[1]
          components << RelativeComponent.new(sign * amount, unit)
          rest = rest[component[0].size..]
        end
        components
      end

      # Applies a relative-date string to `anchor` (default: now). The
      # result is in UTC. Months and years are **calendar** steps: `-1mo`
      # from March 15 is February 15, whatever February's length; a day
      # that the target month does not hold clamps to that month's last
      # day (Jan 31 - 1mo = Dec 31; Mar 31 - 1mo = Feb 28/29). Weeks, days,
      # hours, minutes and seconds are fixed-length steps.
      #
      # ```
      # TimeHelper.apply_relative("-1mo", anchor: Time.utc(2026, 3, 15))
      # # => 2026-02-15 00:00:00 UTC
      # ```
      def self.apply_relative(value : String, anchor : Time = Time.utc) : Time
        parse_relative(value).reduce(anchor.to_utc) do |time, component|
          shift(time, component.amount, component.unit)
        end
      end

      # Resolves a filter bound: an ISO‑8601 datetime normalizes to UTC
      # RFC‑3339, a well-formed relative date resolves against `anchor`.
      # Returns `nil` when the value is neither.
      def self.resolve_bound(value : String, anchor : Time = Time.utc) : String?
        if relative?(value)
          return apply_relative(value, anchor: anchor).to_rfc3339
        end
        to_utc_rfc3339(value)
      end

      # Moves a resolved bound to the start (`:start`) or the last second
      # (`:end`) of its UTC calendar day. Used to give a relative bound its
      # calendar reading on a day-granular comparison — `__lte` ends the
      # day, `__gt` starts it — without changing the stored form.
      #
      # ```
      # TimeHelper.day_edge("2026-03-08T10:30:00Z", :end)
      # # => "2026-03-08T23:59:59Z"
      # ```
      def self.day_edge(value : String, edge : Symbol) : String
        parsed = Time.parse_iso8601(value).to_utc
        day = Time.utc(parsed.year, parsed.month, parsed.day)
        (edge == :end ? day + 1.day - 1.second : day).to_rfc3339
      rescue Time::Format::Error
        value
      end

      # Shifts `time` by `amount` of `unit`. Extracted so month and year
      # share the calendar clamp.
      private def self.shift(time : Time, amount : Int32, unit : Symbol) : Time
        case unit
        when :year   then shift_months(time, amount * 12)
        when :month  then shift_months(time, amount)
        when :week   then time + amount.weeks
        when :day    then time + amount.days
        when :hour   then time + amount.hours
        when :minute then time + amount.minutes
        when :second then time + amount.seconds
        else              time
        end
      end

      # Adds calendar months, clamping the day to the target month's length
      # so `2026-01-31 - 1mo` lands on `2025-12-31` and `2026-03-31 - 1mo`
      # lands on `2026-02-28`.
      private def self.shift_months(time : Time, months : Int32) : Time
        total = (time.year * 12) + (time.month - 1) + months
        year = total // 12
        month = (total % 12) + 1
        day = Math.min(time.day, days_in_month(year, month))
        Time.utc(year, month, day, time.hour, time.minute, time.second, nanosecond: time.nanosecond)
      end

      # The number of days in `month` of `year` — February follows the
      # Gregorian leap rule.
      private def self.days_in_month(year : Int32, month : Int32) : Int32
        case month
        when 1, 3, 5, 7, 8, 10, 12 then 31
        when 4, 6, 9, 11           then 30
        else
          leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
          leap ? 29 : 28
        end
      end
    end
  end
end
