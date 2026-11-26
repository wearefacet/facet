# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd
#
# Generates site-docs/src/content/docs/reference/lua-api.md and the French
# twin fr/reference/lua-api.md from the Lua API surface in code.
# Run: make gen-docs-lua
#
# Mechanism: src/lua/sandbox.cr drags in the document and webhook layers,
# so the script cannot `require` it and read objects. It extracts the
# namespace membership and signatures from the source text with strict
# anchored patterns instead:
#
# - src/lua/sandbox.cr — the registration surface. Every
#   `engine.function("__binding", ->(...) { ... })` and
#   `engine.raw_function("__binding") do` line must match; the heredoc
#   tables (`util = { ... }`, `date = { ... }`, `math.clamp = ...`) and the
#   conditional assignments (`util.x = __util_x` under the db and
#   json_helpers blocks) give the exposed names. Every registered binding
#   must be assigned to a namespace and every assigned name must be
#   registered, so a new or removed helper stops the generation.
# - The purpose of each binding comes from a doc comment, followed through
#   the registration's callee: `Util::ScriptHelpers.*` ->
#   src/util/script_helpers.cr, `Webhook::TargetCheck.*` ->
#   src/webhook/target_check.cr, `Config.instance.webhook.<prop>` ->
#   src/webhook/config.cr. The purpose is the first sentence of the doc
#   comment, verbatim. A binding whose callee carries no doc comment stops
#   the generation — nothing is invented.
# - src/document/lua_document_helpers.cr and
#   src/document/lua_notification_helpers.cr — the module doc-comment
#   tables give the document.* and notification.* function names and
#   signatures. The raw `raw_function_in_table` registration literals in
#   each file must equal the table rows, so a new helper without a doc row
#   stops the generation.
# - doc/backend/lua-engine.md — supplies only the purpose sentences for the
#   functions whose code doc comments do not carry per-function prose (the
#   two util.json_* helpers) and for document.* / notification.* (their
#   code tables carry backend and returns, not purpose). Every
#   document/notification code row must have a matching table row there,
#   and vice versa.
#
# The page tables carry Function | Signature | Purpose. The util, date, and
# math rows are sorted by function name; the document and notification rows
# keep their code-table order.

require "json"
require "./fr_overlay"

REPO_ROOT = File.expand_path("../..", __DIR__)
TARGET    = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "reference", "lua-api.md")
FR_TARGET = File.join(REPO_ROOT, "site-docs", "src", "content", "docs", "fr", "reference", "lua-api.md")

def fail!(message : String) : NoReturn
  abort "gen_docs/lua: #{message}"
end

def esc(s : String) : String
  s.gsub("|", "\\|")
end

# First sentence of a doc comment block: join the lines, collapse spaces,
# cut at a period followed by whitespace and an uppercase letter or
# backtick. Returns the text verbatim.
def first_sentence(comment_lines : Array(String)) : String
  text = comment_lines.join(" ").gsub(/\s+/, " ").strip
  m = text.match(/\A(.+?\.)\s+(?=[A-Z`])/)
  sentence = m ? m.[1] : text
  fail!("doc comment carries no readable sentence: #{text.inspect}") if sentence.empty?
  sentence
end

# Reads the contiguous doc comment block above `def self.<name>` in a
# source file. Fails loudly when the method or its comment is missing.
def doc_comment_for(path : String, method : String) : Array(String)
  lines = File.read_lines(path)
  index = lines.index { |l| l.matches?(/^\s*def self\.#{Regex.escape(method)}[\(\s:]/) || l.matches?(/^\s*def self\.#{Regex.escape(method)}\?[\(\s]/) }
  index ||= lines.index { |l| l.strip == "def self.#{method}" || l.strip.starts_with?("def self.#{method}(") || l.strip.starts_with?("def self.#{method}?(") }
  fail!("no `def self.#{method}` found in #{File.basename(path)}") unless index
  comment = [] of String
  (index - 1).downto(0) do |i|
    line = lines[i]
    break if line.strip.empty? || !line.strip.starts_with?("#")
    comment.unshift(line.lstrip.sub(/^#\s?/, ""))
  end
  comment.reject(&.empty?)
end

def doc_comment_callee(path : String, callee : String) : String
  method = callee.split(".").last
  first_sentence(doc_comment_for(path, method))
end

def doc_comment_config_bullet(path : String, key : String) : String
  joined = File.read_lines(path).map(&.lstrip.sub(/^#\s?/, "")).join(" ").gsub(/\s+/, " ")
  m = joined.match(/- `#{Regex.escape(key)}` — ([^\.]+\.)/)
  fail!("no `#{key}` bullet found in #{File.basename(path)}") unless m
  "`#{key}` — #{m.[1]}"
end

# ── Parse the sandbox registration surface ───────────────────────────────

SANDBOX = File.join(REPO_ROOT, "src", "lua", "sandbox.cr")
sandbox = File.read(SANDBOX)
sandbox_lines = sandbox.lines

record Binding, name : String, params : Array(String), callee : String, raw : Bool

bindings = {} of String => Binding
sandbox_lines.each_with_index do |line, i|
  if m = line.match(/^\s*engine\.function\("(__[a-z0-9_]+)", ->\(([^)]*)\)\s*\{(.*)$/)
    name, params, body_start = m.[1], m.[2], m.[3]
    window = ([body_start] + sandbox_lines[(i + 1)..Math.min(i + 3, sandbox_lines.size - 1)]).join(" ")
    callee_m = window.match(/::Facet::[A-Za-z0-9.:_?]+/)
    fail!("binding #{name} carries no ::Facet:: callee in its window") unless callee_m
    plist = params.strip.empty? ? [] of String : params.split(",").map(&.split(":").first.strip)
    bindings[name] = Binding.new(name, plist, callee_m.[0], false)
  elsif m = line.match(/^\s*engine\.function\("(__[a-z0-9_]+)", ->\s*\{(.*)$/)
    name, body_start = m.[1], m.[2]
    window = ([body_start] + sandbox_lines[(i + 1)..Math.min(i + 3, sandbox_lines.size - 1)]).join(" ")
    callee_m = window.match(/::Facet::[A-Za-z0-9.:_?]+/)
    fail!("binding #{name} carries no ::Facet:: callee in its window") unless callee_m
    bindings[name] = Binding.new(name, [] of String, callee_m.[0], false)
  elsif m = line.match(/^\s*engine\.raw_function\("(__[a-z0-9_]+)"\) do/)
    bindings[m.[1]] = Binding.new(m.[1], [] of String, "", true)
  elsif m = line.match(/^\s*bind_date_function!\("(__[a-z0-9_]+)", \d+\)/)
    # The date bindings register through the private bind_date_function!
    # helper, which wraps engine.raw_function; the callee sits in the block
    # body on the same line.
    callee_m = line.match(/::Facet::[A-Za-z0-9.:_?]+/)
    fail!("binding #{m.[1]} carries no ::Facet:: callee in its window") unless callee_m
    bindings[m.[1]] = Binding.new(m.[1], [] of String, callee_m.[0], true)
  end
end
fail!("sandbox.cr carries no engine.function registrations") if bindings.empty?

# ── Parse the heredoc namespace tables ───────────────────────────────────

record Member, ns : String, name : String, binding : String?, lua_params : Array(String)?, gate : String

members = [] of Member
current_block = {ns: "", gate: ""}
in_lua_block = false
inline_depth = 0
sandbox_lines.each do |line|
  # The heredoc block layout: an indented `ns = {` opens, an equally
  # indented `}` closes. Track which conditional (`if db` / `if json_helpers`)
  # the heredoc sits in for the gate label.
  if line.matches?(/^\s*if (captured_db = )?db\s*$/)
    current_block = {ns: current_block[:ns], gate: "db"}
  elsif line.matches?(/^\s*if json_helpers\s*$/)
    current_block = {ns: current_block[:ns], gate: "json"}
  elsif m = line.match(/^\s*(util|date|math)\s*=\s*\{\s*$/)
    current_block = {ns: m.[1], gate: ""}
    in_lua_block = true
  elsif in_lua_block && line.matches?(/^\s*\}\s*$/)
    current_block = {ns: "", gate: ""}
    in_lua_block = false
  elsif m = line.match(/^\s*(util)\.([a-z0-9_]+)\s*=\s*(__[a-z0-9_]+)\s*$/)
    members << Member.new("util", m.[2], m.[3], nil, current_block[:gate])
  elsif m = line.match(/^\s*(math)\.([a-z0-9_]+)\s*=\s*(__[a-z0-9_]+)\s*$/)
    members << Member.new("math", m.[2], m.[3], nil, "")
  elsif in_lua_block && current_block[:ns] != ""
    if inline_depth > 0
      # A body line of an inline Lua function. Count every block opener
      # (`then` / `do`) and closer (`end`) on the line; single-line
      # `if ... then ... end` forms net zero. When the counter returns to
      # zero the function's table entry is complete. String literals are
      # stripped first — the date block reads period bounds through
      # p["end"], and the quoted keyword is not a block closer.
      code = line.gsub(/"(?:[^"\\]|\\.)*"/, "\"\"").gsub(/'(?:[^'\\]|\\.)*'/, "''")
      inline_depth += code.scan(/\b(?:then|do)\b/).size
      inline_depth -= code.scan(/\bend\b/).size
    elsif m = line.match(/^\s*([a-z0-9_]+)\s*=\s*(__[a-z0-9_]+)\s*,?\s*$/)
      members << Member.new(current_block[:ns], m.[1], m.[2], nil, current_block[:gate])
    elsif m = line.match(/^\s*([a-z0-9_]+)\s*=\s*function\(([^)]*)\)/)
      params = m.[2].strip.empty? ? [] of String : m.[2].split(",").map(&.strip)
      members << Member.new(current_block[:ns], m.[1], nil, params, current_block[:gate])
      inline_depth = 1
    		elsif !line.matches?(/^\s*(util|date|math)\s=/) && !line.strip.empty?
      			# Comment lines document the table in the source (e.g. the `end`
      			# keyword note on the date block); they are not members.
      			unless line.strip.starts_with?("--")
      				fail!("unrecognized heredoc line in the #{current_block[:ns]} block: #{line.strip.inspect}")
      			end
    end
  end
end
fail!("the namespace heredocs parsed to zero members") if members.empty?

# Every binding registered must be assigned, and vice versa. The raw json
# helpers are assigned inside the json_helpers heredoc; the db gates inside
# the db heredoc — the heredoc scan above covers both.
assigned = members.compact_map(&.binding)
# The period/dateperiod helper bindings are never namespace members: the
# date table aliases them with a `local __ovl, __cnt = ...` line and uses
# them inside the inline period_overlaps / period_contains / dateperiod_*
# functions. A right-hand name on such an alias line is consumed on
# purpose, not forgotten.
internal = Set(String).new
sandbox_lines.each do |line|
  if m = line.match(/^\s*local\s+[a-zA-Z0-9_,\s]+=\s*([a-zA-Z0-9_,\s]+)$/)
    names = m.[1].split(',').map(&.strip).select(&.starts_with?("__"))
    names.each { |n| internal << n }
  end
end
unassigned = (bindings.keys - assigned).reject { |name| internal.includes?(name) }
fail!("registered but never assigned to a namespace: #{unassigned.inspect}") unless unassigned.empty?
unknown_assigned = assigned - bindings.keys
fail!("assigned but never registered: #{unknown_assigned.inspect}") unless unknown_assigned.empty?
duplicates = assigned.tally.select { |_, count| count > 1 }
fail!("a binding is assigned twice: #{duplicates.keys.inspect}") unless duplicates.empty?

# ── Purposes from doc comments ───────────────────────────────────────────

SCRIPT_HELPERS = File.join(REPO_ROOT, "src", "util", "script_helpers.cr")
TARGET_CHECK   = File.join(REPO_ROOT, "src", "webhook", "target_check.cr")
WEBHOOK_CONFIG = File.join(REPO_ROOT, "src", "webhook", "config.cr")

def purpose_for(binding : Binding) : String
  return doc_comment_callee(SCRIPT_HELPERS, binding.callee.sub("::Facet::Util::ScriptHelpers.", "")) if binding.callee.starts_with?("::Facet::Util::ScriptHelpers.")
  return doc_comment_callee(TARGET_CHECK, binding.callee.sub("::Facet::Webhook::TargetCheck.", "")) if binding.callee.starts_with?("::Facet::Webhook::TargetCheck.")
  if m = binding.callee.match(/^::Facet::Config\.instance\.webhook\.([a-z0-9_]+)$/)
    return doc_comment_config_bullet(WEBHOOK_CONFIG, m.[1])
  end
  fail!("binding #{binding.name} callee #{binding.callee.inspect} matches no doc-comment source")
end

# ── document.* and notification.* code tables ────────────────────────────

record CodeRow, ns : String, name : String, signature : String

def code_table_rows(path : String) : Array(CodeRow)
  rows = [] of CodeRow
  File.read_lines(path).each do |line|
    if m = line.match(/^\s*#\s*\|\s*`(document|notification)\.([a-z0-9_]+)\(([^)]*)\)`\s*\|/)
      rows << CodeRow.new(m.[1], m.[2], m.[3])
    end
  end
  fail!("#{File.basename(path)} module table parsed to zero rows") if rows.empty?
  rows
end

document_rows = code_table_rows(File.join(REPO_ROOT, "src", "document", "lua_document_helpers.cr"))
notification_rows = code_table_rows(File.join(REPO_ROOT, "src", "document", "lua_notification_helpers.cr"))

# Cross-check: the raw registration literals in each file must equal the
# table rows.
def registration_literals(path : String) : Array(String)
  names = File.read_lines(path).compact_map do |line|
    if m = line.match(/raw_function_in_table\(state,\s*"([a-z0-9_]+)"/)
      m.[1]
    elsif m = line.match(/register_refusal_on\(state,\s*engine,\s*"([a-z0-9_]+)"/)
      m.[1]
    end
  end.uniq!
  fail!("#{File.basename(path)} carries no registration literals") if names.empty?
  names
end

document_literals = registration_literals(File.join(REPO_ROOT, "src", "document", "lua_document_helpers.cr"))
fail!("document code table rows #{document_rows.map(&.name).inspect} disagree with registrations #{document_literals.inspect}") if document_rows.map(&.name).sort! != document_literals.sort
notification_literals = registration_literals(File.join(REPO_ROOT, "src", "document", "lua_notification_helpers.cr"))
fail!("notification code table rows #{notification_rows.map(&.name).inspect} disagree with registrations #{notification_literals.inspect}") if notification_rows.map(&.name).sort! != notification_literals.sort

# ── Purposes and signatures from the concern doc tables ──────────────────

LUA_ENGINE_DOC = File.join(REPO_ROOT, "doc", "backend", "lua-engine.md")

record DocRow, ns : String, name : String, signature : String, purpose : String

def doc_table_rows(path : String) : Hash(String, DocRow)
  rows = {} of String => DocRow
  File.read_lines(path).each do |line|
    m = line.match(/^\|\s*`(document|notification|util|date|math)\.([a-z0-9_]+)\(([^)]*)\)`\s*\|(.+)\|\s*$/)
    next unless m
    cells = m.[4].split('|').map(&.strip)
    fail!("lua-engine.md row `#{m.[1]}.#{m.[2]}` carries fewer than 2 trailing cells") if cells.size < 2
    purpose = first_sentence([cells.last])
    rows["#{m.[1]}.#{m.[2]}"] = DocRow.new(m.[1], m.[2], m.[3], purpose)
  end
  fail!("lua-engine.md parsed to zero function rows") if rows.empty?
  rows
end

doc_rows = doc_table_rows(LUA_ENGINE_DOC)

# Every document/notification code row must have a doc row, and vice versa.
{"document" => document_rows, "notification" => notification_rows}.each do |ns, rows|
  rows.each do |row|
    key = "#{ns}.#{row.name}"
    fail!("no lua-engine.md row for #{key}") unless doc_rows.has_key?(key)
  end
  doc_ns = doc_rows.values.select(&.ns.==(ns))
  extra = doc_ns.reject { |r| rows.any?(&.name.==(r.name)) }
  fail!("lua-engine.md carries #{ns} rows missing from the code tables: #{extra.map(&.name).inspect}") unless extra.empty?
end

# ── Emit rows per namespace ──────────────────────────────────────────────

GATE_NOTES = {
  "db"   => " Lifecycle contexts only.",
  "json" => " Not available in transient contexts.",
}

# Inline Lua functions carry no registration binding, so their purpose
# resolution maps them to the ScriptHelpers method whose doc comment
# documents the same rule. A new inline function must add an entry here or
# the generation stops.
INLINE_PURPOSE_MAP = {
  "is_empty"            => "empty?",
  "coalesce"            => "coalesce",
  "period_overlaps"     => "period_overlaps?",
  "period_contains"     => "period_contains?",
  "dateperiod_overlaps" => "dateperiod_overlaps?",
  "dateperiod_contains" => "dateperiod_contains?",
}

def lua_signature(ns : String, name : String, binding : Binding?) : String
  if binding
    return "#{binding.params.join(", ")}" if binding.params.empty? == false && binding.raw == false
  end
  ""
end

record OutRow, function : String, signature : String, purpose : String

util_rows = [] of OutRow
date_rows = [] of OutRow
math_rows = [] of OutRow
members.each do |member|
  binding = member.binding.try { |b| bindings[b] }
  signature = if params = member.lua_params
                params.join(", ")
              elsif binding && !binding.params.empty?
                binding.params.join(", ")
              elsif binding && binding.raw
                # Signature rows in lua-engine.md are keyed by the member's
                # own namespace (util.json_encode, date.diff) — raw bindings
                # exist in both tables.
                key = "#{member.ns}.#{member.name}"
                doc = doc_rows[key]?
                fail!("no lua-engine.md signature for the raw binding #{key}") unless doc
                doc.signature
              else
                "()"
              end
  purpose = if member.lua_params
              # An inline Lua function: its doc comment lives on the
              # ScriptHelpers method the Lua body mirrors.
              method = INLINE_PURPOSE_MAP[member.name]?
              fail!("no ScriptHelpers doc-comment mapping for the inline function #{member.name}") unless method
              first_sentence(doc_comment_for(SCRIPT_HELPERS, method))
            elsif binding && !binding.raw
              base = purpose_for(binding)
              note = GATE_NOTES[member.gate]? || ""
              base + note
            else
              key = "#{member.ns}.#{member.name}"
              doc = doc_rows[key]?
              fail!("no lua-engine.md purpose for the raw helper #{key}") unless doc
              base = doc.purpose.ends_with?(".") ? doc.purpose : doc.purpose + "."
              base + (GATE_NOTES[member.gate]? || "")
            end
  purpose = purpose.ends_with?(".") ? purpose : purpose + "."
  row = OutRow.new("#{member.ns}.#{member.name}", signature, purpose)
  case member.ns
  when "util" then util_rows << row
  when "date" then date_rows << row
  when "math" then math_rows << row
  else             fail!("unexpected namespace #{member.ns.inspect}")
  end
end

util_rows = util_rows.sort_by(&.function)
date_rows = date_rows.sort_by(&.function)
math_rows = math_rows.sort_by(&.function)

def md_table(rows : Array(OutRow), header : Array(String) = ["| Function | Signature | Purpose |", "| --- | --- | --- |"]) : String
  table = header.dup
  rows.each { |r| table << "| `#{r.function}` | `#{esc(r.signature)}` | #{esc(r.purpose)} |" }
  table.join("\n")
end

document_out = document_rows.map { |r| OutRow.new("document.#{r.name}", r.signature, doc_rows["document.#{r.name}"].purpose) }
notification_out = notification_rows.map { |r| OutRow.new("notification.#{r.name}", r.signature, doc_rows["notification.#{r.name}"].purpose) }
parts = [] of String
parts << <<-FRONTMATTER
  ---
  title: Lua API
  description: "The tables and functions Lua scripts can call: document, notification, util, date, and math."
  audience: [developer]
  type: reference
  features: [AUT-08, DOM-08]
  verified_at: f1409cdc
  ---
  FRONTMATTER
parts << "> Generated from `src/lua` by `make gen-docs-lua`. Do not edit this file by hand."
parts << "Lua scripts run in a sandbox with a fixed set of globals. Lifecycle hooks, named actions, and domain hooks get the full surface: `document`, `notification`, `util`, `date`, and `math.clamp`. Computed fields get `util` and `date` plus a read-only `document` table. They get no `notification` and no query-backed `util` gates. Scripts also receive the `ctx` object and an `error(msg)` collector; see lifecycle scripts and guards."
parts << "## document"
parts << "Reads accept a qualified `domain.Doctype` first argument. A foreign read needs an active domain grant; the returned content is reduced to the covered fields."
parts << md_table(document_out)
parts << ":::note\nEvery `document.*` function raises a catchable Lua error on failure. Handle it with `pcall`.\n:::"
parts << "## notification"
parts << md_table(notification_out)
parts << "## util"
parts << md_table(util_rows)
parts << "## date"
parts << md_table(date_rows)
parts << "## math"
parts << md_table(math_rows)
parts << "## Related"
parts << [
  "- [Lifecycle scripts and guards](/build/lifecycle-scripts-guards/) — where create, update, delete, and actions run.",
  "- [Event hooks](/build/event-hooks/) — the domain hooks that share this surface.",
  "- [Sidecars](/build/sidecars/) — system-managed attachment doctypes with their own hooks.",
].join("\n")

# ── French page ──────────────────────────────────────────────────────────

ov = "lua-api"
fr_header = ["| #{GenDocs::FrOverlay.fetch(ov, "col_function", "Function")} | #{GenDocs::FrOverlay.fetch(ov, "col_signature", "Signature")} | #{GenDocs::FrOverlay.fetch(ov, "col_purpose", "Purpose")} |", "| --- | --- | --- |"]
fr_parts = [] of String
fr_parts << <<-FRONTMATTER
  ---
  title: API Lua
  description: "#{GenDocs::FrOverlay.fetch(ov, "description", "")}"
  audience: [developer]
  type: reference
  features: [AUT-08, DOM-08]
  verified_at: f1409cdc
  ---
  FRONTMATTER
fr_parts << GenDocs::FrOverlay.fetch(ov, "generated_note", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "intro", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "doc_heading", "")
fr_parts << GenDocs::FrOverlay.fetch(ov, "doc_intro", "")
fr_parts << md_table(document_out, fr_header)
fr_parts << [GenDocs::FrOverlay.fetch(ov, "note_fence_open", ":::note"), GenDocs::FrOverlay.fetch(ov, "note_text", ""), GenDocs::FrOverlay.fetch(ov, "note_fence_close", ":::")].join("\n")
fr_parts << GenDocs::FrOverlay.fetch(ov, "notification_heading", "")
fr_parts << md_table(notification_out, fr_header)
fr_parts << GenDocs::FrOverlay.fetch(ov, "util_heading", "")
fr_parts << md_table(util_rows, fr_header)
fr_parts << GenDocs::FrOverlay.fetch(ov, "date_heading", "")
fr_parts << md_table(date_rows, fr_header)
fr_parts << GenDocs::FrOverlay.fetch(ov, "math_heading", "")
fr_parts << md_table(math_rows, fr_header)
fr_parts << "## #{GenDocs::FrOverlay.fetch(ov, "related_heading", "Related")}"
fr_parts << [
  GenDocs::FrOverlay.fetch(ov, "related_lifecycle", ""),
  GenDocs::FrOverlay.fetch(ov, "related_event_hooks", ""),
  GenDocs::FrOverlay.fetch(ov, "related_sidecars", ""),
].join("\n")

Dir.mkdir_p(File.dirname(TARGET))
File.write(TARGET, parts.join("\n\n") + "\n")
Dir.mkdir_p(File.dirname(FR_TARGET))
File.write(FR_TARGET, fr_parts.join("\n\n") + "\n")
puts "gen_docs/lua: wrote reference/lua-api.md in en + fr (#{document_out.size} document, #{notification_out.size} notification, #{util_rows.size} util, #{date_rows.size} date, #{math_rows.size} math rows)"
