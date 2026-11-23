# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/settings"
require "../../src/iam"
require "../../src/http/server"
require "../support/iam_helper"
require "../support/http_helper"
require "json"

# Initialize HTTP handler chain once (idempotent across spec files)
HTTPTest.init

private def auth_cookie_header(account_id : String, role : String = "admin") : HTTP::Headers
  pem_key = Facet::IAM::TokenEmitter.signing_key
  payload, _exp = Facet::IAM::JWT.build_access_payload(account_id, "fake-sid", role)
  token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")
  HTTP::Headers{"Cookie" => "auth_token=#{token}"}
end

describe "Settings HTTP Integration" do
  describe "GET /Api/settings" do
    it "returns 401 without authentication" do
      request = HTTP::Request.new("GET", "/Api/settings")
      response = call_api(request)

      assert_http_status(response, 401)
      JSON.parse(response.body)["error"].to_s.should contain("Authentication")
    end

    it "returns core defaults for an authenticated user" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/settings", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["app"].to_s.should eq("core")
      json["values"]["timezone"].to_s.should eq("auto")
      json["values"]["language"].to_s.should eq("en")
    end
  end

  describe "GET /Api/settings/:app" do
    it "returns persisted values for the app scope" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
      end

      request = HTTP::Request.new("GET", "/Api/settings/core", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["app"].to_s.should eq("core")
      json["values"]["timezone"].to_s.should eq("Europe/Paris")
      json["values"]["language"].to_s.should eq("en")
    end

    it "returns the notifications scope default for a new account" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/settings/notifications", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["app"].to_s.should eq("notifications")
      json["values"]["in_app"].as_bool.should be_true
    end
  end

  describe "GET /Api/settings/:app/:key" do
    it "returns the value with updated_at when persisted" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
      end

      request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["app"].to_s.should eq("core")
      json["key"].to_s.should eq("timezone")
      json["value"].to_s.should eq("Europe/Paris")
      json["updated_at"]?.should_not be_nil
    end

    it "returns the default without updated_at when not persisted" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["value"].to_s.should eq("auto")
      json["updated_at"]?.should be_nil
    end

    it "returns 404 for an unregistered key" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/settings/core/nonexistent", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].to_s.should contain("Unknown setting")
    end
  end

  describe "PUT /Api/settings/:app/:key" do
    it "returns 401 without authentication" do
      headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      request = HTTP::Request.new("PUT", "/Api/settings/core/timezone", headers: headers, body: %({"value": "UTC"}))
      response = call_api(request)

      assert_http_status(response, 401)
    end

    it "returns 422 without X-Requested-With header (CSRF)" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      # Raw dispatch — `call_api` would add the browser default header.
      request = HTTP::Request.new("PUT", "/Api/settings/core/timezone", headers: headers, body: %({"value": "UTC"}))
      response = call_api_raw(request)

      JSON.parse(response.body)["error"].to_s.should contain("CSRF")
    end

    it "persists and returns the updated value" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      body = %({"value": "Europe/Paris"})
      request = HTTP::Request.new("PUT", "/Api/settings/core/timezone", headers: headers, body: body)
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["value"].to_s.should eq("Europe/Paris")
      json["updated_at"]?.should_not be_nil

      # Confirm read-back
      read_request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      read_response = call_api(read_request)
      JSON.parse(read_response.body)["value"].to_s.should eq("Europe/Paris")
    end

    it "returns 422 for an invalid timezone" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      body = %({"value": "Bogus/Nowhere"})
      request = HTTP::Request.new("PUT", "/Api/settings/core/timezone", headers: headers, body: body)
      response = call_api(request)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].to_s.should contain("Invalid timezone")
    end

    it "returns 422 for an unregistered key" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      body = %({"value": "anything"})
      request = HTTP::Request.new("PUT", "/Api/settings/core/nonexistent", headers: headers, body: body)
      response = call_api(request)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].to_s.should contain("Unknown setting")
    end

    it "returns 422 when body lacks 'value'" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("PUT", "/Api/settings/core/timezone", headers: headers, body: %({"other": "x"}))
      response = call_api(request)

      assert_http_status(response, 422)
    end

    it "persists and returns a notifications.in_app write" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("PUT", "/Api/settings/notifications/in_app", headers: headers, body: %({"value": false}))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["value"].as_bool.should be_false

      read_request = HTTP::Request.new("GET", "/Api/settings/notifications/in_app", headers: auth_cookie_header(account_id.as(String)))
      read_response = call_api(read_request)
      JSON.parse(read_response.body)["value"].as_bool.should be_false
    end

    it "returns 422 for a non-boolean in_app value" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("PUT", "/Api/settings/notifications/in_app", headers: headers, body: %({"value": "yes"}))
      response = call_api(request)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].to_s.should contain("must be a boolean")
    end

    it "returns 422 for an unregistered key in the notifications scope" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("PUT", "/Api/settings/notifications/digest", headers: headers, body: %({"value": true}))
      response = call_api(request)

      assert_http_status(response, 422)
      JSON.parse(response.body)["error"].to_s.should contain("Unknown setting")
    end
  end

  describe "GET /Api/iam/me includes settings" do
    it "returns the settings block with core defaults" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/iam/me", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["settings"]?.should_not be_nil
      json["settings"]["timezone"].to_s.should eq("auto")
      json["settings"]["language"].to_s.should eq("en")
    end

    it "reflects persisted settings in /me" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("America/New_York"))
      end

      request = HTTP::Request.new("GET", "/Api/iam/me", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["settings"]["timezone"].to_s.should eq("America/New_York")
    end
  end

  describe "server defaults (the SystemSettings tier)" do
    it "resolves an unset account key from the pinned server default" do
      account_id = nil
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"localization": {"default_timezone": "Europe/Paris", "default_language": "en"}}))
        account_id = create_test_account(db)
      end

      request = HTTP::Request.new("GET", "/Api/settings/core", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["values"]["timezone"].to_s.should eq("Europe/Paris")
      json["values"]["language"].to_s.should eq("en")
    ensure
      Facet::SystemSettings.reset_cache!
    end

    it "lets the account row win over the server default" do
      account_id = nil
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"localization": {"default_timezone": "Europe/Paris"}}))
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Asia/Tokyo"))
      end

      request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      JSON.parse(response.body)["value"].to_s.should eq("Asia/Tokyo")
    ensure
      Facet::SystemSettings.reset_cache!
    end

    it "carries the defaults block with the server-effective values" do
      account_id = nil
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"localization": {"default_timezone": "Australia/Sydney"}}))
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Asia/Tokyo"))
      end

      request = HTTP::Request.new("GET", "/Api/settings/core", headers: auth_cookie_header(account_id.as(String)))
      response = call_api(request)

      assert_http_status(response, 200)
      json = JSON.parse(response.body)
      json["defaults"]["timezone"].to_s.should eq("Australia/Sydney")
      json["defaults"]["language"].to_s.should eq("en")
      # Keys with no server mapping keep their registry defaults.
      json["defaults"]["pinned_doctypes"].as_a.should be_empty
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  describe "DELETE /Api/settings/:app/:key" do
    it "returns 401 without authentication" do
      headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
      request = HTTP::Request.new("DELETE", "/Api/settings/core/timezone", headers: headers)
      response = call_api(request)

      assert_http_status(response, 401)
    end

    it "returns 403 without X-Requested-With header (CSRF)" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
      end

      request = HTTP::Request.new("DELETE", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      # Raw dispatch — `call_api` would add the browser default header.
      response = call_api_raw(request)

      JSON.parse(response.body)["error"].to_s.should contain("CSRF")
    end

    it "removes the row and answers 204" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
        Facet::Settings::Service.update(db, account_id, "core", "timezone", JSON::Any.new("Europe/Paris"))
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("DELETE", "/Api/settings/core/timezone", headers: headers)
      response = call_api(request)

      assert_http_status(response, 204)

      # The value fell back to the default chain.
      read_request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_id.as(String)))
      read_response = call_api(read_request)
      JSON.parse(read_response.body)["value"].to_s.should eq("auto")
    end

    it "is idempotent — deleting a missing row still answers 204" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("DELETE", "/Api/settings/core/timezone", headers: headers)
      response = call_api(request)
      assert_http_status(response, 204)

      second = call_api(HTTP::Request.new("DELETE", "/Api/settings/core/timezone",
        headers: headers))
      assert_http_status(second, 204)
    end

    it "returns 404 for an unregistered key" do
      account_id = nil
      with_db do |db|
        account_id = create_test_account(db)
      end

      headers = auth_cookie_header(account_id.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("DELETE", "/Api/settings/core/nonexistent", headers: headers)
      response = call_api(request)

      assert_http_status(response, 404)
      JSON.parse(response.body)["error"].to_s.should contain("Unknown setting")
    end

    it "is isolated — one account cannot delete another account's row" do
      account_a = nil
      account_b = nil
      with_db do |db|
        account_a = create_test_account(db, email: "a@example.com")
        account_b = create_test_account(db, email: "b@example.com")
        Facet::Settings::Service.update(db, account_b, "core", "timezone", JSON::Any.new("Europe/Paris"))
      end

      # A deletes its own (missing) timezone row; B's row is untouched.
      headers = auth_cookie_header(account_a.as(String))
      headers["X-Requested-With"] = "XMLHttpRequest"
      request = HTTP::Request.new("DELETE", "/Api/settings/core/timezone", headers: headers)
      response = call_api(request)
      assert_http_status(response, 204)

      read_request = HTTP::Request.new("GET", "/Api/settings/core/timezone", headers: auth_cookie_header(account_b.as(String)))
      read_response = call_api(read_request)
      JSON.parse(read_response.body)["value"].to_s.should eq("Europe/Paris")
    end
  end
end
