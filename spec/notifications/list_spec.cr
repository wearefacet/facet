# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/notifications"

private def send_notification(
  db,
  account_id : String,
  kind : String = "leave_approved",
  title : String = "Title",
  icon : String? = nil,
)
  Facet::Notification::Send.send(
    db, account_id, "hr", "LeaveRequest",
    Facet::Util::ScriptHelpers.ulid, kind, title, icon: icon)
end

describe Facet::Notification::List do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  describe ".list" do
    it "returns rows newest-first (created_at DESC, id DESC)" do
      with_db do |db|
        account_id = create_test_account(db)
        send_notification(db, account_id, kind: "a")
        send_notification(db, account_id, kind: "b")
        send_notification(db, account_id, kind: "c")

        items, count, more = Facet::Notification::List.list(db, account_id)

        count.should eq(3)
        more.should be_false
        kinds = items.map(&.kind)
        kinds.should eq(["c", "b", "a"])
        # The sort key is the pair — verify the invariant directly so the
        # spec stays valid even if two rows share a created_at.
        items.each_cons_pair do |a, b|
          (a.created_at > b.created_at || (a.created_at == b.created_at && a.id > b.id)).should be_true
        end
      end
    end

    it "breaks created_at ties by id DESC (ULID tiebreaker)" do
      with_db do |db|
        account_id = create_test_account(db)
        doc_id = Facet::Util::ScriptHelpers.ulid
        ts = Time.utc

        # Two real ULIDs with an identical created_at; order them so the
        # lexicographically greater id is known upfront.
        first_id = Facet::Util::ScriptHelpers.ulid
        second_id = Facet::Util::ScriptHelpers.ulid
        first_id, second_id = second_id, first_id if first_id < second_id

        [first_id, second_id].each do |id|
          db.exec(
            "INSERT INTO notifications (id, account_id, domain, doc_type, doc_id, kind, title, created_at)
             VALUES ($1, $2, 'hr', 'LeaveRequest', $3, 'kind', 'Title', $4)",
            id, account_id, doc_id, ts,
          )
        end

        items, count, _more = Facet::Notification::List.list(db, account_id)

        count.should eq(2)
        items.map(&.id).should eq([first_id, second_id])
        items[0].created_at.should eq(items[1].created_at)
      end
    end

    it "counts from the page offset and toggles more at the cap" do
      with_db do |db|
        account_id = create_test_account(db)
        5.times { |i| send_notification(db, account_id, kind: "n#{i}") }

        # `count` is the real number from the page offset; five rows fit
        # under the cap, so `more` stays false on every page.
        items, count, more = Facet::Notification::List.list(db, account_id, page: 1, per_page: 3)
        count.should eq(5)
        more.should be_false
        items.map(&.kind).should eq(["n4", "n3", "n2"])

        items, count, more = Facet::Notification::List.list(db, account_id, page: 2, per_page: 3)
        count.should eq(2)
        more.should be_false
        items.map(&.kind).should eq(["n1", "n0"])

        items, count, more = Facet::Notification::List.list(db, account_id, page: 3, per_page: 3)
        count.should eq(0)
        more.should be_false
        items.should be_empty
      end
    end

    it "clamps per_page to 100" do
      with_db do |db|
        account_id = create_test_account(db)
        105.times { |i| send_notification(db, account_id, kind: "n#{i}") }

        items, count, more = Facet::Notification::List.list(db, account_id, per_page: 150)

        # The count is real (105), not clamped with the page size; 105 rows
        # fit under the 1000 cap, so `more` is false.
        count.should eq(105)
        items.size.should eq(100)
        more.should be_false
      end
    end

    it "filters with only_unread" do
      with_db do |db|
        account_id = create_test_account(db)
        send_notification(db, account_id, kind: "unread-a")
        send_notification(db, account_id, kind: "unread-b")
        marked = send_notification(db, account_id, kind: "read-one")
        Facet::Notification::MarkRead.mark_read(db, account_id, marked.id)

        items, count, _more = Facet::Notification::List.list(db, account_id, only_unread: true)

        count.should eq(2)
        items.map(&.kind).sort!.should eq(["unread-a", "unread-b"])
        items.each(&.read_at.should be_nil)
      end
    end

    it "filters by kind" do
      with_db do |db|
        account_id = create_test_account(db)
        send_notification(db, account_id, kind: "leave_pending")
        send_notification(db, account_id, kind: "leave_pending")
        send_notification(db, account_id, kind: "leave_approved")

        items, count, _more = Facet::Notification::List.list(db, account_id, kind: "leave_pending")

        count.should eq(2)
        items.map(&.kind).should eq(["leave_pending", "leave_pending"])
      end
    end

    it "isolates accounts from each other" do
      with_db do |db|
        account_a = create_test_account(db, email: "a-#{unique_suffix}@example.com")
        account_b = create_test_account(db, email: "b-#{unique_suffix}@example.com")
        send_notification(db, account_a, kind: "for-a-1")
        send_notification(db, account_a, kind: "for-a-2")
        send_notification(db, account_b, kind: "for-b-1")

        items_a, count_a, _more_a = Facet::Notification::List.list(db, account_a)
        items_b, count_b, _more_b = Facet::Notification::List.list(db, account_b)

        count_a.should eq(2)
        items_a.all?(&.account_id.==(account_a)).should be_true
        items_a.map(&.kind).sort!.should eq(["for-a-1", "for-a-2"])

        count_b.should eq(1)
        items_b.map(&.kind).should eq(["for-b-1"])
      end
    end

    it "raises ArgumentError on a blank account_id" do
      with_db do |db|
        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::List.list(db, "")
        end
      end
    end
  end

  describe ".unread_count" do
    it "matches the filtered unread list and drops to zero after marking all read" do
      with_db do |db|
        account_id = create_test_account(db)
        3.times { |i| send_notification(db, account_id, kind: "k#{i}") }

        Facet::Notification::List.unread_count(db, account_id).should eq(3)

        items, count, _more = Facet::Notification::List.list(db, account_id, only_unread: true)
        count.should eq(3)
        items.size.should eq(3)

        Facet::Notification::MarkRead.mark_all_read(db, account_id)
        Facet::Notification::List.unread_count(db, account_id).should eq(0)
      end
    end
  end
end
