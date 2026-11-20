# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "yaml"
require "./spec_helper"
require "../src/domain/portable/export"

# Guard: the compile-time embedded sources must match the files on disk.
#
# The binary bakes `db/migrations/*.sql`, `db/lua/*.lua`, `data/seeds/**`,
# and the `shard.yml` version in at compile time (`read_file` macros), so a
# stale build silently carries old SQL, Lua, or seed content. These specs
# pin every embedded byte to the checked-out file — a mismatch means the
# build did not pick up a change (or the Makefile `EMBEDDED` dependency set
# is out of date).

private def repo_root : String
  File.expand_path("..", __DIR__)
end

describe "compile-time embedded sources" do
  it "embeds every db/migrations file verbatim" do
    dir = File.join(repo_root, "db", "migrations")
    disk = Dir.children(dir).select(&.ends_with?(".sql")).sort!
    disk.empty?.should be_false

    embedded = Facet::Migrate::MIGRATION_SOURCES
    embedded.keys.sort!.should eq(disk)
    disk.each do |name|
      embedded[name].should eq(File.read(File.join(dir, name)))
    end
  end

  it "embeds the db/lua event scripts verbatim" do
    dir = File.join(repo_root, "db", "lua")
    Facet::Event::Subscriber::Stream::LOCK_SHARDS_SCRIPT
      .should eq(File.read(File.join(dir, "lock_shards.lua")))
    Facet::Event::Subscriber::Stream::UNLOCK_SHARDS_SCRIPT
      .should eq(File.read(File.join(dir, "unlock_shards.lua")))
  end

  it "embeds every data/seeds file verbatim" do
    root = File.join(repo_root, "data", "seeds")
    disk = Dir.glob(File.join(root, "**", "*"))
      .select { |path| File.file?(path) }
      .map(&.sub("#{root}/", ""))
      .sort!
    disk.empty?.should be_false

    embedded = Facet::Doctype::Seed::SEED_FILES
    embedded.keys.sort!.should eq(disk)
    disk.each do |key|
      embedded[key].should eq(File.read(File.join(root, key)))
    end
  end

  it "embeds the shard.yml version" do
    yml = YAML.parse(File.read(File.join(repo_root, "shard.yml")))
    FACET_VERSION.should eq(yml["version"].as_s)
  end
end
