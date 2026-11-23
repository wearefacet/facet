# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"

# Lint: `src/` must never take a `ResultSet` out of a query without the
# block form.
#
# `rs = db.query(...)` returns an OPEN result set that the caller must close.
# A `return` or a raise between the query and `rs.close` abandons it and
# leaves the response frames queued on a pooled connection — the next
# borrower then reads another request's response (see
# `src/database/wire_guard.cr` and `doc/backend/workflow.md` → Database
# quirks). The block form (`db.query(...) { |rs| ... }`) closes on every
# path, including a raising block.
#
# The wire guard in `src/database/wire_guard.cr` is the safety net; this spec
# keeps the source from relying on it.

private def source_root : String
  File.expand_path("../src", __DIR__)
end

# `= <receiver>.query(` — an assignment of an open `ResultSet`.
NON_BLOCK_QUERY = /=\s*[A-Za-z_][A-Za-z0-9_.]*\.query\s*\(/

# True for a line that opens a block query on the same line
# (`db.query(...) do |rs|` / `db.query(...) { |rs|`).
private def block_query_line?(line : String) : Bool
  !(line =~ /\)\s*(do|\{)/).nil?
end

describe "src/ result-set hygiene" do
  it "has no non-block `rs = <conn>.query(...)` assignment" do
    offenders = [] of String
    Dir.glob(File.join(source_root, "**", "*.cr")).sort!.each do |path|
      File.read_lines(path).each_with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        next unless line =~ NON_BLOCK_QUERY
        next if block_query_line?(line)
        offenders << "#{path.sub("#{source_root}/", "src/")}:#{i + 1}: #{line.strip}"
      end
    end

    offenders.should eq([] of String)
  end
end
