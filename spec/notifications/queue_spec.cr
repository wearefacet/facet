# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/notifications"

private def build_pending(
  account_id : String,
  doc_ref : String? = nil,
  kind : String = "leave_pending",
  title : String = "Pending review",
  icon : String? = nil,
  body : String = "",
  data : JSON::Any = JSON.parse("{}"),
  actions : Array(Facet::Notification::Action) = [] of Facet::Notification::Action,
) : Facet::Notification::Pending
  Facet::Notification::Pending.new(
    account_id: account_id, kind: kind, title: title,
    icon: icon, body: body, data: data, actions: actions, doc_ref: doc_ref,
  )
end

private def notification_count(db) : Int64
  db.query_one("SELECT count(*) FROM notifications", as: Int64)
end

describe Facet::Notification::Queue do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  describe ".enqueue" do
    it "returns a Pending carrying every field for a valid entry" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
        data = JSON.parse(%({"previous_status": "pending"}))
        actions = [Facet::Notification::Action.new(key: "approve", label: "Approve", variant: "primary")]

        entry = Facet::Notification::Queue.enqueue(
          [] of Facet::Notification::Pending,
          db, account_id, "leave_pending", "Pending review",
          icon: "clock", body: "Awaiting review", data: data,
          actions: actions, doc_ref: doc_ref,
        )

        entry.account_id.should eq(account_id)
        entry.kind.should eq("leave_pending")
        entry.title.should eq("Pending review")
        entry.icon.should eq("clock")
        entry.body.should eq("Awaiting review")
        entry.data.should eq(data)
        entry.actions.should eq(actions)
        entry.doc_ref.should eq(doc_ref)
      end
    end

    it "appends the validated entry to the queue" do
      with_db do |db|
        account_id = create_test_account(db)
        queue = [] of Facet::Notification::Pending

        Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "t", doc_ref: "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}")
        Facet::Notification::Queue.enqueue(queue, db, account_id, "k2", "t2", doc_ref: "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}")

        queue.size.should eq(2)
        queue[0].kind.should eq("k")
        queue[1].kind.should eq("k2")
      end
    end

    it "rejects a blank account_id, kind, or title" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
        queue = [] of Facet::Notification::Pending

        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::Queue.enqueue(queue, db, "", "k", "t", doc_ref: doc_ref)
        end
        expect_raises(ArgumentError, "kind") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "", "t", doc_ref: doc_ref)
        end
        expect_raises(ArgumentError, "title") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "", doc_ref: doc_ref)
        end
        queue.should be_empty
      end
    end

    it "rejects oversized kind, icon, and title" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
        queue = [] of Facet::Notification::Pending

        expect_raises(ArgumentError, "kind exceeds") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k" * 65, "t", doc_ref: doc_ref)
        end
        expect_raises(ArgumentError, "icon exceeds") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "t", icon: "i" * 33, doc_ref: doc_ref)
        end
        expect_raises(ArgumentError, "title exceeds") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "t" * 257, doc_ref: doc_ref)
        end
        queue.should be_empty
      end
    end

    it "rejects __-prefixed action keys" do
      with_db do |db|
        account_id = create_test_account(db)
        queue = [] of Facet::Notification::Pending

        expect_raises(ArgumentError, "reserved __ prefix") do
          Facet::Notification::Queue.enqueue(
            queue, db, account_id, "k", "t",
            actions: [Facet::Notification::Action.new(key: "__read", label: "Dismiss")],
          )
        end
        queue.should be_empty
      end
    end

    it "rejects a malformed doc_ref" do
      with_db do |db|
        account_id = create_test_account(db)
        queue = [] of Facet::Notification::Pending

        # A bare id without the domain.Doctype prefix.
        expect_raises(ArgumentError, "must be qualified") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "t", doc_ref: "01BAREIDNOPREFIX")
        end
        # Not a valid document reference at all.
        expect_raises(ArgumentError, "not a valid document reference") do
          Facet::Notification::Queue.enqueue(queue, db, account_id, "k", "t", doc_ref: "hr.LeaveRequest.bad id!")
        end
        queue.should be_empty
      end
    end

    it "rejects an unknown account_id before any insert" do
      with_db do |db|
        missing_account_id = Facet::Util::ScriptHelpers.ulid
        doc_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
        queue = [] of Facet::Notification::Pending

        expect_raises(ArgumentError, "does not match an existing account") do
          Facet::Notification::Queue.enqueue(queue, db, missing_account_id, "k", "t", doc_ref: doc_ref)
        end
        queue.should be_empty
        notification_count(db).should eq(0)
      end
    end
  end

  describe ".drain" do
    it "inserts entries in FIFO order with concrete coordinates" do
      with_db do |db|
        account_id = create_test_account(db)
        first_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"
        second_ref = "hr.LeaveRequest.#{Facet::Util::ScriptHelpers.ulid}"

        pending = [
          build_pending(account_id, doc_ref: first_ref, kind: "first"),
          build_pending(account_id, doc_ref: second_ref, kind: "second"),
        ]

        Facet::Notification::Queue.drain(db, pending, "doc-test", "T1", nil)

        rows = db.query_all(
          "SELECT account_id, domain, doc_type, doc_id, kind FROM notifications ORDER BY created_at, id",
          as: {String, String, String, String, String},
        )
        rows.size.should eq(2)
        rows[0][4].should eq("first")
        rows[1][4].should eq("second")
        rows.each do |row|
          row[0].should eq(account_id)
          row[1].should eq("hr")
          row[2].should eq("LeaveRequest")
        end
        rows[0][3].should eq(first_ref.split('.')[2])
        rows[1][3].should eq(second_ref.split('.')[2])
      end
    end

    it "resolves doc_ref = nil to the owning operation's (domain, doc_type, self_doc_id)" do
      with_db do |db|
        account_id = create_test_account(db)
        self_doc_id = Facet::Util::ScriptHelpers.ulid

        pending = [build_pending(account_id, doc_ref: nil)]

        Facet::Notification::Queue.drain(db, pending, "doc-test", "T1", self_doc_id)

        n_domain, n_doc_type, n_doc_id = db.query_one(
          "SELECT domain, doc_type, doc_id FROM notifications",
          as: {String, String, String},
        )
        n_domain.should eq("doc-test")
        n_doc_type.should eq("T1")
        n_doc_id.should eq(self_doc_id)
      end
    end

    it "logs and drops a failing entry; later entries still insert" do
      with_db do |db|
        doomed_account_id = create_test_account(db)
        live_account_id = create_test_account(db, email: "drain-#{unique_suffix}@example.com")
        self_doc_id = Facet::Util::ScriptHelpers.ulid

        # An entry that fails at drain time (drain is the last line of
        # defense — a Pending bypasses enqueue validation, so an oversized
        # kind only surfaces when Send validates and inserts). It is
        # logged and dropped; later entries still insert.
        pending = [
          build_pending(doomed_account_id, kind: "f" * 65),
          build_pending(live_account_id, kind: "will_pass"),
        ]

        Facet::Notification::Queue.drain(db, pending, "doc-test", "T1", self_doc_id)

        rows = db.query_all(
          "SELECT account_id, kind FROM notifications",
          as: {String, String},
        )
        rows.size.should eq(1)
        rows[0][0].should eq(live_account_id)
        rows[0][1].should eq("will_pass")
      end
    end

    it "does nothing for an empty queue" do
      with_db do |db|
        Facet::Notification::Queue.drain(db, [] of Facet::Notification::Pending, "doc-test", "T1", nil)
        notification_count(db).should eq(0)
      end
    end
  end
end
