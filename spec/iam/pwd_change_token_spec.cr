# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/pwd_change_token"

# Unit specs for the one-shot password-change token store, including the
# "used" marker the change-password route leaves after a successful change
# (F01-03). The suite talks to the real test Redis; `redis_cleanup` removes
# every `pwd_change:*` key around each example.
describe Facet::IAM::PwdChangeToken do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "consumes a created token and returns the account id" do
    token = Facet::IAM::PwdChangeToken.create_pwd_change_token("acc_1", 3600)
    Facet::IAM::PwdChangeToken.consume_pwd_change_token(token).should eq("acc_1")
  end

  it "returns nil for an unknown token" do
    Facet::IAM::PwdChangeToken.consume_pwd_change_token("never-minted").should be_nil
  end

  it "deletes the token after the last allowed attempt" do
    token = Facet::IAM::PwdChangeToken.create_pwd_change_token("acc_1", 3600)

    (Facet::IAM::PwdChangeToken::PWD_CHANGE_ATTEMPTS - 1).times do
      Facet::IAM::PwdChangeToken.consume_pwd_change_token(token).should eq("acc_1")
    end
    # The last allowed attempt consumes the token and returns nil.
    Facet::IAM::PwdChangeToken.consume_pwd_change_token(token).should be_nil
  end

  it "reports no used marker before the first consume" do
    token = Facet::IAM::PwdChangeToken.create_pwd_change_token("acc_1", 3600)
    Facet::IAM::PwdChangeToken.used_pwd_change_token?(token).should be_false
  end

  it "reports the used marker after a mark-and-delete burn" do
    token = Facet::IAM::PwdChangeToken.create_pwd_change_token("acc_1", 3600)

    Facet::IAM::PwdChangeToken.mark_pwd_change_token_used(token)
    Facet::IAM::PwdChangeToken.delete_pwd_change_token(token)

    # The burn leaves no consumable token, but the marker survives.
    Facet::IAM::PwdChangeToken.consume_pwd_change_token(token).should be_nil
    Facet::IAM::PwdChangeToken.used_pwd_change_token?(token).should be_true
  end

  it "reports no used marker for a token that was never valid" do
    Facet::IAM::PwdChangeToken.used_pwd_change_token?("never-minted").should be_false
  end

  it "keeps the used marker under the pwd_change: cleanup prefix" do
    # The shared `redis_cleanup` sweep scans `pwd_change:*`. The marker must
    # stay under that prefix, or it would outlive the cleanup.
    Facet::IAM::PwdChangeToken::USED_MARKER_PREFIX.should start_with(
      Facet::IAM::PwdChangeToken::PWD_CHANGE_PREFIX
    )
  end
end
