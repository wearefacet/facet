# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/settings"
require "../support/iam_helper"

describe Facet::Settings::Service do
  describe ".get" do
    it "returns registered defaults when no row exists" do
      with_db do |db|
        account_id = create_test_account(db)
        values = Facet::Settings::Service.get(db, account_id, "core")
        values["timezone"].as_s.should eq("auto")
        values["language"].as_s.should eq("en")
      end
    end

    it "returns persisted values overriding defaults" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))

        values = Facet::Settings::Service.get(db, account_id, "core")
        values["timezone"].as_s.should eq("Europe/Paris")
        values["language"].as_s.should eq("en")
      end
    end

    it "defaults to the core app when app is omitted" do
      with_db do |db|
        account_id = create_test_account(db)
        values = Facet::Settings::Service.get(db, account_id)
        values["language"].as_s.should eq("en")
      end
    end

    it "returns the notifications scope default for a new account" do
      with_db do |db|
        account_id = create_test_account(db)
        values = Facet::Settings::Service.get(db, account_id, "notifications")
        values["in_app"].as_bool.should be_true
      end
    end

    it "defaults core.show_welcome to true without a row" do
      with_db do |db|
        account_id = create_test_account(db)
        values = Facet::Settings::Service.get(db, account_id, "core")
        values["show_welcome"].as_bool.should be_true
      end
    end
  end

  describe ".get_value" do
    it "returns the default for a missing key" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.get_value(db, account_id, "core", "timezone")
        result.should_not be_nil
        value, updated_at = result.not_nil!
        value.as_s.should eq("auto")
        updated_at.should be_nil
      end
    end

    it "returns the persisted value with updated_at" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "language", JSON::Any.new("en"))

        result = Facet::Settings::Service.get_value(db, account_id, "core", "language")
        result.should_not be_nil
        value, updated_at = result.not_nil!
        value.as_s.should eq("en")
        updated_at.should_not be_nil
      end
    end

    it "returns nil for an unregistered key" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.get_value(db, account_id, "core", "nonexistent").should be_nil
      end
    end
  end

  describe ".update" do
    it "creates a row on first write" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
        result.is_a?(Facet::ServiceError).should be_false

        value, _updated_at = result.as({JSON::Any, Time})
        value.as_s.should eq("Europe/Paris")
      end
    end

    it "updates an existing row" do
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
        result = Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("America/New_York"))

        value, _updated_at = result.as({JSON::Any, Time})
        value.as_s.should eq("America/New_York")
      end
    end

    it "stores the auto sentinel for the timezone" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("auto"))
        result.is_a?(Facet::ServiceError).should be_false

        value, _updated_at = result.as({JSON::Any, Time})
        value.as_s.should eq("auto")
      end
    end

    it "rejects an unregistered key" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "nonexistent", JSON::Any.new("value"))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("Unknown setting")
      end
    end

    it "rejects an invalid timezone" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Bogus/Nowhere"))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("Invalid timezone")
      end
    end

    it "rejects a non-string timezone" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new(42))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.message.should contain("must be a string")
      end
    end

    it "rejects an unsupported language" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "language", JSON::Any.new("de"))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.message.should contain("Unsupported language")
      end
    end

    it "persists and reads back pinned_doctypes" do
      with_db do |db|
        account_id = create_test_account(db)
        value = JSON::Any.new([JSON::Any.new("crm.Company")])
        result = Facet::Settings::Service.update(db, account_id, "core", "pinned_doctypes", value)
        result.is_a?(Facet::ServiceError).should be_false

        stored = Facet::Settings::Service.get_value(db, account_id, "core", "pinned_doctypes")
        stored.should_not be_nil
        stored_value, _ = stored.not_nil!
        stored_value.as_a.map(&.as_s).should eq(["crm.Company"])
      end
    end

    it "defaults pinned_doctypes to an empty array" do
      with_db do |db|
        account_id = create_test_account(db)
        values = Facet::Settings::Service.get(db, account_id, "core")
        values["pinned_doctypes"].as_a.should be_empty
      end
    end

    it "persists and reads back notifications.in_app" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "notifications", "in_app", JSON::Any.new(false))
        result.is_a?(Facet::ServiceError).should be_false

        stored = Facet::Settings::Service.get_value(db, account_id, "notifications", "in_app")
        stored.should_not be_nil
        stored_value, _ = stored.not_nil!
        stored_value.as_bool.should be_false
      end
    end

    it "rejects a non-boolean in_app value" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "notifications", "in_app", JSON::Any.new("yes"))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("must be a boolean")
      end
    end

    it "persists and reads back core.show_welcome" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "show_welcome", JSON::Any.new(false))
        result.is_a?(Facet::ServiceError).should be_false

        stored = Facet::Settings::Service.get_value(db, account_id, "core", "show_welcome")
        stored.should_not be_nil
        stored_value, _ = stored.not_nil!
        stored_value.as_bool.should be_false
      end
    end

    it "rejects a non-boolean show_welcome value" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::Settings::Service.update(db, account_id, "core", "show_welcome", JSON::Any.new(1))
        result.should be_a(Facet::ServiceError)
        error = result.as(Facet::ServiceError)
        error.status.should eq(422)
        error.message.should contain("must be a boolean")
      end
    end
  end
end
