# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/notifications"

private def fetch_row(db, id : String)
  db.query_one?(
    "SELECT account_id, domain, doc_type, doc_id, kind, icon, title, body,
            data, actions, read_at, created_at
     FROM notifications WHERE id = $1",
    id,
  ) do |rs|
    {
      account_id: rs.read(String),
      domain:     rs.read(String),
      doc_type:   rs.read(String),
      doc_id:     rs.read(String),
      kind:       rs.read(String),
      icon:       rs.read(String?),
      title:      rs.read(String),
      body:       rs.read(String),
      data:       rs.read(JSON::Any),
      actions:    rs.read(JSON::Any),
      read_at:    rs.read(Time?),
      created_at: rs.read(Time),
    }
  end
end

describe Facet::Notification::Send do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  describe ".send" do
    it "inserts a row and returns the id + created_at" do
      with_db do |db|
        account_id = create_test_account(db)
        before = Time.utc

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
          "leave_approved", "Your leave request was approved",
        )

        result.id.size.should eq(26)
        result.created_at.should be_close(before, 1.minute)

        row = fetch_row(db, result.id)
        row.should_not be_nil
        row = row.not_nil!
        row[:account_id].should eq(account_id)
        row[:kind].should eq("leave_approved")
        row[:title].should eq("Your leave request was approved")
        row[:body].should eq("")
        row[:data].should eq(JSON.parse("{}"))
        row[:actions].should eq(JSON.parse("[]"))
        row[:read_at].should be_nil
        row[:created_at].should eq(result.created_at)
      end
    end

    it "stores icon as null when omitted and as the value when given" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", doc_id,
          "leave_approved", "Approved",
        )
        fetch_row(db, result.id).not_nil![:icon].should be_nil

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", doc_id,
          "leave_pending", "Pending review", icon: "clock")
        fetch_row(db, result.id).not_nil![:icon].should eq("clock")
      end
    end

    it "round-trips the actions array through JSONB" do
      with_db do |db|
        account_id = create_test_account(db)

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
          "leave_request_pending", "A leave request awaits your review",
          actions: [
            Facet::Notification::Action.new(key: "approve", label: "Approve", variant: "primary"),
            Facet::Notification::Action.new(key: "deny", label: "Deny", variant: "danger", confirm: "Deny this leave request?"),
          ],
        )

        row = fetch_row(db, result.id).not_nil!
        expected_actions = JSON.parse(%({"actions": [
          {"key": "approve", "label": "Approve", "variant": "primary"},
          {"key": "deny", "label": "Deny", "variant": "danger",
           "confirm": "Deny this leave request?"}
        ]}))["actions"]
        row[:actions].should eq(expected_actions)
      end
    end

    it "stores the data payload as JSONB" do
      with_db do |db|
        account_id = create_test_account(db)
        data = JSON.parse(%({"actor": "iam.Account.alice", "previous_status": "pending"}))

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
          "leave_approved", "Approved", body: "Approved by Alice", data: data)

        row = fetch_row(db, result.id).not_nil!
        row[:body].should eq("Approved by Alice")
        row[:data].should eq(data)
      end
    end

    it "raises ArgumentError on a blank account_id, kind, or title" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid

        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::Send.send(db, "", "hr", "LeaveRequest", doc_id, "kind", "title")
        end
        expect_raises(ArgumentError, "kind") do
          Facet::Notification::Send.send(db, account_id, "hr", "LeaveRequest", doc_id, "", "title")
        end
        expect_raises(ArgumentError, "title") do
          Facet::Notification::Send.send(db, account_id, "hr", "LeaveRequest", doc_id, "kind", "")
        end
      end
    end

    it "raises ArgumentError when kind, icon, or title exceed the column limits" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid

        expect_raises(ArgumentError, "kind exceeds") do
          Facet::Notification::Send.send(db, account_id, "hr", "LeaveRequest", doc_id, "k" * 65, "title")
        end
        expect_raises(ArgumentError, "icon exceeds") do
          Facet::Notification::Send.send(db, account_id, "hr", "LeaveRequest", doc_id, "kind", "title", icon: "i" * 33)
        end
        expect_raises(ArgumentError, "title exceeds") do
          Facet::Notification::Send.send(db, account_id, "hr", "LeaveRequest", doc_id, "kind", "t" * 257)
        end
      end
    end

    it "raises an unwrapped driver error when the insert fails" do
      with_db do |db|
        account_id = create_test_account(db)
        raised = false

        begin
          # The source-document domain has a 128-char column with no
          # application-level cap — an oversized value passes validation
          # and fails at the insert. The driver's error is deliberately
          # not wrapped so it keeps its PG provenance.
          Facet::Notification::Send.send(
            db, account_id, "d" * 200, "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
            "leave_approved", "Approved",
          )
        rescue PQ::PQError
          raised = true
        end

        raised.should be_true
      end
    end

    it "rejects __-prefixed action keys, including __read" do
      with_db do |db|
        account_id = create_test_account(db)

        expect_raises(ArgumentError, "reserved __ prefix") do
          Facet::Notification::Send.send(
            db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
            "leave_request_pending", "Pending review",
            actions: [Facet::Notification::Action.new(key: "__read", label: "Dismiss")],
          )
        end
        expect_raises(ArgumentError, "reserved __ prefix") do
          Facet::Notification::Send.send(
            db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
            "leave_request_pending", "Pending review",
            actions: [Facet::Notification::Action.new(key: "__navigate", label: "Open")],
          )
        end
      end
    end

    it "rejects a blank action key" do
      with_db do |db|
        account_id = create_test_account(db)

        expect_raises(ArgumentError, "action key is required") do
          Facet::Notification::Send.send(
            db, account_id, "hr", "LeaveRequest", Facet::Util::ScriptHelpers.ulid,
            "leave_request_pending", "Pending review",
            actions: [Facet::Notification::Action.new(key: "", label: "Approve")],
          )
        end
      end
    end
  end

  describe "event emission" do
    # The suite shares one `Event::InProcessManager` (installed by
    # spec_helper), and spec examples on one fiber share the fiber-local
    # publisher queue. Drain it so earlier examples' pending events do not
    # skew the before/after deltas below.
    before_each do
      Facet::Event::Publisher.flush
    end

    it "publishes a notified event after commit on the source stream and the account fanout" do
      with_db do |db|
        mgr = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid
        stream_channel = "FACET:RESOURCE:hr:LeaveRequest"
        own_channel = "fanout:notifications:#{account_id}"
        doc_channel = "fanout:hr.LeaveRequest:#{doc_id}"
        before_stream = mgr.events_for(stream_channel).size
        before_own = mgr.events_for(own_channel).size

        result = Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", doc_id,
          "leave_approved", "Approved", icon: "check")
        Facet::Event::Publisher.flush

        # Stream: the source document's stream, event `notified`.
        stream_events = mgr.events_for(stream_channel)
        stream_events.size.should eq(before_stream + 1)
        msg = stream_events.last
        msg.headers["event"].as_s.should eq("notified")
        msg.headers["actioner_id"].as_s.should eq("system")
        # A notification is not a mutation — no mutation_id header.
        msg.headers["mutation_id"]?.should be_nil
        msg.content["id"].as_s.should eq(doc_id)
        notification = msg.content["notification"]
        notification["notification_id"].as_s.should eq(result.id)
        notification["account_id"].as_s.should eq(account_id)
        notification["kind"].as_s.should eq("leave_approved")
        notification["icon"].as_s.should eq("check")
        notification["title"].as_s.should eq("Approved")
        notification["created_at"].as_s.should eq(result.created_at.to_rfc3339)

        # Fanout: only the recipient's own channel.
        mgr.events_for(own_channel).size.should eq(before_own + 1)
        # Not on the document fanout channel — the notification is private
        # to its recipient, and any watcher of the document listens there.
        mgr.events_for(doc_channel).size.should eq(0)
      end
    end

    it "carries a null icon and empty actions through the event payload" do
      with_db do |db|
        mgr = Facet::Event::Publisher.manager.as(Facet::Event::InProcessManager)
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid
        stream_channel = "FACET:RESOURCE:hr:LeaveRequest"
        before_stream = mgr.events_for(stream_channel).size

        Facet::Notification::Send.send(
          db, account_id, "hr", "LeaveRequest", doc_id,
          "leave_pending", "Pending review",
        )
        Facet::Event::Publisher.flush

        msg = mgr.events_for(stream_channel).last
        notification = msg.content["notification"]
        notification["icon"]?.try(&.as_s?).should be_nil
        notification["actions"].as_a.should be_empty
        notification["data"].as_h.should be_empty
        mgr.events_for(stream_channel).size.should eq(before_stream + 1)
      end
    end

    it "enqueues nothing when validation or the insert fails" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid

        expect_raises(ArgumentError) do
          Facet::Notification::Send.send(
            db, account_id, "hr", "LeaveRequest", doc_id, "", "title",
          )
        end
        Facet::Event::Publisher.pending_count.should eq(0)

        # Insert failure (column overflow on the source domain) — the
        # insert fails, so no event.
        begin
          Facet::Notification::Send.send(
            db, account_id, "d" * 200, "LeaveRequest", doc_id,
            "kind", "title",
          )
        rescue PQ::PQError
          # Expected — unwrapped driver error.
        end
        Facet::Event::Publisher.pending_count.should eq(0)
      end
    end
  end
end
