# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./spec_helper"
require "../src/service"

# `Facet::Service` — the process-wide identity holder. One instance id per
# boot; every manager and subscriber derives its `service_id` from it
# (see `doc/backend/event.md` → Shard locking).
describe Facet::Service do
  it "mints one stable instance id per process" do
    first = Facet::Service.instance_id
    Facet::Service.instance_id.should eq(first)
  end

  it "mints the instance id in ULID format" do
    Facet::Service.instance_id.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
  end

  it "mints distinct ids on separate mints" do
    ids = [
      Facet::Util::ScriptHelpers.ulid,
      Facet::Util::ScriptHelpers.ulid,
      Facet::Util::ScriptHelpers.ulid,
    ]
    ids.uniq.size.should eq(3)
  end

  it "builds subsystem ids from the prefix, the env, and the instance id" do
    Facet::Service.service_id("facet-repl")
      .should eq("facet-repl-#{Facet::Service.app_env}-#{Facet::Service.instance_id}")
  end

  it "reports the environment from APP_ENV with the dev fallback" do
    Facet::Service.app_env.should eq(ENV["APP_ENV"]? || "dev")
  end
end
