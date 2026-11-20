# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/notifications"

private def send_notification(db, account_id : String, kind : String = "leave_approved")
  Facet::Notification::Send.send(
    db, account_id, "hr", "LeaveRequest",
    Facet::Util::ScriptHelpers.ulid, kind, "Title",
  )
end

private def fetch_read_at(db, id : String) : Time?
  db.query_one?("SELECT read_at FROM notifications WHERE id = $1", id, as: Time?)
end

describe Facet::Notification::MarkRead do
  before_each do
    # The global per-example truncate covers `mutations` / `projections`
    # and their cascade children; `notifications` is not in the truncate
    # list, so clear it here to keep count assertions honest.
    with_db(&.exec("TRUNCATE notifications"))
  end

  describe ".mark_read" do
    it "sets read_at; re-marking is a no-op that returns false" do
      with_db do |db|
        account_id = create_test_account(db)
        notification = send_notification(db, account_id)

        marked = Facet::Notification::MarkRead.mark_read(db, account_id, notification.id)
        marked.should be_true

        read_at = fetch_read_at(db, notification.id)
        read_at.should_not be_nil
        read_at = read_at.not_nil!
        read_at.should be_close(Time.utc, 1.minute)

        marked = Facet::Notification::MarkRead.mark_read(db, account_id, notification.id)
        marked.should be_false
        fetch_read_at(db, notification.id).should eq(read_at)
      end
    end

    it "returns false for an unknown id" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Notification::MarkRead.mark_read(db, account_id, Facet::Util::ScriptHelpers.ulid)
          .should be_false
      end
    end

    it "returns false for a not-owned id and leaves the row untouched" do
      with_db do |db|
        account_a = create_test_account(db, email: "a-#{unique_suffix}@example.com")
        account_b = create_test_account(db, email: "b-#{unique_suffix}@example.com")
        notification = send_notification(db, account_a)

        Facet::Notification::MarkRead.mark_read(db, account_b, notification.id).should be_false
        fetch_read_at(db, notification.id).should be_nil

        # The owner can still mark it afterwards.
        Facet::Notification::MarkRead.mark_read(db, account_a, notification.id).should be_true
      end
    end

    it "raises ArgumentError on a blank account_id or id" do
      with_db do |db|
        account_id = create_test_account(db)
        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::MarkRead.mark_read(db, "", Facet::Util::ScriptHelpers.ulid)
        end
        expect_raises(ArgumentError, "id is required") do
          Facet::Notification::MarkRead.mark_read(db, account_id, "")
        end
      end
    end
  end

  describe ".mark_all_read" do
    it "marks every unread row, returns the count, and is idempotent" do
      with_db do |db|
        account_a = create_test_account(db, email: "a-#{unique_suffix}@example.com")
        account_b = create_test_account(db, email: "b-#{unique_suffix}@example.com")
        already_read = send_notification(db, account_a, kind: "read-one")
        send_notification(db, account_a, kind: "unread-1")
        send_notification(db, account_a, kind: "unread-2")
        foreign = send_notification(db, account_b, kind: "for-b")

        Facet::Notification::MarkRead.mark_read(db, account_a, already_read.id)

        affected = Facet::Notification::MarkRead.mark_all_read(db, account_a)
        affected.should eq(2)

        # Second call is a no-op.
        Facet::Notification::MarkRead.mark_all_read(db, account_a).should eq(0)

        items, _count, _more = Facet::Notification::List.list(db, account_a)
        items.all? { |item| !item.read_at.nil? }.should be_true

        # The other account's row is untouched.
        fetch_read_at(db, foreign.id).should be_nil
        Facet::Notification::List.unread_count(db, account_b).should eq(1)
      end
    end

    it "returns 0 when the account has no notifications" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Notification::MarkRead.mark_all_read(db, account_id).should eq(0)
      end
    end

    it "raises ArgumentError on a blank account_id" do
      with_db do |db|
        expect_raises(ArgumentError, "account_id") do
          Facet::Notification::MarkRead.mark_all_read(db, "")
        end
      end
    end
  end
end
