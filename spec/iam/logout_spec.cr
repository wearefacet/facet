# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::Logout do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "logs out and deletes the session" do
    with_db do |db|
      account_id = create_test_account(db)
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: account_id,
        active_role: "iam.Roles.admin",
      )

      Facet::IAM::RedisSession.load(session_id).should_not be_nil
      Facet::IAM::Logout.call(db, session_id)
      Facet::IAM::RedisSession.load(session_id).should be_nil
    end
  end

  it "writes a logout event" do
    with_db do |db|
      account_id = create_test_account(db)
      session_id, _ = Facet::IAM::RedisSession.create(
        account_id: account_id,
        active_role: "iam.Roles.admin",
      )

      Facet::IAM::Logout.call(db, session_id)

      events = db.query_all(
        "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
        as: JSON::Any
      )
      events.any? { |e| e["event"]?.try(&.as_s) == "logout" }.should be_true
    end
  end

  it "handles logout for non-existent session gracefully" do
    with_db do |db|
      Facet::IAM::Logout.call(db, "nonexistent")
    end
  end
end
