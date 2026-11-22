# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/rbac"
require "../../src/document"
require "../../src/mutation/client"
require "../support/webhook_helper"

# ── Helpers ────────────────────────────────────────────────────────────────

# An authenticated context whose role grants `create` on `core.Webhook`
# (unrestricted) and `read` on `core.DocType`. The read grant is required by
# the reference check: `core.Webhook.source_doctype` targets `core.DocType`
# with `dangling: false`, and since B-356 the reference check verifies the
# target under the caller's read scope. A webhook author therefore holds the
# metadata read grant. `role_id` is the value the create hook stamps into the
# document's `role_id` field.
def webhook_actor(account_id : String, role_id : String) : Facet::RBAC::AuthContext
  create_webhook = Facet::RBAC::Permission.new(action: "create", domain: "core", path: ["Webhook"])
  read_doctype = Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["DocType"])
  role = Facet::RBAC::ActiveRole.new(
    role_id: role_id,
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [create_webhook, read_doctype],
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Minimal authoring body: only the fields a caller must supply. The create
# hook stamps `secret`; defaults fill `enabled`.
WEBHOOK_BASE_BODY = {
  "label"          => "Relay",
  "url"            => "https://receiver.example.com/hook",
  "source_doctype" => "core.DocType.iam.LoginEvent",
}

def stored_webhook_content(db, doc_id : String) : Hash(String, JSON::Any)
  content = Facet::Mutation::Client.fetch_content(db, "core", "Webhook", doc_id)
  content.as_h.not_nil!
end

# Creates a webhook as the system bypass and fails the example on error.
def create_system_webhook(db, doc_id : String, body : String = WEBHOOK_BASE_BODY.to_json, allow_system_writes : Bool = false) : Nil
  result = Facet::Document::Create.call(
    db, "core", "Webhook", body,
    Facet::RBAC::AuthContext.system,
    doc_id: doc_id,
    allow_system_writes: allow_system_writes,
  )
  case result
  in Facet::Document::Create::Result
    # created
  in Facet::ServiceError
    details = result.details.try(&.map(&.message).join("; ")) || ""
    fail "Webhook create failed: #{result.message} #{details}"
  end
end

module Facet
  describe "core.Webhook doctype (seed)" do
    # The global per-example truncation wipes `projections`, removing the
    # template database's seeded doctypes. Re-ensure (idempotent) the
    # doctypes this file touches — the service layer (`Document::Create`)
    # needs each target doctype's definition row, and the webhook's
    # reference fields need live `iam.Roles` rows. Scoped `ensure_doctype`
    # calls keep the per-example cost at ~10 ms instead of a full-corpus
    # re-seed.
    before_each do
      with_db do |db|
        ensure_seed_roles_with_dependencies(db)
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "LoginEvent")
        Facet::Doctype::DefinitionStore.cache.clear
      end
    end

    it "is registered by Doctype::Seed" do
      with_db do |db|
        Doctype::DefinitionStore.fetch(db, "core.Webhook").should_not be_nil
      end
    end

    it "create stamps the secret and binds the actioner identity" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_1", "wh_role_1")
        result = Document::Create.call(
          db, "core", "Webhook", WEBHOOK_BASE_BODY.to_json, ctx,
          doc_id: "wh_doc_1",
        )
        case result
        in Document::Create::Result
          content = stored_webhook_content(db, "wh_doc_1")
          secret = content["secret"]?.try(&.as_s)
          secret.should_not be_nil
          # A ULID is 26 characters — well past the schema's min: 16.
          secret.not_nil!.size.should be >= 26
          # Reference fields normalize to the fully qualified storage form
          # after the hook stamps the bare actor ids.
          content["account_id"]?.try(&.as_s).should eq("iam.Account.wh_actor_1")
          content["role_id"]?.try(&.as_s).should eq("iam.Roles.wh_role_1")
          content["enabled"]?.try(&.as_bool).should be_true
        in Facet::ServiceError
          details = result.details.try(&.map(&.message).join("; ")) || ""
          fail "create failed: #{result.message} #{details}"
        end
      end
    end

    # The read_only gate is the first line of defence: a real principal can
    # never place a value the hook would have to overwrite. The fields are
    # known (not unknown), so the rejection comes from check_readonly_fields.
    ["secret", "account_id", "role_id"].each do |field|
      it "create rejects caller-supplied #{field} for a real principal" do
        with_db do |db|
          ctx = webhook_actor("wh_actor_2", "wh_role_2")
          body = WEBHOOK_BASE_BODY.merge({field => "attacker"}).to_json
          result = Document::Create.call(
            db, "core", "Webhook", body, ctx,
            doc_id: "wh_reject_#{field}",
          )
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          codes = err.details.try(&.map(&.code)) || [] of String?
          codes.should contain("read_only")
        end
      end
    end

    it "create overwrites a caller-supplied secret when the system write gate is open (the hook always wins)" do
      with_db do |db|
        body = WEBHOOK_BASE_BODY.merge({"secret" => "attacker-secret-value"}).to_json
        create_system_webhook(db, "wh_doc_3", body, allow_system_writes: true)
        content = stored_webhook_content(db, "wh_doc_3")
        secret = content["secret"]?.try(&.as_s)
        secret.should_not be_nil
        secret.not_nil!.should_not eq("attacker-secret-value")
        secret.not_nil!.size.should be >= 26
      end
    end

    # The standard (non-reentrant) update path rejects read_only fields at
    # validation, before the hook runs. The hook's own immutability checks
    # are defence in depth for paths that allow system writes (reentrant
    # mutations) — those must still fail with the hook's message.
    it "update rejects PATCH to secret through the read_only gate (422)" do
      with_db do |db|
        create_system_webhook(db, "wh_upd_gate")
        result = Document::Update.call(
          db, "core", "Webhook", "wh_upd_gate",
          %({"secret": "new-secret"}),
          RBAC::AuthContext.system,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        codes = err.details.try(&.map(&.code)) || [] of String?
        codes.should contain("read_only")
      end
    end

    ["account_id", "role_id", "secret"].each do |field|
      it "update rejects PATCH to #{field} with the hook's message" do
        with_db do |db|
          create_system_webhook(db, "wh_upd_#{field}")
          # The patch must pass the reference existence check before the
          # hook runs, so reference fields carry real target rows. Role
          # projections use qualified ids ("iam.Roles.admin"), so the
          # reference value is the field prefix plus that full row id.
          patch_value = case field
                        when "account_id" then create_test_account(db)
                        when "role_id"    then "iam.Roles.iam.Roles.admin"
                        else                   "tampered-payload-0000"
                        end
          patch = {field => patch_value}.to_json
          result = Document::Update.call(
            db, "core", "Webhook", "wh_upd_#{field}",
            patch,
            RBAC::AuthContext.system,
            reentrant: true,
          )
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("immutable after creation")
        end
      end
    end

    it "create rejects a source_doctype pointing at a non-existent doctype" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_3", "wh_role_3")
        body = WEBHOOK_BASE_BODY.merge({"source_doctype" => "core.DocType.nope"}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_dangling",
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        codes = err.details.try(&.map(&.code)) || [] of String?
        codes.should contain("reference_filter_mismatch")
      end
    end

    # The `headers` authoring rules: reserved `X-Facet-*` keys (any case),
    # non-token key names, and non-string values are rejected with 422 so
    # the dispatcher's runtime header merge never has to defend against
    # malformed or spoofing entries.
    it "create rejects an X-Facet-* headers key (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_4", "wh_role_4")
        body = WEBHOOK_BASE_BODY.merge({"headers" => {"X-Facet-Signature" => "attacker"}}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_headers_reserved",
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("X-Facet-")
      end
    end

    it "create rejects an X-Facet-* headers key regardless of case (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_5", "wh_role_5")
        body = WEBHOOK_BASE_BODY.merge({"headers" => {"x-facet-signature" => "attacker"}}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_headers_reserved_lower",
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("X-Facet-")
      end
    end

    it "create rejects a headers key outside the field-name grammar (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_6", "wh_role_6")
        body = WEBHOOK_BASE_BODY.merge({"headers" => {"bad key" => "tier-1"}}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_headers_token",
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("RFC 7230")
      end
    end

    it "create rejects a non-string headers value (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_7", "wh_role_7")
        body = WEBHOOK_BASE_BODY.merge({"headers" => {"X-Trace" => 42}}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_headers_nonstring",
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("must be strings")
      end
    end

    it "create accepts well-formed custom headers" do
      with_db do |db|
        ctx = webhook_actor("wh_actor_8", "wh_role_8")
        body = WEBHOOK_BASE_BODY.merge({"headers" => {"X-Trace" => "tier-1", "Authorization" => "Bearer tok"}}).to_json
        result = Document::Create.call(
          db, "core", "Webhook", body, ctx,
          doc_id: "wh_headers_ok",
        )
        case result
        in Document::Create::Result
          content = stored_webhook_content(db, "wh_headers_ok")
          content["headers"]?.try(&.as_h["X-Trace"]?.try(&.as_s)).should eq("tier-1")
        in Facet::ServiceError
          details = result.details.try(&.map(&.message).join("; ")) || ""
          fail "create failed: #{result.message} #{details}"
        end
      end
    end

    it "update rejects a PATCH that adds an X-Facet-* headers key (422)" do
      with_db do |db|
        create_system_webhook(db, "wh_upd_headers")
        patch = %({"headers": {"X-Trace": "ok", "X-Facet-Event": "spoofed"}})
        result = Document::Update.call(
          db, "core", "Webhook", "wh_upd_headers",
          patch,
          RBAC::AuthContext.system,
          reentrant: true,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("X-Facet-")
      end
    end

    # The target-URL scheme rule: with `webhook.allow_insecure_urls` false
    # (the default), an `http://` target is rejected at authoring time with
    # the dispatcher's message — a webhook the server would never deliver
    # to must not be creatable (run-24 finding B-77). With the flag on,
    # plain http is accepted (dev/test).
    it "create rejects an http target URL when insecure URLs are not allowed (422)" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new) do
          ctx = webhook_actor("wh_actor_9", "wh_role_9")
          body = WEBHOOK_BASE_BODY.merge({"url" => "http://receiver.example.com/hook"}).to_json
          result = Document::Create.call(
            db, "core", "Webhook", body, ctx,
            doc_id: "wh_url_insecure",
          )
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("insecure webhook target URL rejected")
        end
      end
    end

    it "create accepts an http target URL when allow_insecure_urls is true" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true, allowed_hosts: ["receiver.example.com"])) do
          ctx = webhook_actor("wh_actor_10", "wh_role_10")
          body = WEBHOOK_BASE_BODY.merge({"url" => "http://receiver.example.com/hook"}).to_json
          result = Document::Create.call(
            db, "core", "Webhook", body, ctx,
            doc_id: "wh_url_insecure_ok",
          )
          case result
          in Document::Create::Result
            content = stored_webhook_content(db, "wh_url_insecure_ok")
            content["url"]?.try(&.as_s).should eq("http://receiver.example.com/hook")
          in Facet::ServiceError
            details = result.details.try(&.map(&.message).join("; ")) || ""
            fail "create failed: #{result.message} #{details}"
          end
        end
      end
    end

    # The target-host rule (B-76): the host must resolve public. These
    # drive the gate through IP literals (no DNS) plus one RFC 2606 name
    # that can never resolve, in any environment. The Lua hook words the
    # rejection generically (it cannot know which check failed — scheme
    # and host are separate bindings); the specific texts live on
    # `TargetCheck` and surface at delivery/test time.
    it "create rejects a loopback IP-literal target (422)" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true)) do
          ctx = webhook_actor("wh_actor_11", "wh_role_11")
          body = WEBHOOK_BASE_BODY.merge({"url" => "http://127.0.0.1:9/hook"}).to_json
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_loopback")
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("host must resolve to a public")
        end
      end
    end

    it "create rejects an IPv4-mapped loopback target (422)" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true)) do
          ctx = webhook_actor("wh_actor_12", "wh_role_12")
          body = WEBHOOK_BASE_BODY.merge({"url" => "http://[::ffff:127.0.0.1]/hook"}).to_json
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_mapped")
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("host must resolve to a public")
        end
      end
    end

    it "create rejects a metadata-range IP-literal target (422)" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new) do
          ctx = webhook_actor("wh_actor_13", "wh_role_13")
          body = WEBHOOK_BASE_BODY.merge({"url" => "https://169.254.169.254/latest/meta-data/"}).to_json
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_metadata")
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("host must resolve to a public")
        end
      end
    end

    it "create rejects a host that does not resolve (422)" do
      with_fake_resolver do
        with_db do |db|
          with_webhook_config(Facet::Config::WebhookConfig.new) do
            ctx = webhook_actor("wh_actor_14", "wh_role_14")
            body = WEBHOOK_BASE_BODY.merge({"url" => "https://b76-does-not-resolve.invalid/hook"}).to_json
            result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_unresolved")
            err = result.as(Facet::ServiceError)
            err.status.should eq(422)
            messages = err.details.try(&.map(&.message).join("; ")) || ""
            messages.should contain("does not resolve")
          end
        end
      end
    end

    it "create accepts a public IP-literal target" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new) do
          ctx = webhook_actor("wh_actor_15", "wh_role_15")
          body = WEBHOOK_BASE_BODY.merge({"url" => "https://1.1.1.1/hook"}).to_json
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_public_literal")
          case result
          in Document::Create::Result
            content = stored_webhook_content(db, "wh_public_literal")
            content["url"]?.try(&.as_s).should eq("https://1.1.1.1/hook")
          in Facet::ServiceError
            details = result.details.try(&.map(&.message).join("; ")) || ""
            fail "create failed: #{result.message} #{details}"
          end
        end
      end
    end

    it "create accepts an internal target named on webhook.allowed_hosts" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new(allow_insecure_urls: true, allowed_hosts: ["10.0.0.0/8"])) do
          ctx = webhook_actor("wh_actor_16", "wh_role_16")
          body = WEBHOOK_BASE_BODY.merge({"url" => "http://10.1.2.3:8080/hook"}).to_json
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_allowed")
          case result
          in Document::Create::Result
            stored_webhook_content(db, "wh_allowed")["url"]?.try(&.as_s).should eq("http://10.1.2.3:8080/hook")
          in Facet::ServiceError
            details = result.details.try(&.map(&.message).join("; ")) || ""
            fail "create failed: #{result.message} #{details}"
          end
        end
      end
    end

    it "update rejects a PATCH that sets an http target URL (422)" do
      with_db do |db|
        with_webhook_config(Facet::Config::WebhookConfig.new(allowed_hosts: ["receiver.example.com"])) do
          create_system_webhook(db, "wh_upd_url")
          result = Document::Update.call(
            db, "core", "Webhook", "wh_upd_url",
            %({"url": "http://receiver.example.com/hook"}),
            RBAC::AuthContext.system,
            reentrant: true,
          )
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          messages = err.details.try(&.map(&.message).join("; ")) || ""
          messages.should contain("insecure webhook target URL rejected")
        end
      end
    end

    # ── The `events` authoring gate (B-152) ──────────────────────────
    #
    # The event vocabulary is closed. The hook validates every entry
    # against `util.webhook_event_names` on both authoring paths, so a
    # typo'd name ("document.created") cannot create a webhook that
    # silently never fires. An empty list stays valid — it means "fire on
    # nothing" (the dispatch filter treats it as opt-out); a field absent
    # from the body arrives as nil and skips the gate.
    it "create accepts events naming a mutation verb" do
      with_db do |db|
        ctx = webhook_actor("wh_ev_verb", "wh_ev_role_verb")
        body = WEBHOOK_BASE_BODY.merge({"events" => ["created"]}).to_json
        result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_ev_verb")
        case result
        in Document::Create::Result
          events = stored_webhook_content(db, "wh_ev_verb")["events"]?.try(&.as_a.map(&.as_s))
          events.should eq(["created"])
        in Facet::ServiceError
          details = result.details.try(&.map(&.message).join("; ")) || ""
          fail "create failed: #{result.message} #{details}"
        end
      end
    end

    # One success case per opt-in event class: the private notification
    # event, the aggregate child-change event, and one job-lifecycle name.
    ["notified", "child_changed", "import_completed"].each do |event_name|
      it "create accepts the opt-in event '#{event_name}'" do
        with_db do |db|
          ctx = webhook_actor("wh_ev_opt", "wh_ev_role_opt")
          body = WEBHOOK_BASE_BODY.merge({"events" => [event_name]}).to_json
          doc_id = "wh_ev_opt_#{event_name}"
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: doc_id)
          case result
          in Document::Create::Result
            events = stored_webhook_content(db, doc_id)["events"]?.try(&.as_a.map(&.as_s))
            events.should eq([event_name])
          in Facet::ServiceError
            details = result.details.try(&.map(&.message).join("; ")) || ""
            fail "create failed: #{result.message} #{details}"
          end
        end
      end
    end

    # The reconciler's snapshot arm also derives these two event names
    # (`Document::Migrate`, `Audit::Rollback`), so they are real
    # webhook-visible events and sit in the vocabulary with the verbs.
    ["migrated", "rolled_back"].each do |event_name|
      it "create accepts the repair event '#{event_name}'" do
        with_db do |db|
          ctx = webhook_actor("wh_ev_repair", "wh_ev_role_repair")
          body = WEBHOOK_BASE_BODY.merge({"events" => [event_name]}).to_json
          doc_id = "wh_ev_repair_#{event_name}"
          result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: doc_id)
          case result
          in Document::Create::Result
            events = stored_webhook_content(db, doc_id)["events"]?.try(&.as_a.map(&.as_s))
            events.should eq([event_name])
          in Facet::ServiceError
            details = result.details.try(&.map(&.message).join("; ")) || ""
            fail "create failed: #{result.message} #{details}"
          end
        end
      end
    end

    it "create rejects an unknown event name with the vocabulary in the message (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_ev_bad", "wh_ev_role_bad")
        body = WEBHOOK_BASE_BODY.merge({"events" => ["document.created"]}).to_json
        result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_ev_bad")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("unknown event name 'document.created'")
        # The message lists the allowed names, so the author can self-correct.
        messages.should contain("created, updated, deleted")
      end
    end

    it "update rejects a PATCH that sets an unknown event name (422)" do
      with_db do |db|
        create_system_webhook(db, "wh_upd_events")
        result = Document::Update.call(
          db, "core", "Webhook", "wh_upd_events",
          %({"events": ["document.created"]}),
          RBAC::AuthContext.system,
          reentrant: true,
        )
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("unknown event name 'document.created'")
      end
    end

    it "create accepts an empty events list (fire on nothing)" do
      with_db do |db|
        ctx = webhook_actor("wh_ev_empty", "wh_ev_role_empty")
        body = WEBHOOK_BASE_BODY.merge({"events" => [] of String}).to_json
        result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_ev_empty")
        case result
        in Document::Create::Result
          events = stored_webhook_content(db, "wh_ev_empty")["events"]?.try(&.as_a)
          events.should eq([] of JSON::Any)
        in Facet::ServiceError
          details = result.details.try(&.map(&.message).join("; ")) || ""
          fail "create failed: #{result.message} #{details}"
        end
      end
    end

    # The array field type rejects a non-string entry at validation, before
    # the hook runs — the 422 contract is what matters, whichever gate
    # answers first.
    it "create rejects a non-string events entry (422)" do
      with_db do |db|
        ctx = webhook_actor("wh_ev_nonstr", "wh_ev_role_nonstr")
        body = WEBHOOK_BASE_BODY.merge({"events" => ["created", 42]}).to_json
        result = Document::Create.call(db, "core", "Webhook", body, ctx, doc_id: "wh_ev_nonstr")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
      end
    end

    it "system-bypass create stamps only the secret; the binding stays unset" do
      with_db do |db|
        create_system_webhook(db, "wh_sys_1")
        content = stored_webhook_content(db, "wh_sys_1")
        secret = content["secret"]?.try(&.as_s)
        secret.should_not be_nil
        secret.not_nil!.size.should be >= 26
        content["account_id"]?.should be_nil
        content["role_id"]?.should be_nil
      end
    end

    # ── The connectivity authoring gate (role channels) ──────────────
    #
    # Webhook authoring is open by permission shape (B-76 ownership
    # arbitration), but the actioner's active role must carry the
    # `webhook` connectivity channel. A role whose list excludes it gets
    # a clear 422; a role without the channel can never deliver (the
    # enqueue gate skips with `ChannelClosed`), so the refusal lands at
    # authoring time. System bypass callers are exempt (seeding stamps
    # bindings later).
    it "create refuses a real actor whose role's connectivity excludes the webhook channel (422)" do
      with_db do |db|
        # A real role projection with an explicitly empty list — the
        # browser-only shape.
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
        Facet::Doctype::DefinitionStore.cache.clear
        Facet::Mutation::Client.create(
          db, "iam", "Roles", doc_id: "iam.Roles.wh_channelless",
          content: %({"name": "wh_channelless", "description": "Browser-only role", "visible_tags": ["default"], "connectivity": [], "permissions": [{"action": "create", "on": "*.*"}]}),
          actioner_id: "system",
        )

        # The role also needs `read core.DocType`: `source_doctype` targets
        # `core.DocType` with `dangling: false`, and since B-356 the reference
        # check runs under the caller's read scope. The gate under test is the
        # connectivity check, so the read grant must be present.
        perm = Facet::RBAC::Permission.new(action: "create", domain: "core", path: ["Webhook"])
        read_doctype = Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["DocType"])
        role = Facet::RBAC::ActiveRole.new(
          role_id: "iam.Roles.wh_channelless",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [perm, read_doctype],
        )
        ctx = Facet::RBAC::AuthContext.authenticated("wh_actor_ch", role)

        result = Document::Create.call(db, "core", "Webhook", WEBHOOK_BASE_BODY.to_json, ctx,
          doc_id: "wh_channelless")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("connectivity excludes")
      end
    end

    it "create accepts a real actor whose role carries the webhook channel" do
      with_db do |db|
        # The full-list role: create through the pipeline so the row exists
        # (the in-memory actor role would pass the gate's missing-projection
        # branch — here we exercise the positive branch against the DB).
        Facet::Doctype::Seed.ensure_doctype(db, "iam", "Roles")
        Facet::Doctype::DefinitionStore.cache.clear
        Facet::Mutation::Client.create(
          db, "iam", "Roles", doc_id: "iam.Roles.wh_channeled",
          content: %({"name": "wh_channeled", "description": "Full-channel role", "visible_tags": ["default"], "connectivity": ["mcp", "webhook", "api", "assistant"], "permissions": [{"action": "create", "on": "*.*"}]}),
          actioner_id: "system",
        )

        # The role also needs `read core.DocType` for the `source_doctype`
        # reference check (B-356) — the gate under test is the channel one.
        perm = Facet::RBAC::Permission.new(action: "create", domain: "core", path: ["Webhook"])
        read_doctype = Facet::RBAC::Permission.new(action: "read", domain: "core", path: ["DocType"])
        role = Facet::RBAC::ActiveRole.new(
          role_id: "iam.Roles.wh_channeled",
          visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [perm, read_doctype],
        )
        ctx = Facet::RBAC::AuthContext.authenticated("wh_actor_ch2", role)

        result = Document::Create.call(db, "core", "Webhook", WEBHOOK_BASE_BODY.to_json, ctx,
          doc_id: "wh_channeled")
        case result
        in Document::Create::Result
          stored_webhook_content(db, "wh_channeled")["role_id"]?.try(&.as_s)
            .should eq("iam.Roles.wh_channeled")
        in Facet::ServiceError
          details = result.details.try(&.map(&.message).join("; ")) || ""
          fail "create failed: #{result.message} #{details}"
        end
      end
    end

    # F07-01: the seeded `editor` role must not be able to open an outbound
    # webhook. Its connectivity list excludes the `webhook` channel, so the
    # create hook refuses with 422 even though its blanket `create *.*` line
    # covers `core.Webhook` by permission shape.
    it "create refuses the seeded editor role (connectivity excludes the webhook channel, 422)" do
      with_db do |db|
        restore_seeded_baseline(db)
        ensure_iam_account(db, "wh_editor_actor")

        role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
        role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
        ctx = Facet::RBAC::AuthContext.authenticated("wh_editor_actor", role)

        result = Document::Create.call(db, "core", "Webhook", WEBHOOK_BASE_BODY.to_json, ctx,
          doc_id: "wh_seeded_editor")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        messages = err.details.try(&.map(&.message).join("; ")) || ""
        messages.should contain("connectivity excludes")
      end
    end
  end
end
