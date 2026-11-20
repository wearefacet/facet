# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/login_throttle"

describe Facet::IAM::LoginThrottle do
  # The IAM Redis state shares one Redis instance across the suite. We clean
  # up all IAM keys before each test.
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "checks lockout state" do
    Facet::IAM::LoginThrottle.locked_out?("account_123").should be_false
    Facet::IAM::LoginThrottle.set_lockout("account_123")
    Facet::IAM::LoginThrottle.locked_out?("account_123").should be_true
  end

  it "increments and resets password attempts" do
    count = Facet::IAM::LoginThrottle.increment_pwd_attempts("account_123")
    count.should eq(1)
    count = Facet::IAM::LoginThrottle.increment_pwd_attempts("account_123")
    count.should eq(2)

    Facet::IAM::LoginThrottle.get_pwd_attempts("account_123").should eq(2)

    Facet::IAM::LoginThrottle.reset_pwd_attempts("account_123")
    Facet::IAM::LoginThrottle.get_pwd_attempts("account_123").should eq(0)
  end

  it "increments and resets IP attempts" do
    count = Facet::IAM::LoginThrottle.increment_ip_attempts("192.168.1.1")
    count.should eq(1)
    Facet::IAM::LoginThrottle.get_ip_attempts("192.168.1.1").should eq(1)

    Facet::IAM::LoginThrottle.reset_pwd_attempts("account_123", "192.168.1.1")
    Facet::IAM::LoginThrottle.get_ip_attempts("192.168.1.1").should eq(0)
  end
end
