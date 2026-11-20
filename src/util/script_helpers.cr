# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../config"
require "../event"
require "./redirect_uri"

module Facet
  module Util
    # Crystal-backed safe functions exposed to doctype Lua scripts
    # as the `util.*`, `date.*`, and `math.clamp` globals.
    module ScriptHelpers
      # ---- crockford base32 (used by ULID) --------------------------------

      CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

      # ── App hosting: reserved hosts + host shape ──────────────────────

      # Shape rule for the `app.App` `host` field: a bare lowercase hostname —
      # no scheme, no port, no path, no wildcard characters, dot-separated
      # labels of alphanumerics and inner hyphens, single labels (`localhost`)
      # allowed. The deployment target supplies the port at serve time, so a
      # stored host must not carry one (B-211 — the dispatcher matches the
      # port-stripped request hostname exactly, and a port-bearing host could
      # never match). Enforced in the app.App create/update Lua hook through
      # the `util.valid_hostname` binding (the rule is not expressible in
      # Lua patterns).
      HOST_PATTERN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/

      # Upper bound of the RFC 1034 hostname length.
      HOST_MAX_LENGTH = 253

      # True for a bare lowercase hostname — no scheme, port, path, or
      # wildcard — at most 253 characters; the `app.App` `host` shape rule.
      def self.valid_hostname?(value : String) : Bool
        return false if value.empty? || value.size > HOST_MAX_LENGTH
        HOST_PATTERN.matches?(value)
      end

      # ── OAuth redirect URIs ──────────────────────────────────────────

      # Shape rule for one entry of the `app.App` `redirect_uris` field —
      # the shared `Util::RedirectUri` rule (the single source of truth;
      # `OAuth::RedirectUri` and the register endpoint use it too):
      # absolute `https` on any host, or absolute `http` on a loopback host
      # (`localhost`, any `*.localhost` subdomain, `127.0.0.1`, `::1`); no
      # fragment, no userinfo, no query, host required. The only permitted
      # wildcard is a `*` port, and only on an `http` loopback host
      # (RFC 8252 — the OS assigns the local listener's port, so the CLI
      # cannot pin it). A `*` anywhere else — scheme, host, path — is
      # rejected. Enforced in the app.App create/update Lua hook through
      # the `util.valid_redirect_uri` binding (the parse is not
      # expressible in Lua patterns).
      def self.valid_redirect_uri?(value : String) : Bool
        RedirectUri.valid_shape?(value)
      end

      # ── OIDC provider fields ─────────────────────────────────────

      # Shape rule for the `iam.OIDCProvider` `issuer` field: an absolute
      # https URL with a host. Enforced in the provider's create/update
      # Lua hook through the `util.valid_https_url` binding (the parse is
      # not expressible in Lua patterns). Mirrors the load-time check the
      # removed `iam.oidc` config section used to run.
      def self.valid_https_url?(value : String) : Bool
        uri = URI.parse(value)
        uri.scheme == "https" && !uri.host.nil? && !uri.host.try(&.empty?)
      rescue
        false
      end

      # Shape rule for the `iam.OIDCProvider` `issuer` field (B-329): an
      # absolute https URL, or plain `http` on a loopback host — the same
      # scheme-follows-host carve-out as the redirect-URI rule (B-154).
      # The loopback never leaves the machine, so a dev/e2e mock IdP can
      # register without TLS; the parse rides the shared `RedirectUri` rule,
      # which also rejects a query or fragment in the issuer (RFC 8414).
      # Enforced in the provider's create/update Lua hook through the
      # `util.valid_issuer_url` binding. Kept separate from
      # `valid_https_url?` so the webhook scheme rule (B-77) stays strict.
      def self.valid_issuer_url?(value : String) : Bool
        parsed = RedirectUri.parse(value) || return false
        parsed.scheme == "https" || (parsed.scheme == "http" && RedirectUri.loopback_host?(parsed.host))
      rescue
        false
      end

      # True when a tombstoned `iam.OIDCProvider` still holds `name`. The
      # provider's create hook refuses such a name: tombstones keep their
      # content until the prune window, and the account links join on the
      # provider name — recreating the name against a different issuer
      # would silently re-authenticate every existing link under the new
      # IdP. Exposed through the `util.oidc_name_tombstoned` binding.
      def self.oidc_name_tombstoned?(db : DB::Connection, name : String) : Bool
        !db.query_one?("SELECT 1 FROM projections WHERE domain = 'iam' AND doc_type = 'OIDCProvider' " \
                       "AND deleted_at IS NOT NULL AND content->>'name' = $1 LIMIT 1", name, as: Int32).nil?
      end

      # ── Webhook authoring vocabulary ──────────────────────────────

      # The closed event-name vocabulary for the `core.Webhook` `events`
      # field. Sourced from the `Facet::Event` constants — the names the
      # publisher and `Cron::WebhookReconcile.derive_event_name` use — so
      # authoring validation cannot drift from dispatch. Exposed to Lua
      # through the `util.webhook_event_names` binding; the webhook
      # create/update hooks check every `events` entry against this list
      # and reject an unknown name with 422 (B-152 — a name outside the
      # list would create a binding that silently never fires).
      def self.webhook_event_names : Array(String)
        ::Facet::Event::WEBHOOK_EVENT_NAMES
      end

      # True when the named role's `connectivity` array carries the channel.
      # The read semantics behind the `util.role_has_channel` Lua binding
      # (the `core.Webhook` authoring gate):
      #
      # - **No matching role projection → true.** An authenticated actor's
      #   active role always has a live projection — the auth layer loads
      #   the role content before any hook runs — so this branch is
      #   reachable only from fixtures that build in-memory roles. The
      #   delivery-time gate (`Webhook::AuthCheck`) fails closed on the
      #   same state (`RoleDeleted`), so a webhook authored here can never
      #   fire.
      # - **Present role, missing or malformed `connectivity` → false.**
      #   Fail closed: a role whose list cannot be read carries no
      #   channels.
      # - **Otherwise** → whether the list names the channel.
      #
      # The lookup accepts both role identifier forms: the qualified
      # projection id (`iam.Roles.admin`) and the bare content name
      # (`admin`). `ctx.actor.role_id` is `RBAC::ActiveRole.role_id` — the
      # role content's `name` — so a live HTTP caller arrives with the
      # bare form; matching only the projection id would hit the
      # missing-projection branch and pass every real role (the B-188
      # inertness). The bare name resolves through the content `name`,
      # which the `iam.Roles` hooks keep equal to the id suffix.
      def self.role_has_channel?(db : DB::Connection, role_id : String, channel : String) : Bool
        row = db.query_one?("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' " \
                            "AND id = $1 AND deleted_at IS NULL", role_id, as: JSON::Any?)
        if row.nil?
          row = db.query_one?("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' " \
                              "AND content->>'name' = $1 AND deleted_at IS NULL LIMIT 1", role_id, as: JSON::Any?)
        end
        return true if row.nil?

        channels = row["connectivity"]?.try(&.as_a?) || return false
        channels.any?(&.as_s?.try(&.==(channel)))
      end

      # Loopback literals Facet itself answers at. Internal callers reach
      # the backend by IP — the frontend SSR `handleFetch` rewrites requests
      # to `BACKEND_URL`, so the Host header carries `127.0.0.1:<port>` —
      # and `HTTP::Request#hostname` strips the port. The bare literals
      # must fall through to the main router, and no app may claim them.
      # Appended after the configured hosts so `facet_hosts.first` stays
      # the configured host.
      LOOPBACK_HOSTS = ["127.0.0.1", "::1"]

      # Internal service hostnames the containerized stacks use for the
      # backend upstream (`http://backend:3000`). Forwarded requests then
      # carry `Host: backend` — the compose service name, not a loopback
      # literal and not a configured Facet host. Reserving it keeps the
      # app-host dispatcher's fall-through honest in those stacks, and no
      # app may claim the name that resolves to Facet's own backend there.
      SERVICE_HOSTS = ["backend"]

      # The host set Facet itself answers at — what the `app.App` `host`
      # field must never claim. Derived from the existing config keys
      # (`host`, `base_url`, `artifact_base_url`) plus the loopback
      # literals; there is no app_hosting config section. Each value is
      # normalized to a bare lowercase hostname (scheme and port stripped)
      # so the Lua hook can compare it against the submitted host.
      def self.facet_hosts : Array(String)
        config = Facet::Config.instance
        hosts = [
          config.host,
          config.base_url,
          config.artifact_base_url,
        ].compact_map { |raw| normalize_host(raw) }
        (hosts + LOOPBACK_HOSTS + SERVICE_HOSTS).uniq
      end

      # Normalizes a configured URL-or-host value to a bare lowercase
      # hostname: scheme stripped, path fragment dropped, port dropped, one
      # trailing dot dropped. A fully qualified DNS name may carry one
      # trailing dot, and the webhook host check strips it too — both
      # checks must see the same value. IPv6 literals are out of scope for
      # the same reason the host field's shape rule is — app hosts are
      # DNS names.
      def self.normalize_host(raw : String) : String
        host = raw.strip.downcase
        host = host.sub(/^https?:\/\//, "")
        host = host.split('/', 2)[0]
        host = host.split(':', 2)[0]
        host = host[0...-1] if host.ends_with?('.') && host.size > 1
        host
      end

      # Generates a ULID (26-char, Crockford Base32, time-sortable).
      # Mirrors the PG `ulid()` function from `db/migrations/0001_document_store.sql`.
      #
      # Layout (128 bits = 26 chars):
      #   - 10 chars: 48-bit millisecond timestamp (padded with 2 zero low
      #     bits to fill 10 base32 chars)
      #   -  2 chars: 10-bit sub-millisecond (ticks of 1/1024 ms counted from
      #     the current millisecond boundary)
      #   - 14 chars: 70 bits of cryptographic randomness
      # All time math is exact integer arithmetic, and the ms timestamp is
      # floored so the millisecond bucket starts exactly where the sub-ms
      # tick grid wraps. ULIDs issued within the same millisecond sort by
      # creation order at ~1 µs resolution; ties within one tick resolve on
      # random bits. Not strictly ULID-spec compliant (spec mandates 80
      # random bits) but the first 10 chars remain a spec-compliant ms
      # timestamp.
      def self.ulid : String
        # Capture time once so ms and sub-ms derive from the same instant.
        # Integer math only, anchored at the millisecond boundary — mirrors
        # the PG ulid() function exactly.
        t = Time.utc
        unix_ts = t.to_unix_ms
        sub_ms = (t.nanosecond % 1_000_000).to_i64 * 1024 // 1_000_000

        String.build(26) do |io|
          # Timestamp: 48 bits padded to 50 -> 10 base32 chars. Do NOT write
          # the shift as `unix_ts >> (43 - i * 5)`: the last char would shift
          # by -2. Crystal happens to shift left for negative counts, but the
          # PG function does not (it right-shifts by 62), so keep both sides
          # on the explicit padding form below.
          (0..9).each do |i|
            io << CROCKFORD[(((unix_ts << 2) >> (45 - i * 5)) & 31).to_i]
          end

          # 9 crypto-random bytes (72 bits; 70 used). Byte 3 straddles the
          # two 40-bit halves (top 6 bits → first half, bottom 2 → second);
          # the bottom 2 bits of byte 8 are dropped.
          bytes = Random::Secure.random_bytes(9)

          # First 40 bits: sub_ms (10) ‖ top 30 random bits -> 8 base32 chars
          val = (sub_ms << 30) |
                (bytes[0].to_i64 << 22) |
                (bytes[1].to_i64 << 14) |
                (bytes[2].to_i64 << 6) |
                (bytes[3].to_i64 >> 2)
          (0..7).each do |i|
            io << CROCKFORD[((val >> (35 - i * 5)) & 31).to_i]
          end

          # Second 40 bits: bottom 2 bits of byte 3 ‖ bytes 4..7 ‖ top 6 of
          # byte 8 -> 8 base32 chars
          val2 = ((bytes[3] & 0x03).to_i64 << 38) |
                 (bytes[4].to_i64 << 30) |
                 (bytes[5].to_i64 << 22) |
                 (bytes[6].to_i64 << 14) |
                 (bytes[7].to_i64 << 6) |
                 (bytes[8].to_i64 >> 2)
          (0..7).each do |i|
            io << CROCKFORD[((val2 >> (35 - i * 5)) & 31).to_i]
          end
        end
      end

      # SHA-256 hex digest.
      def self.sha256(value : String) : String
        Digest::SHA256.hexdigest(value)
      end

      # Clamp a number between min and max.
      def self.clamp(x : Float64, min : Float64, max : Float64) : Float64
        if x < min
          min
        elsif x > max
          max
        else
          x
        end
      end

      # Returns true for nil, empty string, empty array, empty hash.
      def self.empty?(value : Lua::Engine::Value) : Bool
        case value
        when Nil
          true
        when String
          value.empty?
        when Array(Lua::Engine::Value)
          value.empty?
        when Hash(String, Lua::Engine::Value)
          value.empty?
        else
          false
        end
      end

      # Returns the first non-nil, non-empty value, or nil if none.
      def self.coalesce(values : Array(Lua::Engine::Value)) : Lua::Engine::Value
        values.each do |v|
          unless empty?(v)
            return v
          end
        end
        nil
      end

      # ---- Date helpers ----------------------------------------------------

      # The calendar-date form the `date`, `dateperiod`, and Lua date
      # helpers exchange: four-digit year, zero-padded month and day.
      ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

      # Units accepted by `date_diff` and `date_add`, in the error wording.
      DATE_UNITS = ["second", "minute", "hour", "day", "week", "month", "year"]

      # Units accepted by `date_start_of` and `date_end_of`.
      BOUNDARY_UNITS = ["day", "week", "month", "quarter", "year"]

      # Returns the signed distance from `a` to `b` in `unit`. Two distance
      # families:
      #
      # - **Elapsed** — `second`, `minute`, `hour`, `day`, `week` measure the
      #   physical span between the two instants and may be fractional.
      #   Jul 27 to Aug 6 is 10 days.
      # - **Calendar** — `month`, `year` measure the distance between the
      #   calendar positions and are whole numbers. Jul 27 to Aug 6 crosses
      #   the Aug 1 boundary, so 1 month; Jan 1 to Jan 31 is 0 months. A
      #   caller who needs a fractional distance uses an elapsed unit
      #   (`second` is exact).
      #
      # Both inputs may be a full ISO 8601 datetime (offsets convert to
      # UTC) or a calendar date `YYYY-MM-DD`, read as UTC midnight. Raises
      # `ArgumentError` on an unparseable value or an unknown unit — the
      # Lua binding turns that into a catchable Lua error.
      def self.date_diff(a : String, b : String, unit : String) : Float64
        ta = parse_date!(a, "date.diff")
        tb = parse_date!(b, "date.diff")

        case unit
        when "second" then (tb - ta).total_seconds
        when "minute" then (tb - ta).total_minutes
        when "hour"   then (tb - ta).total_hours
        when "day"    then (tb - ta).total_days
        when "week"   then (tb - ta).total_days / 7
        when "month"  then (tb.year * 12 + tb.month - (ta.year * 12 + ta.month)).to_f
        when "year"   then (tb.year - ta.year).to_f
        else
          raise ArgumentError.new("date.diff: unknown unit '#{unit}' (use #{DATE_UNITS.join(", ")})")
        end
      end

      # Parses `s` as ISO 8601 if it contains a time component (or any
      # `Time.parse_iso8601`-acceptable input). Falls back to the explicit
      # `%Y-%m-%d` format for bare calendar dates — Crystal's
      # `Time.parse_iso8601` rejects date-only strings with `Invalid number
      # at 10`. Bare dates are interpreted as UTC midnight.
      private def self.parse_iso8601_or_date(s : String) : Time
        Time.parse_iso8601(s)
      rescue Time::Format::Error
        Time.parse(s, "%Y-%m-%d", Time::Location::UTC)
      end

      # Parses a value for the date helpers — same inputs as
      # `parse_iso8601_or_date`, normalized to UTC (an offset input keeps
      # its source location, so every component read and boundary
      # computation must see the UTC instant). A failure raises
      # `ArgumentError` with the Lua function name so the binding
      # surfaces a useful, catchable Lua error instead of a raw
      # `Time::Format::Error`.
      private def self.parse_date!(s : String, fn : String) : Time
        parse_iso8601_or_date(s).to_utc
      rescue Time::Format::Error | ArgumentError
        raise ArgumentError.new("#{fn}: not a valid ISO 8601 date or datetime: '#{s}'")
      end

      # Parses a value as a calendar day: any time component truncates to
      # the UTC date's midnight. The `dateperiod` helpers read their
      # bounds through this, so a datetime argument compares by its date.
      private def self.parse_calendar_day!(s : String, fn : String) : Time
        parse_date!(s, fn).at_beginning_of_day
      end

      # Calendar units move by whole months, years, or days — a fractional
      # count has no calendar meaning.
      private def self.whole_units!(n : Float64, unit : String, fn : String) : Int64
        unless n == n.trunc
          raise ArgumentError.new("#{fn}: unit '#{unit}' needs a whole number of units, got #{n}")
        end
        n.to_i64
      end

      # Returns the current UTC time as ISO 8601.
      def self.date_now : String
        Time.utc.to_rfc3339
      end

      # Returns the current UTC calendar date, `YYYY-MM-DD`.
      #
      # The backend computes in UTC end to end — the process pins `TZ=UTC`
      # at boot and storage is tz-naive UTC — so this is the server's
      # "today", the same day every other server-side reader sees. It is
      # not the caller's local calendar day; that conversion is a frontend
      # concern (the `core.timezone` setting). The release image ships no
      # tzdata, so there is no IANA-zone form.
      def self.date_today : String
        Time.utc.to_s("%Y-%m-%d")
      end

      # Adds `n` units to an ISO 8601 date or datetime. Date in → date
      # out; datetime in → UTC RFC-3339 out (whole seconds, the stored
      # form). `month` and `year` clamp the day to the target month's
      # length (Jan 31 + 1 month = Feb 28) and need a whole `n`; the
      # elapsed units take fractions on a datetime. A calendar date moves
      # by whole units only, and the sub-day units raise — a calendar
      # date has no time component. Negative `n` subtracts.
      def self.date_add(iso : String, n : Float64, unit : String) : String
        t = parse_date!(iso, "date.add")

        if ISO_DATE_PATTERN.matches?(iso)
          add_to_calendar_date(t, n, unit).to_s("%Y-%m-%d")
        else
          add_to_datetime(t, n, unit).to_rfc3339
        end
      end

      # Calendar-date branch of `date_add`: the result stays a calendar
      # date, so every unit moves by whole units and the sub-day units
      # have no meaning.
      private def self.add_to_calendar_date(t : Time, n : Float64, unit : String) : Time
        case unit
        when "day"   then t + whole_units!(n, unit, "date.add").days
        when "week"  then t + (whole_units!(n, unit, "date.add") * 7).days
        when "month" then t.shift(months: whole_units!(n, unit, "date.add"))
        when "year"  then t.shift(years: whole_units!(n, unit, "date.add"))
        when "second", "minute", "hour"
          raise ArgumentError.new("date.add: unit '#{unit}' needs a datetime — a calendar date has no time component")
        else
          raise ArgumentError.new("date.add: unknown unit '#{unit}' (use #{DATE_UNITS.join(", ")})")
        end
      end

      # Datetime branch of `date_add`: the elapsed units take fractional
      # counts; `month` and `year` need whole numbers.
      private def self.add_to_datetime(t : Time, n : Float64, unit : String) : Time
        case unit
        when "second" then t + n.seconds
        when "minute" then t + n.minutes
        when "hour"   then t + n.hours
        when "day"    then t + n.days
        when "week"   then t + (n * 7).days
        when "month"  then t.shift(months: whole_units!(n, unit, "date.add"))
        when "year"   then t.shift(years: whole_units!(n, unit, "date.add"))
        else
          raise ArgumentError.new("date.add: unknown unit '#{unit}' (use #{DATE_UNITS.join(", ")})")
        end
      end

      # First day or instant of the `unit` containing the value — `day`,
      # `week` (Monday, ISO-8601), `month`, `quarter`, or `year`. Date in
      # → date out; datetime in → UTC RFC-3339 out.
      def self.date_start_of(iso : String, unit : String) : String
        t = parse_date!(iso, "date.start_of")

        started = case unit
                  when "day"     then t.at_beginning_of_day
                  when "week"    then t.at_beginning_of_week
                  when "month"   then t.at_beginning_of_month
                  when "quarter" then Time.utc(t.year, ((t.month - 1) // 3) * 3 + 1, 1)
                  when "year"    then t.at_beginning_of_year
                  else
                    raise ArgumentError.new("date.start_of: unknown unit '#{unit}' (use #{BOUNDARY_UNITS.join(", ")})")
                  end

        ISO_DATE_PATTERN.matches?(iso) ? started.to_s("%Y-%m-%d") : started.to_rfc3339
      end

      # Last day or instant of the `unit` containing the value. For a
      # calendar date the result is the unit's last day. For a datetime it
      # is the unit's last whole second (`23:59:59Z`) — the form a display
      # string expects. A `[)` `period` bound should instead use the next
      # unit's `date.start_of`, which excludes nothing.
      def self.date_end_of(iso : String, unit : String) : String
        t = parse_date!(iso, "date.end_of")

        ended = case unit
                when "day"     then t.at_end_of_day
                when "week"    then t.at_end_of_week
                when "month"   then t.at_end_of_month
                when "quarter" then Time.utc(t.year, ((t.month - 1) // 3) * 3 + 3, 1).at_end_of_month
                when "year"    then t.at_end_of_year
                else
                  raise ArgumentError.new("date.end_of: unknown unit '#{unit}' (use #{BOUNDARY_UNITS.join(", ")})")
                end

        if ISO_DATE_PATTERN.matches?(iso)
          ended.to_s("%Y-%m-%d")
        else
          Time.utc(ended.year, ended.month, ended.day, 23, 59, 59).to_rfc3339
        end
      end

      # Components of an ISO 8601 date or datetime in UTC. `weekday` is
      # ISO-8601: Monday = 1 … Sunday = 7 (Crystal's `DayOfWeek` values
      # already follow that convention). Time fields are zero for a
      # calendar date.
      def self.date_parts(iso : String) : {year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32, second: Int32, weekday: Int32}
        t = parse_date!(iso, "date.parts")
        {
          year:    t.year,
          month:   t.month,
          day:     t.day,
          hour:    t.hour,
          minute:  t.minute,
          second:  t.second,
          weekday: t.day_of_week.value,
        }
      end

      # True when two `[)` datetime ranges — the `period` field shape —
      # share an instant. Touching ranges (one ends where the other
      # starts) do not overlap: the exclusive upper bound excludes that
      # instant.
      def self.period_overlaps?(a_start : String, a_end : String, b_start : String, b_end : String) : Bool
        fn = "date.period_overlaps"
        as_ = parse_date!(a_start, fn)
        ae = parse_date!(a_end, fn)
        bs = parse_date!(b_start, fn)
        be = parse_date!(b_end, fn)
        as_ < be && bs < ae
      end

      # True when `x` falls inside a `[)` datetime range: start included,
      # end excluded.
      def self.period_contains?(p_start : String, p_end : String, x : String) : Bool
        fn = "date.period_contains"
        ps = parse_date!(p_start, fn)
        pe = parse_date!(p_end, fn)
        px = parse_date!(x, fn)
        ps <= px && px < pe
      end

      # True when two calendar-date ranges — the `dateperiod` field shape,
      # inclusive on both ends — share a day. Touching ranges (one ends
      # the day the other starts) DO overlap: both bounds include their
      # day. Datetime arguments compare by their UTC date.
      def self.dateperiod_overlaps?(a_start : String, a_end : String, b_start : String, b_end : String) : Bool
        fn = "date.dateperiod_overlaps"
        as_ = parse_calendar_day!(a_start, fn)
        ae = parse_calendar_day!(a_end, fn)
        bs = parse_calendar_day!(b_start, fn)
        be = parse_calendar_day!(b_end, fn)
        as_ <= be && bs <= ae
      end

      # True when `x` falls inside a calendar-date range, inclusive on
      # both ends. A datetime `x` truncates to its UTC date.
      def self.dateperiod_contains?(p_start : String, p_end : String, x : String) : Bool
        fn = "date.dateperiod_contains"
        ps = parse_calendar_day!(p_start, fn)
        pe = parse_calendar_day!(p_end, fn)
        px = parse_calendar_day!(x, fn)
        ps <= px && px <= pe
      end
    end
  end
end
