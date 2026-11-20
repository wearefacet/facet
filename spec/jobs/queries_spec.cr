# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/jobs"

def insert_job(db : DB::Connection, *, kind : String = "webhook_delivery", max_attempts : Int32? = nil, backoff : Array(Int32)? = nil, run_after : Time? = nil, lease_ttl_s : Int32? = nil) : String
  id = Facet::Util::ScriptHelpers.ulid
  payload = JSON.parse(%({"url": "https://example.test/hook", "n": "#{id}"}))
  Facet::Jobs::Queries.insert(db, id, kind, payload, max_attempts: max_attempts, backoff: backoff, run_after: run_after, lease_ttl_s: lease_ttl_s)
  id
end

def raw_row(db : DB::Connection, id : String)
  db.query_one?("SELECT status, attempts, max_attempts, backoff_seconds, run_after,
            locked_by, locked_until, last_error, last_http_status
     FROM background_jobs WHERE id = $1",
    id,
  ) do |rs|
    {
      status:           rs.read(String),
      attempts:         rs.read(Int32),
      max_attempts:     rs.read(Int32),
      backoff:          rs.read(Array(Int32)?),
      run_after:        rs.read(Time?),
      locked_by:        rs.read(String?),
      locked_until:     rs.read(Time?),
      last_error:       rs.read(String?),
      last_http_status: rs.read(Int32?),
    }
  end
end

module Facet
  module Jobs
    describe Queries do
      before_each do
        # `background_jobs` is not in the global truncation list; each spec
        # cleans up its own rows.
        with_db(&.exec("DELETE FROM background_jobs"))
      end

      describe ".insert / .find" do
        it "round-trips all fields" do
          with_db do |db|
            id = Util::ScriptHelpers.ulid
            payload = JSON.parse(%({"url": "https://example.test/hook"}))
            run_after = Time.utc(2026, 9, 1, 12, 0, 0)
            backoff = [10, 60, 300]

            Queries.insert(db, id, "webhook_delivery", payload,
              max_attempts: 3, backoff: backoff, run_after: run_after)
            job = Queries.find(db, id)

            job.should_not be_nil
            job = job.not_nil!
            job.id.should eq(id)
            job.kind.should eq("webhook_delivery")
            job.payload.should eq(payload)
            job.attempts.should eq(0)
            job.max_attempts.should eq(3)
            job.backoff.should eq(backoff)

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            ((row[:run_after].not_nil! - run_after).abs < 1.second).should be_true
          end
        end

        it "applies column defaults when no policy is given" do
          with_db do |db|
            id = insert_job(db)

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            row[:attempts].should eq(0)
            row[:max_attempts].should eq(5)
            row[:backoff].should be_nil
            row[:locked_by].should be_nil
            ((row[:run_after].not_nil! - Time.utc).abs < 5.seconds).should be_true

            job = Queries.find(db, id).not_nil!
            job.max_attempts.should eq(5)
            job.backoff.should be_nil
          end
        end

        it "returns nil for an unknown id" do
          with_db do |db|
            Queries.find(db, "does-not-exist").should be_nil
          end
        end
      end

      describe ".claim" do
        it "claims due rows in run_after order and holds a lease" do
          with_db do |db|
            first = insert_job(db, run_after: 10.seconds.ago)
            second = insert_job(db, run_after: 5.seconds.ago)

            claims = Queries.claim(db, "worker-a", 60, 32)

            claims.map(&.id).should eq([first, second])
            claims.all?(&.kind.==("webhook_delivery")).should be_true
            claims.all?(&.attempts.==(1)).should be_true

            row = raw_row(db, first).not_nil!
            row[:status].should eq("running")
            row[:attempts].should eq(1)
            row[:locked_by].should eq("worker-a")
            locked_until = row[:locked_until].not_nil!
            ((locked_until - (Time.utc + 60.seconds)).abs < 5.seconds).should be_true
          end
        end

        it "returns no rows when run_after is in the future" do
          with_db do |db|
            insert_job(db, run_after: 1.minute.from_now)

            Queries.claim(db, "worker-a", 60, 32).should be_empty
          end
        end

        it "does not claim rows already running" do
          with_db do |db|
            insert_job(db)

            first = Queries.claim(db, "worker-a", 60, 32)
            first.size.should eq(1)

            Queries.claim(db, "worker-a", 60, 32).should be_empty
          end
        end

        it "gives two concurrent claimers disjoint row sets" do
          with_db do |db|
            4.times { insert_job(db) }

            channel = Channel(Array(Job)).new
            2.times do |i|
              spawn do
                claims = with_db { |conn| Queries.claim(conn, "worker-#{i}", 60, 2) }
                channel.send(claims)
              end
            end
            claims_a = channel.receive
            claims_b = channel.receive

            ids_a = claims_a.map(&.id)
            ids_b = claims_b.map(&.id)
            (ids_a & ids_b).empty?.should be_true
            (ids_a + ids_b).size.should eq(4)
          end
        end
      end

      describe ".write_succeeded" do
        it "writes the terminal state and clears the lease" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)

            Queries.write_succeeded(db, id, http_status: 200)

            row = raw_row(db, id).not_nil!
            row[:status].should eq("succeeded")
            row[:last_error].should be_nil
            row[:last_http_status].should eq(200)
            row[:run_after].should be_nil
            row[:locked_by].should be_nil
            row[:locked_until].should be_nil
          end
        end

        it "leaves last_http_status null when the result has none" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)

            Queries.write_succeeded(db, id)

            raw_row(db, id).not_nil![:last_http_status].should be_nil
          end
        end

        it "stores the handler's terminal result payload" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)

            result = JSON.parse(%({"artifact_id": "01JABC", "row_count": 3, "format": "csv"}))
            Queries.write_succeeded(db, id, result: result)

            outcome = Queries.find_outcome(db, id).not_nil!
            outcome.status.should eq("succeeded")
            outcome.error.should be_nil
            outcome.result.not_nil!["artifact_id"].as_s.should eq("01JABC")
            outcome.result.not_nil!["row_count"].as_i.should eq(3)
          end
        end

        it "leaves the result payload null while the row is not terminal" do
          with_db do |db|
            id = insert_job(db)

            outcome = Queries.find_outcome(db, id).not_nil!
            outcome.status.should eq("pending")
            outcome.result.should be_nil
          end
        end
      end

      describe ".write_failed" do
        it "returns to pending with backoff[attempts - 1] while attempts remain" do
          with_db do |db|
            id = insert_job(db, max_attempts: 3, backoff: [10, 60])

            Queries.claim(db, "worker-a", 60, 32)
            Queries.write_failed(db, id, error: "boom", http_status: 500, backoff_seconds: [10, 60])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            row[:attempts].should eq(1)
            row[:last_error].should eq("boom")
            row[:last_http_status].should eq(500)
            row[:locked_by].should be_nil
            row[:locked_until].should be_nil
            ((row[:run_after].not_nil! - (Time.utc + 10.seconds)).abs < 5.seconds).should be_true

            # Second failure: attempts = 2 -> backoff[1] = 60s. Simulate
            # the retry delay elapsing so the row is due again.
            db.exec("UPDATE background_jobs SET run_after = now() - interval '1 second' WHERE id = $1", id)
            Queries.claim(db, "worker-a", 60, 32)
            Queries.write_failed(db, id, backoff_seconds: [10, 60])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            ((row[:run_after].not_nil! - (Time.utc + 60.seconds)).abs < 5.seconds).should be_true
          end
        end

        it "goes terminal when attempts reach max_attempts" do
          with_db do |db|
            id = insert_job(db, max_attempts: 1, backoff: [10])

            Queries.claim(db, "worker-a", 60, 32)
            Queries.write_failed(db, id, error: "nope", backoff_seconds: [10])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("failed")
            row[:run_after].should be_nil
            row[:last_error].should eq("nope")
          end
        end

        it "stores the terminal result payload on a failed row" do
          with_db do |db|
            id = insert_job(db, max_attempts: 1, backoff: [10])

            Queries.claim(db, "worker-a", 60, 32)
            result = JSON.parse(%({"row": 3, "field": "email", "message": "bad"}))
            Queries.write_failed(db, id, error: "bad row", result: result)

            outcome = Queries.find_outcome(db, id).not_nil!
            outcome.status.should eq("failed")
            outcome.error.should eq("bad row")
            outcome.result.not_nil!["row"].as_i.should eq(3)
            outcome.result.not_nil!["field"].as_s.should eq("email")
          end
        end

        it "clamps to the last backoff value when the list is shorter than attempts" do
          with_db do |db|
            id = insert_job(db, max_attempts: 5, backoff: [10, 60])

            3.times do
              # Simulate the retry delay elapsing so the row is due again.
              db.exec("UPDATE background_jobs SET run_after = now() - interval '1 second' WHERE id = $1", id)
              Queries.claim(db, "worker-a", 60, 32)
              Queries.write_failed(db, id, backoff_seconds: [10, 60])
            end

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            ((row[:run_after].not_nil! - (Time.utc + 60.seconds)).abs < 5.seconds).should be_true
          end
        end

        it "retries immediately when no backoff list exists" do
          with_db do |db|
            id = insert_job(db, max_attempts: 3)

            Queries.claim(db, "worker-a", 60, 32)
            Queries.write_failed(db, id, error: "boom")

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            ((row[:run_after].not_nil! - Time.utc).abs < 5.seconds).should be_true
          end
        end
      end

      describe "per-row lease ttl" do
        it "claims a custom-ttl row with the row's own horizon, not the worker default" do
          with_db do |db|
            custom = insert_job(db, lease_ttl_s: 3600)
            default = insert_job(db)

            claims = Queries.claim(db, "worker-a", 60, 32)
            claims.map(&.id).sort!.should eq([custom, default].sort!)

            custom_row = raw_row(db, custom).not_nil!
            ((custom_row[:locked_until].not_nil! - (Time.utc + 3600.seconds)).abs < 5.seconds).should be_true

            # The default row in the same batch keeps the worker TTL.
            default_row = raw_row(db, default).not_nil!
            ((default_row[:locked_until].not_nil! - (Time.utc + 60.seconds)).abs < 5.seconds).should be_true
          end
        end

        it "requeues a custom-ttl row only after its own expiry" do
          with_db do |db|
            custom = insert_job(db, lease_ttl_s: 3600)
            default = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)

            # Simulate two minutes of runtime: the worker-default lease
            # (60 s) is expired, the custom lease (1 h) is still valid.
            db.exec("UPDATE background_jobs SET locked_until = locked_until - interval '2 minutes'")
            Queries.sweep_expired_leases(db).should eq([{id: default, kind: "webhook_delivery"}])
            raw_row(db, custom).not_nil![:status].should eq("running")

            # Simulate the rest of the custom horizon elapsing: only now
            # does the sweep requeue the row.
            db.exec("UPDATE background_jobs SET locked_until = locked_until - interval '1 hour' WHERE id = $1", custom)
            Queries.sweep_expired_leases(db).should eq([{id: custom, kind: "webhook_delivery"}])
          end
        end
      end

      describe ".sweep_expired_leases" do
        it "returns no rows when nothing expired" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)

            Queries.sweep_expired_leases(db).should be_empty

            row = raw_row(db, id).not_nil!
            row[:status].should eq("running")
            row[:attempts].should eq(1)
          end
        end

        it "requeues rows whose lease expired, without touching attempts" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "worker-a", 60, 32)
            db.exec("UPDATE background_jobs SET locked_until = now() - interval '1 second' WHERE id = $1", id)

            Queries.sweep_expired_leases(db).should eq([{id: id, kind: "webhook_delivery"}])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            row[:attempts].should eq(1)
            row[:locked_by].should be_nil
            row[:locked_until].should be_nil
          end
        end

        it "requeues a row whose owner instance is dead while its lease is valid" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "dead-instance:worker-1", 3600, 32)

            Queries.sweep_expired_leases(db, ["dead-instance"]).should eq([{id: id, kind: "webhook_delivery"}])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("pending")
            row[:attempts].should eq(1)
            row[:locked_by].should be_nil
            row[:locked_until].should be_nil
          end
        end

        it "leaves the row running when its owner is not in the dead list" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "dead-instance:worker-1", 3600, 32)

            # The whole owner tag is not an instance id — only the part
            # before the first colon matches.
            Queries.sweep_expired_leases(db, ["dead-instance:worker-1"]).should be_empty
            Queries.sweep_expired_leases(db, ["other-instance"]).should be_empty

            raw_row(db, id).not_nil![:status].should eq("running")
          end
        end

        it "marks a row past its retry cap failed instead of requeuing it" do
          with_db do |db|
            id = insert_job(db, max_attempts: 1)
            Queries.claim(db, "worker-a", 60, 32)
            db.exec("UPDATE background_jobs SET locked_until = now() - interval '1 second' WHERE id = $1", id)

            Queries.sweep_expired_leases(db).should eq([{id: id, kind: "webhook_delivery"}])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("failed")
            row[:last_error].should eq(Queries::ABANDONED_ERROR)
            row[:run_after].should be_nil
            row[:attempts].should eq(1)
            row[:locked_by].should be_nil
          end
        end

        it "applies the retry cap to a row stranded by a dead owner" do
          with_db do |db|
            id = insert_job(db, max_attempts: 1)
            Queries.claim(db, "dead-instance:worker-1", 3600, 32)

            Queries.sweep_expired_leases(db, ["dead-instance"]).should eq([{id: id, kind: "webhook_delivery"}])

            row = raw_row(db, id).not_nil!
            row[:status].should eq("failed")
            row[:last_error].should eq(Queries::ABANDONED_ERROR)
          end
        end
      end

      describe ".running_owner_instances" do
        it "returns one entry per distinct running owner instance" do
          with_db do |db|
            insert_job(db)
            insert_job(db)
            Queries.claim(db, "inst-a:worker-1", 60, 1)
            Queries.claim(db, "inst-a:worker-2", 60, 1)

            Queries.running_owner_instances(db).should eq(["inst-a"])
          end
        end

        it "ignores rows that are not running" do
          with_db do |db|
            id = insert_job(db)
            Queries.claim(db, "inst-a:worker-1", 60, 1)
            Queries.write_succeeded(db, id)

            Queries.running_owner_instances(db).should be_empty
          end
        end
      end

      describe ".prune_terminal" do
        it "deletes only terminal rows past the retention horizon" do
          with_db do |db|
            old_succeeded = insert_job(db)
            recent_succeeded = insert_job(db)
            old_pending = insert_job(db)
            db.exec("UPDATE background_jobs SET status = 'succeeded', updated_at = now() - interval '40 days' WHERE id = $1", old_succeeded)
            db.exec("UPDATE background_jobs SET status = 'succeeded', updated_at = now() - interval '1 day' WHERE id = $1", recent_succeeded)
            db.exec("UPDATE background_jobs SET updated_at = now() - interval '40 days' WHERE id = $1", old_pending)

            Queries.prune_terminal(db, 30).should eq(1)

            Queries.find(db, old_succeeded).should be_nil
            Queries.find(db, recent_succeeded).should_not be_nil
            Queries.find(db, old_pending).should_not be_nil
          end
        end
      end
    end
  end
end
