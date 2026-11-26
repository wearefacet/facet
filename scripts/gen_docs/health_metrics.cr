# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
# Generates site-docs/src/content/docs/reference/health-metrics-names.md from
# the health probe (src/http/healthcheck.cr, with the consumer and loss
# snapshots in src/event/consumer_health.cr and src/event/loss.cr) and the
# metric catalog (src/metrics.cr).
# Run: make gen-docs-health-metrics
#
# Writes the English page and its French twin under
# site-docs/src/content/docs/fr/reference/. The French prose lives in
# scripts/gen_docs/fr_overlay/health-metrics-names.json (see
# doc/site-docs-fr-style.md). Table cells (field paths, metric names,
# meanings) stay verbatim English; only the page prose, headings, and column
# headers translate.
#
# Mechanism: strict anchored extraction. The module cannot compile
# standalone (the healthcheck route drags in the database layer and its
# Kemal routes), so the script reads the source files: every field name
# comes from an anchored extraction — the response literal of
# `GET /Healthcheck`, the `DBPoolStatus` alias, the consumer snapshot
# signature, the loss-counter hash, the live-probe literal, and the
# `Metrics::CATALOG` lines. The script fails loud when an extracted name has
# no meaning row or a meaning row has no extracted name. Metric meanings
# come from the catalog's own help lines. A second check scans `src/**` for
# literal `Metrics.inc` / `Metrics.set` names and requires each one to be in
# Health meanings are declared prose, checked by name only.

require "./fr_overlay"

REPO_ROOT  = File.expand_path("../..", __DIR__)
PAGE_PATHS = {
  "en" => File.join(REPO_ROOT, "site-docs/src/content/docs/reference/health-metrics-names.md"),
  "fr" => File.join(REPO_ROOT, "site-docs/src/content/docs/fr/reference/health-metrics-names.md"),
}

HEALTHCHECK = File.join(REPO_ROOT, "src/http/healthcheck.cr")
CONSUMERS   = File.join(REPO_ROOT, "src/event/consumer_health.cr")
LOSS        = File.join(REPO_ROOT, "src/event/loss.cr")
METRICS     = File.join(REPO_ROOT, "src/metrics.cr")

record Row, path : String, meaning : String
record Metric, name : String, kind : String, meaning : String

HEALTH_ROWS = [
  Row.new("status", "ok when every dependency passes, degraded otherwise; HTTP 200 answers ok, HTTP 503 answers degraded."),
  Row.new("service.env", "The APP_ENV the process boots in."),
  Row.new("service.instance_id", "One instance id per boot; matches the boot log and the shard-lock holders in Redis."),
  Row.new("database.status", "ok when every pool answers the SELECT 1 probe."),
  Row.new("database.error", "The first pool error, when a pool is broken."),
  Row.new("database.pools[].database", "The database entry name from the route table."),
  Row.new("database.pools[].role", "The pool role: rw or ro."),
  Row.new("database.pools[].status", "ok when this pool answers the SELECT 1 probe."),
  Row.new("database.pools[].error", "The error this pool raised, when it is broken."),
  Row.new("redis.status", "ok when Redis answers, in_process under the in-process manager, error when unreachable."),
  Row.new("redis.error", "The Redis error, when the probe fails."),
  Row.new("events.status", "ok, in_process under the in-process manager, or degraded when a consumer reports consecutive failures."),
  Row.new("events.consumers[].name", "The stream consumer group name."),
  Row.new("events.consumers[].consecutive_failures", "Failed loop turns in a row for this consumer."),
  Row.new("events.consumers[].restarts", "Supervised restarts of this consumer since process start."),
  Row.new("events.consumers[].last_success_at", "RFC-3339 time of the consumer's last successful loop turn."),
  Row.new("events.consumers[].last_error", "The last error message this consumer reported."),
  Row.new("event_loss.publish_flush_failures", "Failed publish flushes since process start."),
  Row.new("event_loss.publish_events_dropped", "Events dropped by failed publish flushes since process start."),
  Row.new("event_loss.messages_dropped", "Dispatched messages dropped by handler errors since process start."),
  Row.new("event_lag.max_lag", "Largest consumer-group lag the last lag-check pass observed."),
  Row.new("live.status", "Always ok while the process answers."),
  Row.new("live.uptime_seconds", "Seconds since the process started."),
]

private def esc(text : String) : String
  text.gsub("|", "\\|")
end

# Top-level keys of the main response literal: the `{` line that follows the
# readiness probe's content-type line, up to the `}.to_json` line. Nested
# keys never start a line, so a leading `key:` match is a top-level key.
private def extract_top_keys(lines : Array(String)) : Array(String)
  keys = [] of String
  armed = false
  inside = false
  lines.each do |line|
    if inside
      if line =~ /^\s+([a-z_]+):/
        keys << $1
      end
      if line =~ /^\s*\}\.to_json$/
        return keys
      end
      next
    end
    if armed
      inside = !!(line =~ /^\s*\{$/)
      armed = false
    elsif line.includes?("content_type = \"application/json\"")
      armed = true
    end
  end
  raise "healthcheck.cr: main response literal not found"
end

# The keys of a `key: value, key: value` list: a key starts the list, or
# follows `{`, `(`, or a comma. A `Module::Constant` value never matches,
# because its lowercase run is not at a boundary.
private def boundary_keys(text : String) : Array(String)
  text.scan(/(?:\A|\{|\(|,\s*)([a-z_]+):/).map(&.[1]).uniq!
end

# The literal keys of a `key: {a: ..., b: ...}` entry on one line.
private def literal_keys(lines : Array(String), anchor : String) : Array(String)
  line = lines.find { |l| l.includes?(anchor) && l.includes?("{") }
  raise "healthcheck.cr: no line with anchor '#{anchor}'" unless line
  match = line.match(/#{Regex.escape(anchor)}\s*\{([^}]+)\}/)
  raise "healthcheck.cr: anchor '#{anchor}' carries no literal keys" unless match
  boundary_keys(match[1])
end

# The field names of a one-line NamedTuple type, found by an anchor.
private def named_tuple_fields(path : String, anchor : String) : Array(String)
  lines = File.read_lines(path)
  line = lines.find(&.includes?(anchor))
  raise "#{path}: no line with anchor '#{anchor}'" unless line
  match = line.match(/\(([^)]+)\)/)
  raise "#{path}: anchor '#{anchor}' carries no NamedTuple fields" unless match
  boundary_keys(match[1])
end

# The keys of the loss-counter snapshot hash.
private def loss_keys : Array(String)
  File.read(LOSS).scan(/"([a-z_]+)"\s*=>/).map(&.[1]).uniq!
end

# The fields of the live-probe response literal: the first `.to_json` line
# after the /Healthcheck/live route registration.
private def live_keys(lines : Array(String)) : Array(String)
  start = lines.index(&.includes?("/Healthcheck/live"))
  raise "healthcheck.cr: /Healthcheck/live route not found" unless start
  lines[start..].each do |line|
    next unless line.includes?(".to_json")
    keys = boundary_keys(line)
    raise "healthcheck.cr: live probe literal carries no keys" if keys.empty?
    return keys
  end
  raise "healthcheck.cr: live probe literal not found"
end

# Metric catalog rows: `"name" => MetricMeta.new("kind", "help")`.
private def extract_catalog : Array(Metric)
  metrics = [] of Metric
  File.read_lines(METRICS).each do |line|
    if match = line.match(/"([a-z_0-9]+)"\s*=>\s*MetricMeta\.new\("([a-z]+)",\s*"([^"]+)"\)/)
      metrics << Metric.new(match[1], match[2], match[3])
    elsif line.includes?("MetricMeta.new")
      raise "metrics.cr: unrecognized catalog line: #{line.strip}"
    end
  end
  raise "metrics.cr: the catalog is empty" if metrics.empty?
  metrics
end

# Every literal metric name emitted through Metrics.inc / Metrics.set.
private def emitted_names : Array(String)
  names = [] of String
  Dir.glob("#{REPO_ROOT}/src/**/*.cr").each do |path|
    File.read(path).scan(/Metrics\.(?:inc|set)\(\s*"([a-z_0-9]+)"/) do |match|
      names << match[1]
    end
  end
  names.uniq
end

# ── row-group helpers ────────────────────────────────────────────────────────

private def rows_under(rows : Array(Row), prefix : String) : Array(Row)
  rows.select(&.path.starts_with?("#{prefix}."))
end

# Direct literal children of `prefix`: one-level names without an array
# marker and without deeper nesting.
private def direct_children(rows : Array(Row), prefix : String) : Array(String)
  rows_under(rows, prefix).compact_map do |row|
    rest = row.path[(prefix.size + 1)..]
    first = rest.split('.')[0]
    next nil if first.includes?('[')
    first if rest == first
  end.uniq!
end

# Array children of `prefix`: the `name[]` marker segments.
private def array_children(rows : Array(Row), prefix : String) : Array(String)
  rows_under(rows, prefix).compact_map do |row|
    rest = row.path[(prefix.size + 1)..]
    first = rest.split('.')[0]
    first.ends_with?("[]") ? first[..-3] : nil
  end.uniq!
end

# Leaf names under `prefix[]` rows.
private def leaf_children(rows : Array(Row), prefix : String) : Array(String)
  marker = "#{prefix}[]"
  rows.select(&.path.starts_with?("#{marker}."))
    .compact_map do |row|
      rest = row.path[(marker.size + 1)..]
      rest unless rest.includes?('.')
    end.uniq!
end

private def check(label : String, declared : Array(String), extracted : Array(String)) : Nil
  d = declared.sort
  e = extracted.sort
  return if d == e
  missing = (e - d).sort
  extra = (d - e).sort
  raise "Health probe drift (#{label}): extracted names with no row: #{missing.join(", ")}; " \
        "rows for names the code does not hold: #{extra.join(", ")}"
end

private def check_health_rows : Nil
  lines = File.read_lines(HEALTHCHECK)
  top_keys = extract_top_keys(lines)
  service = literal_keys(lines, "service:")
  database = literal_keys(lines, "database:")
  redis = literal_keys(lines, "redis:")
  events = literal_keys(lines, "events:")
  lag = literal_keys(lines, "event_lag:")
  pools = named_tuple_fields(HEALTHCHECK, "DBPoolStatus = NamedTuple(")
  consumers = named_tuple_fields(CONSUMERS, "def self.snapshot : Array(NamedTuple(")
  loss = loss_keys
  live = live_keys(lines)

  live_rows = HEALTH_ROWS.select(&.path.starts_with?("live."))
  main_rows = HEALTH_ROWS - live_rows

  check("top-level", main_rows.map(&.path.split('.')[0]).uniq!, top_keys)
  check("service", direct_children(main_rows, "service"), service)
  check("database scalars", direct_children(main_rows, "database"), database - ["pools"])
  check("database pools array", array_children(main_rows, "database"), ["pools"])
  check("database pools fields", leaf_children(main_rows, "database.pools"), pools)
  check("redis", direct_children(main_rows, "redis"), redis)
  check("events scalars", direct_children(main_rows, "events"), events - ["consumers"])
  check("events consumers array", array_children(main_rows, "events"), ["consumers"])
  check("events consumers fields", leaf_children(main_rows, "events.consumers"), consumers)
  check("event_loss", direct_children(main_rows, "event_loss"), loss)
  check("event_lag", direct_children(main_rows, "event_lag"), lag)
  check("live probe", live_rows.map(&.path["live.".size..]), live)
end

private def check_metric_emissions(catalog : Array(Metric)) : Nil
  known = catalog.map(&.name).to_set
  unknown = emitted_names.reject { |name| known.includes?(name) }.sort!
  unless unknown.empty?
    raise "Metrics emitted but missing from the catalog: #{unknown.join(", ")}"
  end
end

private def generate : Nil
  check_health_rows
  catalog = extract_catalog
  check_metric_emissions(catalog)

  live_rows = HEALTH_ROWS.select(&.path.starts_with?("live."))
  main_rows = (HEALTH_ROWS - live_rows).sort_by(&.path)
  probe_rows = (main_rows + live_rows).map do |row|
    "| `#{esc(row.path)}` | #{esc(row.meaning)} |"
  end
  metric_rows = catalog.sort_by(&.name).map do |metric|
    "| `#{esc(metric.name)}` | #{metric.kind} | #{esc(metric.meaning)} |"
  end

  # Front-matter and body reproduce the committed English page byte for byte:
  # the sidebar block and the pinned verified_at change only on re-verification.
  en_body = <<-MARKDOWN
  ---
  title: Health and metrics names
  description: Every health probe field and metric name the server exposes.
  audience: [operator]
  features: [PLT-06, PLT-07]
  type: reference
  sidebar:
    order: 17
  verified_at: 008dd880
  ---

  > Generated from `src/http/healthcheck.cr`, `src/event/loss.cr`, `src/event/consumer_health.cr`, and `src/metrics.cr` by `make gen-docs-health-metrics`. Do not edit this file by hand.

  Use this page to read a probe answer or to name a metric in your dashboards and alerts.

  The server exposes two probes and one scrape endpoint:

  - `GET /Healthcheck` checks readiness.
  - `GET /Healthcheck/live` checks liveness.
  - `GET /metrics` serves the Prometheus text exposition format 0.0.4.

  Both probes answer without authentication. The readiness probe answers HTTP 503 when a dependency is unreachable or a stream consumer is degraded.

  ## Health probe

  Everything `GET /Healthcheck` returns. A `[]` path is one entry of the
  array field: the probe returns one pool entry per database pool and one
  consumer entry per stream consumer group. The live probe returns only the
  two `live.*` fields.

  | Field | Meaning |
  |---|---|
  #{probe_rows.join("\n")}

  ## Metrics

  Every metric name the server emits, with its exposition type. The same
  registry also renders any uncataloged name as a counter with a generic
  help line; the catalog below is the complete documented set.

  | Name | Type | Meaning |
  |---|---|---|
  #{metric_rows.join("\n")}

  ## Related

  - [/admin/keep-running/monitoring/](/admin/keep-running/monitoring/)
  MARKDOWN

  ov = "health-metrics-names"
  fr_body = <<-MARKDOWN
  ---
  title: Sondes et métriques
  description: #{GenDocs::FrOverlay.fetch(ov, "description", "")}
  audience: [operator]
  features: [PLT-06, PLT-07]
  type: reference
  sidebar:
    order: 17
  verified_at: 008dd880
  ---

  #{GenDocs::FrOverlay.fetch(ov, "generated_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "intro", "")}

  #{GenDocs::FrOverlay.fetch(ov, "endpoints_intro", "")}
  #{GenDocs::FrOverlay.fetch(ov, "ep_readiness", "")}
  #{GenDocs::FrOverlay.fetch(ov, "ep_liveness", "")}
  #{GenDocs::FrOverlay.fetch(ov, "ep_metrics", "")}

  #{GenDocs::FrOverlay.fetch(ov, "auth_note", "")}

  #{GenDocs::FrOverlay.fetch(ov, "probe_heading", "")}

  #{GenDocs::FrOverlay.fetch(ov, "probe_intro", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_field", "Field")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |
  |---|---|
  #{probe_rows.join("\n")}

  #{GenDocs::FrOverlay.fetch(ov, "metrics_heading", "")}

  #{GenDocs::FrOverlay.fetch(ov, "metrics_intro", "")}

  | #{GenDocs::FrOverlay.fetch(ov, "col_name", "Name")} | #{GenDocs::FrOverlay.fetch(ov, "col_type", "Type")} | #{GenDocs::FrOverlay.fetch(ov, "col_meaning", "Meaning")} |
  |---|---|---|
  #{metric_rows.join("\n")}

  ## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}

  #{GenDocs::FrOverlay.fetch(ov, "related_ops_page", "")}
  MARKDOWN

  {"en" => en_body, "fr" => fr_body}.each do |locale, text|
    path = PAGE_PATHS[locale]
    Dir.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
  puts "wrote health-metrics-names.md in en + fr (#{HEALTH_ROWS.size} probe fields, #{catalog.size} metrics)"
end

generate
