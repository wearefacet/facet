# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "http"
require "../../src/http/server"
require "../support/http_helper"
require "../support/app_helper"

# Part C — the deploy route: `POST /Api/app/:id/deploy`.
#
# Files covered:
#   - src/app/deploy.cr — multipart create of `app.Deployment` + optional
#     activation, both credential paths (operator session / app-owned
#     `fct_` API key).
#   - `data/seeds/app.Deployment/definition.yml` — the deployment doctype.
#
# Specs walk the plan's acceptance list: multipart create atomicity,
# revision monotonicity, activate + rollback, path validation rejections,
# CLI-key auth path, wrong-key 403, operator-session path, and
# draft/disabled app rejections.

HTTPTest.init

DEPLOY_MP_BOUNDARY = "facet-deploy-boundary"

INDEX_BYTES  = "<!doctype html><html><body>app</body></html>".to_slice
APP_JS_BYTES = "console.log('deployed');".to_slice

# Builds the multipart deploy request: a `$content` JSON part plus one
# file part per `{field_path, bytes}` entry. Cookie-session callers carry
# the CSRF header; bearer callers (API key / OAuth app token) do not need
# it — pass `csrf: false` for those.
def deploy_request(path : String, content_json : String, files : Array({String, Bytes}), csrf = true) : HTTP::Request
  io = IO::Memory.new
  HTTP::FormData.build(io, DEPLOY_MP_BOUNDARY) do |form|
    form.field("$content", content_json)
    files.each do |(field_path, bytes)|
      metadata = HTTP::FormData::FileMetadata.new(filename: field_path)
      form.file(field_path, IO::Memory.new(bytes), metadata)
    end
  end
  headers = HTTP::Headers{
    "Content-Type" => "multipart/form-data; boundary=#{DEPLOY_MP_BOUNDARY}",
  }
  headers["X-Requested-With"] = "XMLHttpRequest" if csrf
  HTTP::Request.new("POST", path, headers, io.to_s)
end

def deploy_content(note : String, paths : Array(String), overrides : Hash(String, String) = {} of String => String) : String
  files = paths.map { |p| %({"path": "#{p}"}) }
  base = %({"note": "#{note}", "spa": true, "files": [#{files.join(",")}]})
  JSON.parse(base).as_h.merge(JSON.parse(overrides.to_json).as_h).to_json
end

# Creates an active (or explicitly-statused) app as the system principal.
def create_deploy_app(db, status = "active", host : String? = nil, no_asset = false) : Facet::Mutation::Client::Projection
  slug = "deploy-#{unique_suffix}"
  body = {
    "slug":     slug,
    "name":     "Deploy App",
    "status":   status,
    "no_asset": no_asset,
  }
  body = body.merge({"host": host}) if host
  result = Facet::Document::Create.call(db, "app", "App", body.to_json, Facet::RBAC::AuthContext.system)
  expect_create_success(result).projection
end

# An operator session whose role holds `deploy` on `app.App` — the
# named action the deploy route gates on.
def deploy_operator_ctx : Facet::RBAC::AuthContext
  permission = Facet::RBAC::Permission.new(action: "deploy", domain: "app", path: ["App"])
  role = Facet::RBAC::ActiveRole.new(
    role_id: "deploy_operator",
    visible_tags: Set{"default"},
    permissions: [permission],
  )
  Facet::RBAC::AuthContext.authenticated("operator-#{unique_suffix}", role)
end

# An operator session WITHOUT `deploy` on `app.App` — the pre-change
# contract (`update` must not imply deploy). Mirrors the seeded `editor`.
def update_only_operator_ctx : Facet::RBAC::AuthContext
  permission = Facet::RBAC::Permission.new(action: "update", domain: "app", path: ["App"])
  role = Facet::RBAC::ActiveRole.new(
    role_id: "update_only_operator",
    visible_tags: Set{"default"},
    permissions: [permission],
  )
  Facet::RBAC::AuthContext.authenticated("operator-#{unique_suffix}", role)
end

# Builds the app-scoped context the request path builds for a verified
# app-owned key (the exact `build_api_key_auth_context` sequence): grant
# ceiling ∩ pinned role, resolved from the app's live content.
def cli_deploy_ctx(verified : Facet::IAM::ApiKey::Verified) : Facet::RBAC::AuthContext
  app_id = verified.app_id.not_nil!
  active_role = Facet::RBAC::ActiveRole.from_projection_content(verified.role_content)
  app_scope = Facet::RBAC::AppScope.from_content(app_id, verified.app_content.not_nil!)
  effective = Facet::RBAC::GrantResolver.resolve(app_scope, active_role)
  Facet::RBAC::AuthContext.app_scoped(verified.account_id, active_role, effective, app_id)
end

# Creates the deploy-capable service role the CLI-shaped confidential app
# pins. The seeded `iam.Roles.cli` role is gone — the first-party CLI is an
# OAuth client now — but backend-app specs still need a service role.
def create_deploy_service_role(db) : String
  role_id = "iam.Roles.deploy_svc"
  existing = db.query_one?("SELECT 1 FROM projections WHERE id = $1 AND deleted_at IS NULL", role_id, as: Int32)
  unless existing
    Facet::Mutation::Client.create(
      db, "iam", "Roles",
      doc_id: role_id,
      content: %({"name": "deploy_svc", "description": "Deploy-capable service role for backend-app specs.", "visible_tags": ["default"], "connectivity": ["mcp", "webhook", "api", "assistant"], "permissions": [{"action": "read", "on": "app.App"}, {"action": "create", "on": "app.App"}, {"action": "update", "on": "app.App"}, {"action": "delete", "on": "app.App"}, {"action": "deploy", "on": "app.App"}, {"action": "read", "on": "app.Deployment"}]}),
      actioner_id: "system",
    )
  end
  role_id
end

# Creates a confidential app whose grant ceiling covers `deploy` on
# `app.App` and whose service role is deploy-capable. With
# `with_deploy_grants: false`, the ceiling covers only `app.Deployment`
# reads — the denial case.
def create_cli_app(db, with_deploy_grants = true) : Facet::Mutation::Client::Projection
  role_id = create_deploy_service_role(db)
  grants = if with_deploy_grants
             %([{"target": "app.App", "actions": [{"name": "read", "required": true}, {"name": "write", "required": true}, {"name": "delete", "required": true}, {"name": "deploy", "required": true}]}, {"target": "app.Deployment", "actions": [{"name": "read", "required": true}]}])
           else
             %([{"target": "app.Deployment", "actions": [{"name": "read", "required": true}]}])
           end
  result = Facet::Document::Create.call(
    db, "app", "App",
    %({"slug": "cli-#{unique_suffix}", "name": "CLI App", "client_type": "confidential", "service_role_id": "#{role_id}", "status": "active", "grants": #{grants}}),
    Facet::RBAC::AuthContext.system,
  )
  expect_create_success(result).projection
end

def deployment_count(db) : Int64
  db.scalar("SELECT count(*) FROM projections WHERE domain = 'app' AND doc_type = 'Deployment' AND deleted_at IS NULL").as(Int64)
end

def artifact_count(db) : Int64
  db.scalar("SELECT count(*) FROM artifacts").as(Int64)
end

def app_content(db, app_id) : JSON::Any
  Facet::Mutation::Client.fetch_content(db, "app", "App", app_id)
end

# Builds the multipart deploy request the way the first-party clients do:
# each part's file name is the build path ("index.html"), not the field
# path. `deploy_request` above names parts by field path, which hides the
# file-name mime rule the "deploy mime types" group pins.
private def deploy_named_request(path : String, content_json : String, files : Array({String, String, Bytes})) : HTTP::Request
  io = IO::Memory.new
  HTTP::FormData.build(io, DEPLOY_MP_BOUNDARY) do |form|
    form.field("$content", content_json)
    files.each do |(field_path, filename, bytes)|
      metadata = HTTP::FormData::FileMetadata.new(filename: filename)
      form.file(field_path, IO::Memory.new(bytes), metadata)
    end
  end
  headers = HTTP::Headers{
    "Content-Type"     => "multipart/form-data; boundary=#{DEPLOY_MP_BOUNDARY}",
    "X-Requested-With" => "XMLHttpRequest",
  }
  HTTP::Request.new("POST", path, headers, io.to_s)
end

# The stored mime type of the artifact mapped at `path` in the app's
# active deployment.
private def deployed_artifact_mime(db, app_id : String, path : String) : String
  content = Facet::Mutation::Client.fetch_content(db, "app", "App", app_id)
  deployment_id = content["active_deployment"].as_s.sub("app.Deployment.", "")
  deployment = Facet::Mutation::Client.fetch_content(db, "app", "Deployment", deployment_id)
  artifact_id = deployment["files"].as_a
    .find! { |entry| entry["path"].as_s == path }["file"].as_s
  db.query_one("SELECT mime_type FROM artifacts WHERE id = $1", artifact_id, as: String)
end

describe "app.Deployment deploy route" do
  before_each do
    with_db { |db| seed_app_doctypes(db) }
  end

  describe "operator-session path" do
    it "deploys, activates, and computes revision 1" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy?activate=true",
        deploy_content("first build", ["index.html", "assets/app.js"]),
        [{"files[0].file", INDEX_BYTES}, {"files[1].file", APP_JS_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)

      body = JSON.parse(resp.body)
      deployment_id = body["id"].as_s
      body["revision"].as_i64.should eq(1)
      body["activated"].as_bool.should be_true
      body["files"].as_i.should eq(2)

      with_db do |db|
        content = Facet::Mutation::Client.fetch_content(db, "app", "Deployment", deployment_id)
        content["app_id"].as_s.should eq("app.App.#{app.id}")
        content["revision"].as_i64.should eq(1)
        content["note"].as_s.should eq("first build")
        content["spa"].as_bool.should be_true

        files = content["files"].as_a
        files[0]["path"].as_s.should eq("index.html")
        files[0]["file"].as_s.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
        files[1]["path"].as_s.should eq("assets/app.js")
        files[1]["file"].as_s.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)

        # Activation flipped the pointer on the app inside the same transaction.
        app_content(db, app.id)["active_deployment"].as_s.should eq("app.Deployment.#{deployment_id}")

        # Audit attribution: the target app lives on the document content
        # (`content.app_id`); the mutation meta carries the caller's
        # channel, not the deploy target.
        channel = db.query_one?(
          "SELECT channel FROM mutations WHERE domain = 'app' AND doc_type = 'Deployment' AND doc_id = $1 AND action = 'create'",
          deployment_id, as: String)
        channel.should eq("session")
      end
    end

    it "refuses a session without the CSRF header" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request("/Api/app/#{app.id}/deploy", deploy_content("n", ["index.html"]), [{"files[0].file", INDEX_BYTES}])
      req.headers.delete("X-Requested-With")
      resp = call_api_raw_as(req, deploy_operator_ctx)
      assert_http_status(resp, 403)
    end

    it "rejects an anonymous caller" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request("/Api/app/#{app.id}/deploy", deploy_content("n", ["index.html"]), [{"files[0].file", INDEX_BYTES}])
      resp = call_api_as(req, nil)
      assert_http_status(resp, 401)
    end

    it "rejects a draft app and a disabled app" do
      draft = with_db { |db| create_deploy_app(db, status: "draft") }
      req = deploy_request("/Api/app/#{draft.id}/deploy", deploy_content("n", ["index.html"]), [{"files[0].file", INDEX_BYTES}])
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)

      disabled = with_db { |db| create_deploy_app(db, status: "disabled") }
      req = deploy_request("/Api/app/#{disabled.id}/deploy", deploy_content("n", ["index.html"]), [{"files[0].file", INDEX_BYTES}])
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)
    end

    it "rejects an app marked no_asset" do
      headless = with_db { |db| create_deploy_app(db, no_asset: true) }
      req = deploy_request("/Api/app/#{headless.id}/deploy", deploy_content("n", ["index.html"]), [{"files[0].file", INDEX_BYTES}])
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)
    end
  end

  describe "revision monotonicity and rollback" do
    it "increments revision per app across deploys" do
      app = with_db { |db| create_deploy_app(db) }
      ctx = deploy_operator_ctx

      2.times do |i|
        req = deploy_request(
          "/Api/app/#{app.id}/deploy?activate=true",
          deploy_content("build #{i}", ["index.html"]),
          [{"files[0].file", INDEX_BYTES}],
        )
        resp = call_api_as(req, ctx)
        assert_http_status(resp, 201)
        JSON.parse(resp.body)["revision"].as_i64.should eq(i + 1)
      end

      # Another app's deploys do not advance this app's counter.
      other = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{other.id}/deploy?activate=true",
        deploy_content("other", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["revision"].as_i64.should eq(1)
    end

    it "rolls back by activating an older deployment via PATCH" do
      app = with_db { |db| create_deploy_app(db) }
      ctx = deploy_operator_ctx

      ids = [] of String
      2.times do |i|
        req = deploy_request(
          "/Api/app/#{app.id}/deploy?activate=true",
          deploy_content("build #{i}", ["index.html"]),
          [{"files[0].file", INDEX_BYTES}],
        )
        resp = call_api_as(req, ctx)
        assert_http_status(resp, 201)
        ids << JSON.parse(resp.body)["id"].as_s
      end

      with_db do |db|
        result = Facet::Document::Update.call(
          db, "app", "App", app.id,
          %({"active_deployment": "app.Deployment.#{ids[0]}"}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Update::Result)
        app_content(db, app.id)["active_deployment"].as_s.should eq("app.Deployment.#{ids[0]}")
      end
    end

    it "activates when the flag rides the $content part (the CLI's shape)" do
      app = with_db { |db| create_deploy_app(db) }
      # The CLI cannot set a query string through its multipart helper; it
      # sends "activate": true inside \$content. The route must read and
      # strip it there — a leftover key fails document validation.
      req = deploy_request(
        "/Api/app/#{app.id}/deploy",
        deploy_content("cli activate", ["index.html"], {"activate" => "true"}),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)
      body = JSON.parse(resp.body)
      body["activated"].as_bool.should be_true
      body["revision"].as_i64.should eq(1)

      with_db do |db|
        app_content(db, app.id)["active_deployment"].as_s.should eq("app.Deployment.#{body["id"].as_s}")
      end
    end

    it "lists the deployment by app_id reference filter in both value forms" do
      # The CLI resolves the app by slug (meta.id is the bare row id) and
      # lists its builds with filters[app_id__eq]. The deploy route stores
      # the reference qualified (app.App.<id>), so the filter must match
      # both the bare and the qualified value form.
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy",
        deploy_content("list probe", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)
      deployment_id = JSON.parse(resp.body)["id"].as_s

      ctx = Facet::RBAC::AuthContext.authenticated(
        "reader-#{unique_suffix}",
        Facet::RBAC::ActiveRole.new(
          role_id: "deployment_reader",
          visible_tags: Set{"default"},
          permissions: [
            Facet::RBAC::Permission.new(action: "read", domain: "app", path: ["Deployment"]),
          ],
        ),
      )
      ["qualified", "bare"].each do |form|
        value = form == "bare" ? app.id : "app.App.#{app.id}"
        list = call_api_as(
          HTTP::Request.new(
            "GET", "/Api/app/Deployment?filters[app_id__eq]=#{value}&sort=-revision",
            HTTP::Headers{"Accept" => "application/json"},
          ),
          ctx,
        )
        assert_http_status(list, 200)
        rows = JSON.parse(list.body)["data"].as_a
        rows.size.should eq(1), "the #{form} app_id filter value must match the stored reference"
        rows.first["meta"]["id"].as_s.should eq(deployment_id)
      end
    end

    it "deploys without activation when the flag is absent" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy",
        deploy_content("no activate", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)
      JSON.parse(resp.body)["activated"].as_bool.should be_false

      with_db do |db|
        app_content(db, app.id)["active_deployment"]?.should be_nil
      end
    end
  end

  describe "path validation and atomicity" do
    it "rejects traversal, absolute, and empty-segment paths" do
      app = with_db { |db| create_deploy_app(db) }
      ctx = deploy_operator_ctx

      ["../evil.html", "/abs.html", "a//b.html", "./x.html"].each do |bad|
        req = deploy_request(
          "/Api/app/#{app.id}/deploy",
          deploy_content("bad", [bad]),
          [{"files[0].file", INDEX_BYTES}],
        )
        resp = call_api_as(req, ctx)
        assert_http_status(resp, 422)
      end
    end

    it "rejects an entry whose file part is missing" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy",
        deploy_content("incomplete", ["index.html", "assets/app.js"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)
    end

    it "rolls the whole deploy back on a validation failure" do
      app = with_db { |db| create_deploy_app(db) }
      before_deployments = with_db { |db| deployment_count(db) }
      before_artifacts = with_db { |db| artifact_count(db) }

      req = deploy_request(
        "/Api/app/#{app.id}/deploy?activate=true",
        deploy_content("half build", ["../evil.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)

      with_db do |db|
        deployment_count(db).should eq(before_deployments)
        artifact_count(db).should eq(before_artifacts)
        app_content(db, app.id)["active_deployment"]?.should be_nil
      end
    end

    it "rejects a body that is not multipart" do
      app = with_db { |db| create_deploy_app(db) }
      req = HTTP::Request.new(
        "POST", "/Api/app/#{app.id}/deploy",
        HTTP::Headers{"Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest"},
        %({"note": "json body"}),
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 422)
    end
  end

  describe "CLI key path" do
    it "deploys with an app-owned fct_ key, without CSRF" do
      with_db do |db|
        seed_iam_doctypes(db)
        seed_test_roles(db)
      end

      app = with_db { |db| create_cli_app(db) }
      issued = with_db { |db| Facet::App::ApiKeys.issue(db, app.id).as(Facet::App::ApiKeys::Issued) }

      # The context the request path resolves for this key: grant ∩ pinned
      # role, both carrying `deploy` on `app.App`.
      verified = with_db { |db| Facet::IAM::ApiKey.verify(db, issued.key).not_nil! }
      ctx = cli_deploy_ctx(verified)

      # The `Authorization` header marks the caller as bearer-authenticated
      # (AuthHandler is disabled in tests — the context is injected — but
      # the route's CSRF exemption branches on the header's presence).
      req = deploy_request(
        "/Api/app/#{app.id}/deploy?activate=true",
        deploy_content("cli build", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
        csrf: false,
      )
      req.headers["Authorization"] = "Bearer #{issued.key}"
      resp = call_api_as(req, ctx)
      assert_http_status(resp, 201)

      body = JSON.parse(resp.body)
      body["revision"].as_i64.should eq(1)
      body["activated"].as_bool.should be_true

      with_db do |db|
        meta_app = db.query_one?("SELECT app FROM mutations WHERE domain = 'app' AND doc_type = 'Deployment' AND doc_id = $1 AND action = 'create'", body["id"].as_s, as: String?)
        meta_app.should eq(app.id)
      end
    end

    it "deploys another app when the grant ceiling covers app.App" do
      # The CLI contract: the key's grants are not row-scoped, so a
      # deploy-capable key onboards and deploys any application.
      with_db do |db|
        seed_iam_doctypes(db)
        seed_test_roles(db)
      end

      holder = with_db { |db| create_cli_app(db) }
      target = with_db { |db| create_deploy_app(db) }
      issued = with_db { |db| Facet::App::ApiKeys.issue(db, holder.id).as(Facet::App::ApiKeys::Issued) }

      verified = with_db { |db| Facet::IAM::ApiKey.verify(db, issued.key).not_nil! }
      ctx = cli_deploy_ctx(verified)

      req = deploy_request(
        "/Api/app/#{target.id}/deploy",
        deploy_content("cross app", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
        csrf: false,
      )
      req.headers["Authorization"] = "Bearer #{issued.key}"
      resp = call_api_as(req, ctx)
      assert_http_status(resp, 201)
    end

    it "refuses an app key whose grant ceiling lacks deploy" do
      with_db do |db|
        seed_iam_doctypes(db)
        seed_test_roles(db)
      end

      app = with_db { |db| create_cli_app(db, with_deploy_grants: false) }
      target = with_db { |db| create_deploy_app(db) }
      issued = with_db { |db| Facet::App::ApiKeys.issue(db, app.id).as(Facet::App::ApiKeys::Issued) }

      verified = with_db { |db| Facet::IAM::ApiKey.verify(db, issued.key).not_nil! }
      ctx = cli_deploy_ctx(verified)

      req = deploy_request(
        "/Api/app/#{target.id}/deploy",
        deploy_content("no deploy grant", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
        csrf: false,
      )
      req.headers["Authorization"] = "Bearer #{issued.key}"
      resp = call_api_as(req, ctx)
      assert_http_status(resp, 403)
    end
  end

  describe "operator without the deploy action" do
    it "refuses a role that holds only update on app.App" do
      app = with_db { |db| create_deploy_app(db) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy",
        deploy_content("editor", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, update_only_operator_ctx)
      assert_http_status(resp, 403)
    end
  end

  describe "deploy mime types" do
    it "stores and serves a lowercase-doctype index.html as text/html" do
      host = "mime.app-#{unique_suffix}.example.com"
      app = with_db { |db| create_deploy_app(db, host: host) }
      req = deploy_request(
        "/Api/app/#{app.id}/deploy?activate=true",
        deploy_content("lower doctype", ["index.html"]),
        [{"files[0].file", INDEX_BYTES}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)

      with_db { |db| deployed_artifact_mime(db, app.id, "index.html").should eq("text/html") }

      Facet::App::Hosting::HostCache.reset
      served = call_api(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => host}))
      assert_http_status(served, 200)
      served.headers["Content-Type"].starts_with?("text/html").should be_true
    end

    it "derives the stored mime from the deploy file name" do
      app = with_db { |db| create_deploy_app(db) }
      # The css bytes are plain text — only the file name can say text/css.
      req = deploy_named_request(
        "/Api/app/#{app.id}/deploy?activate=true",
        deploy_content("named parts", ["assets/main.css"]),
        [{"files[0].file", "assets/main.css", "body{color:red}".to_slice}],
      )
      resp = call_api_as(req, deploy_operator_ctx)
      assert_http_status(resp, 201)

      with_db { |db| deployed_artifact_mime(db, app.id, "assets/main.css").should eq("text/css") }
    end
  end
end
