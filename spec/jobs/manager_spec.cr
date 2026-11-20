# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "yaml"
require "../../src/jobs"

# Minimal config YAML that passes `Config.from_yaml_node` (the `event`
# section and the artifact keys, including `artifact.storage`, are
# fail-loud). `jobs_section` is spliced in verbatim so each example
# shapes the `jobs:` block.
private def parse_config(jobs_section : String) : Facet::Config
  Facet::Config.from_yaml_node(YAML.parse(<<-YAML
    host: "localhost:3000"
    artifact_base_url: "http://localhost:3001"
    artifact_grant_secret: "spec-grant-secret"
    artifact:
      storage:
        type: filesystem
        directory: tmp/uploads/test/store
    event:
      url: "redis://localhost:6379/15"
    secrets:
      master_key: "j6v38U28kkx2TJnNc1azCe1PMsUt8IGoGV7GLRv1exk="
    #{jobs_section}
    YAML
  ))
end

private def job_row(db : DB::Connection, id : String)
  db.query_one?("SELECT status, attempts FROM background_jobs WHERE id = $1", id) do |rs|
    {status: rs.read(String), attempts: rs.read(Int32)}
  end
end

# Builds a manager and installs it as the singleton, so `after_each`
# stops every loop fiber this example started.
private def new_manager(config : Facet::Config::JobsConfig) : Facet::Jobs::Manager
  manager = Facet::Jobs::Manager.new(config)
  Facet::Jobs::Manager.instance = manager
  manager
end

# A do-nothing handler for `register_handler` assertions. Never executed —
# the specs only inspect the dispatch-table wiring.
private class ProbeHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    Result.new(status: Kind::Succeeded)
  end
end

module Facet
  module Jobs
    describe Manager do
      before_each do
        # `background_jobs` is not in the global truncation list; each spec
        # cleans up its own rows.
        with_db(&.exec("DELETE FROM background_jobs"))
        Manager.reset!
      end

      after_each do
        # Never leak a running loop fiber into the next example. `stop`
        # nils the manager's worker, so capture the worker first; then
        # wait for the loop fiber to exit instead of settling blindly.
        worker = Manager.instance.try(&.worker)
        Manager.instance.try(&.stop)
        if worker
          wait_for { worker.loop_fiber.try(&.dead?) == true }
        end
        Manager.reset!
      end

      describe "config parsing" do
        it "parses every jobs: key" do
          config = parse_config(<<-YAML
            jobs:
              poll_interval_s: 1.5
              lease_ttl_s: 30
              batch: 8
              sweep_interval_s: 10.0
              retention_days: 7
              enabled: false
            YAML
          )
          jobs = config.jobs
          jobs.poll_interval_s.should eq 1.5
          jobs.lease_ttl_s.should eq 30
          jobs.batch.should eq 8
          jobs.sweep_interval_s.should eq 10.0
          jobs.retention_days.should eq 7
          jobs.enabled.should be_false
        end

        it "applies defaults when the jobs: section is absent" do
          config = parse_config("")
          jobs = config.jobs
          jobs.poll_interval_s.should eq 5.0
          jobs.lease_ttl_s.should eq 60
          jobs.batch.should eq 32
          jobs.sweep_interval_s.should eq 30.0
          jobs.retention_days.should eq 30
          # Workers run by default: a missing section does not disable them.
          jobs.enabled.should be_true
        end

        it "applies defaults when the jobs: section is empty" do
          config = parse_config("jobs: {}")
          jobs = config.jobs
          jobs.poll_interval_s.should eq 5.0
          jobs.lease_ttl_s.should eq 60
          jobs.batch.should eq 32
          jobs.sweep_interval_s.should eq 30.0
          jobs.retention_days.should eq 30
          jobs.enabled.should be_true
        end
      end

      describe ".instance / .reset!" do
        it "installs and clears the singleton" do
          manager = new_manager(Config::JobsConfig.new(enabled: false))
          Manager.instance.should eq manager

          Manager.reset!
          Manager.instance.should be_nil
        end
      end

      describe "#start / #stop" do
        it "does not start the worker when disabled" do
          manager = new_manager(Config::JobsConfig.new(enabled: false))
          manager.start
          manager.worker.should be_nil
        end

        it "starts the worker when enabled" do
          manager = new_manager(Config::JobsConfig.new(enabled: true, poll_interval_s: 0.05))
          manager.start
          worker = manager.worker
          worker.should_not be_nil
          worker.not_nil!.running?.should be_true
        end

        it "start is idempotent" do
          manager = new_manager(Config::JobsConfig.new(enabled: true))
          manager.start
          worker = manager.worker
          manager.start
          manager.worker.should eq worker
        end

        it "stop makes the worker stop running" do
          manager = new_manager(Config::JobsConfig.new(enabled: true))
          manager.start
          worker = manager.worker.not_nil!
          manager.stop
          worker.running?.should be_false
        end

        it "stop is safe without start and when disabled" do
          manager = new_manager(Config::JobsConfig.new(enabled: false))
          manager.stop
          manager.worker.should be_nil
        end

        it "restarts after a stop" do
          manager = new_manager(Config::JobsConfig.new(enabled: true))
          manager.start
          manager.stop
          manager.worker.should be_nil

          manager.start
          manager.worker.not_nil!.running?.should be_true
        end
      end

      describe "#register_handler" do
        it "fills the dispatch table before start and the started worker carries it" do
          manager = new_manager(Config::JobsConfig.new(enabled: true, poll_interval_s: 60.0))
          manager.handler_for("probe").should be_nil

          manager.register_handler("probe", ProbeHandler)
          manager.handler_for("probe").should eq ProbeHandler

          manager.start
          manager.worker.should_not be_nil
          manager.worker.not_nil!.handlers["probe"]?.should eq ProbeHandler
          manager.stop
        end

        it "raises when called after start" do
          manager = new_manager(Config::JobsConfig.new(enabled: true, poll_interval_s: 60.0))
          manager.start

          expect_raises(Exception, "already started") do
            manager.register_handler("probe", ProbeHandler)
          end
        end
      end

      describe "#enqueue" do
        it "lands the row when the manager is disabled (enqueue-only mode)" do
          manager = new_manager(Config::JobsConfig.new(enabled: false))
          manager.start

          id = manager.enqueue("test", JSON.parse(%({"n": 1})))
          row = with_db { |db| job_row(db, id) }
          row.should_not be_nil
          row.not_nil![:status].should eq "pending"
          row.not_nil![:attempts].should eq 0
        end

        it "delegates to the running worker when enabled" do
          manager = new_manager(Config::JobsConfig.new(enabled: true, poll_interval_s: 0.05))
          manager.start

          # A future run_after keeps the row out of the worker's claim
          # window, so the row is provably untouched by the loop.
          id = manager.enqueue("test", JSON.parse(%({"n": 1})), run_after: Time.utc + 1.hour)
          row = with_db { |db| job_row(db, id) }
          row.should_not be_nil
          row.not_nil![:status].should eq "pending"
          row.not_nil![:attempts].should eq 0
        end
      end
    end
  end
end
