# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "openssl/hmac"
require "../../src/webhook/dispatcher"

# Dispatcher (execute path) — pure transport, no real network, no DB.
#
# The transport is stubbed by overriding `Dispatcher#post` in a recording
# subclass: every spec scripts the canned response (or the raised error)
# and asserts on the recorded request. The signature / merge rules are
# asserted through `build_signed_request` plus the recorded headers.
#
# By inspection (plan row): `src/webhook/dispatcher.cr` requires nothing
# from `rbac/`, `iam/`, or `document/` — no `AuthContext` build, no
# projection read. The class doc carries that contract.

private class RecordingDispatcher < Facet::Webhook::Dispatcher
  record Sent, uri : URI, body : String, headers : HTTP::Headers

  getter sent : Array(Sent) = [] of Sent
  property next_response : HTTP::Client::Response = HTTP::Client::Response.new(200)
  property next_error : Exception? = nil

  protected def post(uri : URI, body : String, headers : HTTP::Headers) : HTTP::Client::Response
    @sent << Sent.new(uri, body, headers)
    if error = @next_error
      raise error
    end
    @next_response
  end
end

SECRET = "TESTSECRET00000000000000000000"

private def build_payload(
  url : String = "https://receiver.example/hook",
  secret : String = SECRET,
  headers : JSON::Any? = nil,
  mutation_id : String? = "01JMUTATION0000000000000000",
) : Facet::Webhook::Payload
  Facet::Webhook::Payload.new(
    webhook_id: "core.Webhook.wh-1",
    delivery_id: "01JDELIVERY000000000000000",
    event: "updated",
    domain: "accountancy",
    doc_type: "Contract",
    doc_id: "accountancy.Contract.abc",
    mutation_id: mutation_id,
    actioner_id: "iam.Account.user-1",
    cause: nil,
    content: JSON.parse(%({"id": "accountancy.Contract.abc"})),
    emitted_at: "2026-09-01T12:00:00Z",
    url: url,
    secret: secret,
    headers: headers,
  )
end

private def stub_job(payload : Facet::Webhook::Payload) : Facet::Jobs::Job
  Facet::Jobs::Job.new(
    id: payload.delivery_id,
    kind: "webhook_delivery",
    payload: JSON.parse(payload.to_json),
    attempts: 1,
    max_attempts: 5,
    backoff: [10, 60, 300, 1800, 7200],
  )
end

# Swaps the singleton config with one whose `webhook` section is replaced.
# Restores the original afterwards (mirrors spec/oauth/dpop_spec.cr).
private def with_webhook_config(webhook : Facet::Config::WebhookConfig, &)
  original = Facet::Config.instance
  temp = Facet::Config.new(
    snapshot_every: original.snapshot_every,
    iam: original.iam,
    event: original.event,
    host: original.host,
    base_url: original.base_url,
    artifact_base_url: original.artifact_base_url,
    artifact_grant_secret: original.artifact_grant_secret,
    artifact_grant_secret_previous: original.artifact_grant_secret_previous,
    artifact: original.artifact,
    domains: original.domains,
    mail: original.mail,
    assistant: original.assistant,
    lua: original.lua,
    hooks: original.hooks,
    jobs: original.jobs,
    webhook: webhook,
    mcp: original.mcp,
    sidecar: original.sidecar,
    tombstone: original.tombstone,
    cache: original.cache,
  )
  Facet::Config.instance = temp
  result = yield
  result
ensure
  Facet::Config.instance = original if original
end

describe Facet::Webhook::Dispatcher do
  it "constructs with no arguments (Jobs::Handler contract)" do
    Facet::Webhook::Dispatcher.new.should be_a(Facet::Webhook::Dispatcher)
  end

  it "reads the retry defaults from the webhook config" do
    Facet::Webhook::Dispatcher.default_max_attempts
      .should eq(Facet::Config.instance.webhook.max_attempts)
    Facet::Webhook::Dispatcher.default_backoff
      .should eq(Facet::Config.instance.webhook.backoff_seconds)
  end

  describe "build_signed_request" do
    it "signs the raw body with the payload secret alone" do
      payload = build_payload
      body, headers = Facet::Webhook::Dispatcher.build_signed_request(payload)

      signature = headers["X-Facet-Signature"]
      signature.should start_with("sha256=")
      signature.should eq("sha256=" + OpenSSL::HMAC.hexdigest(:sha256, SECRET, body))
    end

    it "emits lowercase hex in the signature" do
      _body, headers = Facet::Webhook::Dispatcher.build_signed_request(build_payload)
      hex = headers["X-Facet-Signature"].lchop("sha256=")
      hex.should match(/\A[0-9a-f]{64}\z/)
    end

    it "strips the transport-only fields from the body" do
      payload = build_payload(
        url: "https://receiver.example/hook",
        headers: JSON.parse(%({"X-Routing": "tier-1"})),
      )
      body, _headers = Facet::Webhook::Dispatcher.build_signed_request(payload)

      keys = JSON.parse(body).as_h.keys
      keys.should eq(%w[
        webhook_id delivery_id event domain doc_type doc_id
        mutation_id actioner_id cause content emitted_at
      ])
      keys.should_not contain("url")
      keys.should_not contain("secret")
      keys.should_not contain("headers")
    end
  end

  describe "execute" do
    it "sends the Facet-mandated headers with the default Content-Type and User-Agent" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(200)

      dispatcher.execute(stub_job(build_payload))

      sent = dispatcher.sent.first
      sent.headers["Content-Type"].should eq("application/json")
      sent.headers["User-Agent"].should eq("Facet-Webhook/1.0")
      sent.headers["X-Facet-Event"].should eq("updated")
      sent.headers["X-Facet-Delivery"].should eq("01JDELIVERY000000000000000")
      sent.headers["X-Facet-Webhook-Id"].should eq("core.Webhook.wh-1")
      sent.headers["X-Facet-Mutation-Id"].should eq("01JMUTATION0000000000000000")
      sent.headers["X-Facet-Origin"].should eq("webhooks:core.Webhook.wh-1")
      sent.uri.to_s.should eq("https://receiver.example/hook")
    end

    it "omits X-Facet-Mutation-Id when the payload carries none" do
      dispatcher = RecordingDispatcher.new
      dispatcher.execute(stub_job(build_payload(mutation_id: nil)))
      dispatcher.sent.first.headers["X-Facet-Mutation-Id"]?.should be_nil
    end

    it "lets custom headers override Content-Type and User-Agent" do
      custom = JSON.parse(%({
        "Content-Type": "application/vnd.facet.v1+json",
        "User-Agent": "Facet-Proxy/2.0"
      }))
      dispatcher = RecordingDispatcher.new
      dispatcher.execute(stub_job(build_payload(headers: custom)))

      sent = dispatcher.sent.first
      sent.headers["Content-Type"].should eq("application/vnd.facet.v1+json")
      sent.headers["User-Agent"].should eq("Facet-Proxy/2.0")
    end

    it "ignores custom X-Facet-* keys — the Facet value wins" do
      custom = JSON.parse(%({"X-Facet-Signature": "attacker"}))
      dispatcher = RecordingDispatcher.new
      dispatcher.execute(stub_job(build_payload(headers: custom)))

      sent = dispatcher.sent.first
      expected = "sha256=" + OpenSSL::HMAC.hexdigest(:sha256, SECRET, sent.body)
      sent.headers["X-Facet-Signature"].should eq(expected)
    end

    it "maps an HTTP 2xx to Succeeded with the status code" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(200)

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      result.http_status.should eq(200)
      result.error.should be_nil
    end

    it "maps HTTP >= 400 to Failed with the status code" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(500)

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.http_status.should eq(500)
    end

    it "maps a transport error to Failed with the error and no status" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_error = IO::TimeoutError.new("connect timeout")

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.http_status.should be_nil
      result.error.should eq("connect timeout")
      # No response, no body — but the time to the failure is measured.
      result.response_body.should be_nil
      result.duration_ms.should_not be_nil
    end

    it "captures a text response body into the result" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(201, body: "created")

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      result.response_body.should eq("created")
      result.duration_ms.should_not be_nil
    end

    it "captures the body of a failed response too" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(500, body: "boom")

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.response_body.should eq("boom")
    end

    it "skips a binary response body" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(
        200,
        body: "\xFF\xFE\x00\x01",
        headers: HTTP::Headers{"Content-Type" => "image/png"},
      )

      result = dispatcher.execute(stub_job(build_payload))

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      result.response_body.should be_nil
    end

    it "captures a JSON body regardless of parameters on the Content-Type" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(
        200,
        body: %({"ok": true}),
        headers: HTTP::Headers{"Content-Type" => "application/json; charset=utf-8"},
      )

      result = dispatcher.execute(stub_job(build_payload))

      result.response_body.should eq(%({"ok": true}))
    end

    it "truncates the response body above 4 KB with the marker" do
      dispatcher = RecordingDispatcher.new
      dispatcher.next_response = HTTP::Client::Response.new(200, body: "a" * 5000)

      result = dispatcher.execute(stub_job(build_payload))

      body = result.response_body.not_nil!
      body.should end_with("… [truncated]")
      body.bytesize.should eq(
        Facet::Webhook::Dispatcher::MAX_RESPONSE_BODY_BYTES + "… [truncated]".bytesize
      )
    end

    it "never raises — a malformed payload yields a Failed result" do
      dispatcher = RecordingDispatcher.new
      malformed = Facet::Jobs::Job.new(
        id: "01JBROKEN00000000000000000",
        kind: "webhook_delivery",
        payload: JSON.parse(%({})),
        attempts: 1,
        max_attempts: 5,
        backoff: nil,
      )

      result = dispatcher.execute(malformed)

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.should_not be_nil
      dispatcher.sent.should be_empty
    end

    it "rejects a non-https target URL by default" do
      dispatcher = RecordingDispatcher.new
      result = with_webhook_config(Facet::Config::WebhookConfig.new(allowed_hosts: ["receiver.example"])) do
        dispatcher.execute(stub_job(build_payload(url: "http://receiver.example/hook")))
      end

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.http_status.should be_nil
      result.error.not_nil!.should contain("insecure")
      dispatcher.sent.should be_empty
    end

    it "permits a non-https target when allow_insecure_urls is true" do
      dispatcher = RecordingDispatcher.new
      result = with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true, allowed_hosts: ["receiver.example"])) do
        dispatcher.execute(stub_job(build_payload(url: "http://receiver.example/hook")))
      end

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      dispatcher.sent.size.should eq(1)
    end

    it "rejects a target whose host resolves to a loopback address (B-76)" do
      dispatcher = RecordingDispatcher.new
      result = with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true)) do
        dispatcher.execute(stub_job(build_payload(url: "http://127.0.0.1:9/hook")))
      end

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("private, loopback")
      dispatcher.sent.should be_empty
    end

    it "rejects a target whose host does not resolve (B-76)" do
      dispatcher = RecordingDispatcher.new
      result = with_webhook_config(Facet::Config::WebhookConfig.new) do
        dispatcher.execute(stub_job(build_payload(url: "https://b76-does-not-resolve.invalid/hook")))
      end

      result.status.should eq(Facet::Jobs::Handler::Kind::Failed)
      result.error.not_nil!.should contain("does not resolve")
      dispatcher.sent.should be_empty
    end

    it "dials a target whose host is on the allowed_hosts list even though it resolves private" do
      dispatcher = RecordingDispatcher.new
      result = with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true, allowed_hosts: ["127.0.0.1"])) do
        dispatcher.execute(stub_job(build_payload(url: "http://127.0.0.1:9/hook")))
      end

      result.status.should eq(Facet::Jobs::Handler::Kind::Succeeded)
      dispatcher.sent.size.should eq(1)
    end
  end

  describe "response-body capture helpers" do
    it "treats an absent Content-Type as text" do
      Facet::Webhook::Dispatcher.text_body?(HTTP::Headers.new).should be_true
    end

    it "treats JSON, XML and plain text as text, denylisted media types as binary" do
      Facet::Webhook::Dispatcher.text_body?(HTTP::Headers{"Content-Type" => "application/json"}).should be_true
      Facet::Webhook::Dispatcher.text_body?(HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"}).should be_true
      Facet::Webhook::Dispatcher.text_body?(HTTP::Headers{"Content-Type" => "application/octet-stream"}).should be_false
      Facet::Webhook::Dispatcher.text_body?(HTTP::Headers{"Content-Type" => "image/png"}).should be_false
    end

    it "leaves a body at or under the cap untouched" do
      body = "a" * Facet::Webhook::Dispatcher::MAX_RESPONSE_BODY_BYTES
      Facet::Webhook::Dispatcher.truncate_body(body).should eq(body)
    end
  end
end
