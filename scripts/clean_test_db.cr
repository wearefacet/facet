# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Drops orphaned per-worker test databases left behind when a spec run is
# killed before Spec.after_suite can tear them down.
#
# Usage:
#
#   APP_ENV=test crystal scripts/clean_test_db.cr
#
# Connects via DATABASE_URL (respects .env / .env.{APP_ENV} like the app does)
# and drops every database whose name matches `facet_test_worker_%`.
# The shared template (facet_test_template) is left untouched — it is
# rebuilt by spec_helper.cr on every run.

# Mirrors the loader in spec_helper.cr: the environment-specific file
# overrides the base file and may also introduce new keys; shell exports
# win over both files.
def load_dotenv_file(path : String, shell_keys : Set(String)) : Nil
  return unless File.exists?(path)
  File.read_lines(path).each do |line|
    line = line.strip
    next if line.empty? || line.starts_with?('#')
    if eq = line.index('=')
      key = line[0...eq].strip
      value = line[(eq + 1)..].strip
      ENV[key] = value unless shell_keys.includes?(key)
    end
  end
end

app_env = ENV.fetch("APP_ENV", "dev")
shell_keys = ENV.keys.to_set
load_dotenv_file(".env", shell_keys)
load_dotenv_file(".env.#{app_env}", shell_keys)

require "pg"

private def admin_database_url : String
  uri = URI.parse(ENV.fetch("DATABASE_URL"))
  uri.path = "/postgres"
  uri.to_s
end

private def terminate_connections(db_name : String) : Nil
  DB.open(admin_database_url) do |db|
    db.exec("SELECT pg_terminate_backend(pg_stat_activity.pid)
             FROM pg_stat_activity
             WHERE pg_stat_activity.datname = $1
               AND pid <> pg_backend_pid()", db_name)
  end
rescue
  # OK — database may have no live connections
end

worker_pattern = "facet_test_worker_%"

DB.open(admin_database_url) do |db|
  worker_names = db.query_all(
    "SELECT datname FROM pg_database WHERE datname LIKE $1 ORDER BY datname",
    worker_pattern, as: String
  )

  if worker_names.empty?
    puts "No orphaned worker test databases matching '#{worker_pattern}'."
  else
    puts "Found #{worker_names.size} worker test database(s):"
    worker_names.each { |name| puts "  - #{name}" }

    worker_names.each do |name|
      terminate_connections(name)
      db.exec(%(DROP DATABASE IF EXISTS "#{name}"))
      puts "Dropped #{name}"
    end

    puts "Done."
  end
end
