# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"

# Doc lint: migration citations in the living docs must resolve to real
# files in `db/migrations/`. This spec pins every citation to a file on
# disk.
#
# Scope: `doc/**/*.md` plus `AGENTS.md`. `doc/plans/` is out of scope —
# plan and audit records quote stale numbers on purpose, because they
# describe findings, not the schema.
#
# Citation forms checked:
#   * `db/migrations/0008_jobs.sql` or `0008_jobs.sql` — the file must exist
#   * `migration 0008` / `migrations 0018/0019` — a file with that numeric
#     prefix must exist
#
# Cite the full file name in new docs (`0008_jobs.sql`): a name reads as a
# path the reader can open, and a renumbering fails this spec loudly.

private def repo_root : String
  File.expand_path("..", __DIR__)
end

private def doc_files : Array(String)
  doc_dir = File.join(repo_root, "doc")
  files = Dir.glob("#{doc_dir}/**/*.md").reject do |path|
    path.starts_with?("#{doc_dir}/plans/")
  end
  agents = File.join(repo_root, "AGENTS.md")
  files << agents if File.exists?(agents)
  files.sort
end

private def migration_names : Array(String)
  Dir.children(File.join(repo_root, "db", "migrations"))
    .select(&.ends_with?(".sql"))
    .sort!
end

private def rel_path(path : String) : String
  path.sub("#{repo_root}/", "")
end

private def file_citation_violations : Array(String)
  violations = [] of String
  doc_files.each do |path|
    File.read_lines(path).each_with_index do |line, index|
      line.scan(/\b(\d{4}_[a-z0-9_]+\.sql)\b/) do |match|
        filename = match[1]
        unless File.exists?(File.join(repo_root, "db", "migrations", filename))
          violations << "#{rel_path(path)}:#{index + 1}: no db/migrations/#{filename}"
        end
      end
    end
  end
  violations
end

private def number_citation_violations(names : Array(String)) : Array(String)
  violations = [] of String
  doc_files.each do |path|
    File.read_lines(path).each_with_index do |line, index|
      line.scan(/\bmigrations? `?(\d{4}(?:\s*[\/&-]\s*`?\d{4}`?)?)`?/) do |match|
        match[1].split(/[\s\/&-]+/).each do |number|
          unless names.any?(&.starts_with?(number))
            violations << "#{rel_path(path)}:#{index + 1}: no db/migrations file numbered #{number}"
          end
        end
      end
    end
  end
  violations
end

describe "doc migration citations" do
  it "cites only migration files that exist in db/migrations" do
    violations = file_citation_violations
    unless violations.empty?
      fail "stale migration file citations:\n#{violations.join("\n")}"
    end
  end

  it "resolves every bare migration number to an existing migration file" do
    violations = number_citation_violations(migration_names)
    unless violations.empty?
      fail "unresolved migration numbers:\n#{violations.join("\n")}"
    end
  end
end
