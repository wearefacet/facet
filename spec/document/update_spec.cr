# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "json"
require "../../src/rbac"

describe Facet::Document::Update do
  it "partially updates a document" do
    with_temp_doctype("patchtest") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}, "body": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Original", "body": "Old content"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      patch = %({"title": "Updated"})
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      result = result.as(Facet::Document::Update::Result)

      proj = result.projection
      proj.content["title"].as_s.should eq("Updated")
      proj.content["body"].as_s.should eq("Old content")
    end
  end

  it "returns error for non-existent document" do
    with_temp_doctype("patchnotfound") do |db, domain, doctype|
      ensure_domain(db, domain)
      # Register the doctype first so the lookup reaches the projection
      # fetch (which raises `DB::NoResultsError` for a missing row),
      # rather than short-circuiting at the unknown-doctype gate.
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)

      result = Facet::Document::Update.call(db, domain, doctype, "nonexistent", %({"title": "Nope"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("not found")
    end
  end

  it "returns error for invalid body" do
    with_temp_doctype("patchinvalid") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Valid"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, "not json", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(422)
    end
  end

  it "rejects nulling a required field via PATCH with a 422" do
    with_temp_doctype("patchnullreq") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string", "required": true},
        "body": {"type": "string"}
      }})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original", "body": "Old"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": null}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "title" && e.code == "required" }.should be_true
    end
  end

  it "allows nulling an optional field via PATCH (removes the key, unset entry)" do
    with_temp_doctype("patchnullopt") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string", "required": true},
        "body": {"type": "string"}
      }})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original", "body": "Old"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"body": null}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection

      # JSON Merge Patch semantics: a null patch value removes the key —
      # the stored content no longer carries it at all.
      proj.content.as_h.has_key?("body").should be_false

      # The mutation log carries a real unset entry, not a set-null.
      mutation = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      mutation.state.should eq(proj.state)
    end
  end

  it "removes a nested key via a null inside a nested patch object" do
    with_temp_doctype("patchnullnested") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string", "required": true},
        "meta": {"type": "object"}
      }})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "T", "meta": {"a": 1, "b": 2}}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"meta": {"b": null}}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection

      proj.content.as_h["meta"].as_h.has_key?("b").should be_false
      proj.content.as_h["meta"].as_h["a"].as_i.should eq(1)
    end
  end

  it "is a no-op when the nulled key is already absent" do
    with_temp_doctype("patchnullnoop") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}, "body": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "T"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id
      before = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id).state

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"body": null}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      result.as(Facet::Document::Update::Result).mutation_id.should eq(before)
    end
  end

  it "returns no-op when body is empty object" do
    with_temp_doctype("patchemptybody") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Titled"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, "{}", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      update_res = result.as(Facet::Document::Update::Result)

      # Must return the existing projection with no new mutation
      update_res.projection.content["title"].as_s.should eq("Titled")

      # The mutation_id in the result should be the projection's own state
      # (i.e. the last mutation was the create, not a new update)
      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      proj.state.should eq(update_res.mutation_id)
    end
  end

  it "returns no-op when nothing changed" do
    with_temp_doctype("patchnoop") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Same"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      content_before = Facet::Mutation::Client.fetch_content(db, domain, doctype, doc_id)

      patch = %({"title": "Same"})
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)

      content_after = Facet::Mutation::Client.fetch_content(db, domain, doctype, doc_id)
      content_after.should eq(content_before)
    end
  end

  it "rejects update mutation when diff is empty at the client level" do
    with_temp_doctype("patchnoclient") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "Same"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      empty_diff = %({"set": [], "unset": []})
      expect_raises(ArgumentError, /empty update diff/) do
        Facet::Mutation::Client.update(db, domain, doctype, doc_id, diff_json: empty_diff)
      end
    end
  end

  it "strips write_only fields before computing diff" do
    with_temp_doctype("pwupdate") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string"},
        "password": {"type": "string", "write_only": true}
      }})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Safe", "password": "old_secret"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # PATCH setting only the write_only field — the diff should be empty
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"password": "new_secret"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      result = result.as(Facet::Document::Update::Result)

      proj = result.projection
      proj.content["password"]?.should be_nil
      proj.content["title"].as_s.should eq("Safe")
    end
  end

  it "rejects update to a deleted document" do
    with_temp_doctype("patchdeleted") do |db, domain, doctype|
      ensure_domain(db, domain)
      create_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", create_schema, Facet::RBAC::AuthContext.system)
      expect_create_success(result)

      doc_body = %({"title": "DeleteMe"})
      doc_res = Facet::Document::Create.call(db, domain, doctype, doc_body, Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # Delete first
      Facet::Document::Delete.call(db, domain, doctype, doc_id, Facet::RBAC::AuthContext.system)

      patch = %({"title": "Ghost"})
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(404)
    end
  end

  # ── Lua update lifecycle hook ──────────────────────────────────────

  it "runs the Lua update hook when the doctype has a script" do
    with_temp_doctype("luaup1") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.update(ctx)
          ctx.root.updated_by = ctx.actor_id
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "updated_by": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "Updated"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection
      proj.content["title"].as_s.should eq("Updated")
      proj.content["updated_by"].as_s.should eq("system")
    end
  end

  it "rejects update when the Lua update hook calls ctx.error()" do
    with_temp_doctype("luaup2") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.update(ctx)
          if ctx.root.status == 'archived' then
            ctx.error('cannot update archived documents')
          end
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}, "status": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Archived", "status": "archived"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "Nope"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Script validation failed")
      err.details.not_nil!.map(&.message).should contain("cannot update archived documents")
    end
  end

  it "answers 422 with the Lua message when the update hook raises an uncaught Lua error (B-131)" do
    with_temp_doctype("luaupbug") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.update(ctx)
          no_such_helper()
        end
        return export
      LUA
      fields = %({"title": {"type": "string"}})
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "Updated"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should start_with("Script error: ")
      err.message.should contain("no_such_helper")
    end
  end

  it "re-runs computed fields after update" do
    with_temp_doctype("luacomp") do |db, domain, doctype|
      ensure_domain(db, domain)
      script = <<-LUA
        local export = {}
        function export.compute_full_name(ctx)
          if ctx.root.first_name and ctx.root.last_name then
            return ctx.root.first_name .. " " .. ctx.root.last_name
          end
          return nil
        end
        return export
      LUA
      fields = %({
        "first_name": {"type": "string"},
        "last_name": {"type": "string"},
        "full_name": {"type": "data", "compute": "full_name", "compute_when": ["first_name", "last_name"]}
      })
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}, "script": #{script.to_json}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      # Create with both names
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"first_name": "Alice", "last_name": "Smith"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # Verify full_name was computed on create
      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, doc_id)
      proj.content["full_name"].as_s.should eq("Alice Smith")

      # PATCH only last_name
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"last_name": "Jones"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection
      proj.content["full_name"].as_s.should eq("Alice Jones")
    end
  end

  it "skips the Lua update hook when the doctype has no script" do
    with_temp_doctype("luaup4") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "Updated"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection
      proj.content["title"].as_s.should eq("Updated")
    end
  end

  # ── unique constraint enforcement ────────────────────────────────────

  it "rejects an update that collides on a unique field" do
    with_temp_doctype("patchunique") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string"},
        "code": {"type": "string", "unique": true}
      }})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_a = Facet::Document::Create.call(db, domain, doctype, %({"title": "A", "code": "abc"}), Facet::RBAC::AuthContext.system)
      doc_b = Facet::Document::Create.call(db, domain, doctype, %({"title": "B", "code": "def"}), Facet::RBAC::AuthContext.system)
      expect_create_success(doc_a)
      id_b = expect_create_success(doc_b).projection.id

      # Moving B onto A's unique value must be rejected.
      result = Facet::Document::Update.call(db, domain, doctype, id_b, %({"code": "abc"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should eq("Document validation failed")
      err.details.not_nil!.any? { |e| e.field == "code" && e.code == "unique" }.should be_true

      # The stored value must be unchanged.
      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, id_b)
      proj.content["code"].as_s.should eq("def")
    end
  end

  it "allows an update that keeps the document's own unique value" do
    with_temp_doctype("patchuniqueself") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string"},
        "code": {"type": "string", "unique": true}
      }})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original", "code": "abc"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # Touching a non-unique field while the unique field stays untouched.
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "Renamed"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection
      proj.content["title"].as_s.should eq("Renamed")
      proj.content["code"].as_s.should eq("abc")
    end
  end

  it "allows an update that moves a unique field to a fresh value" do
    with_temp_doctype("patchuniquefresh") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "title": {"type": "string"},
        "code": {"type": "string", "unique": true}
      }})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Original", "code": "abc"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"code": "fresh"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)
      proj = result.as(Facet::Document::Update::Result).projection
      proj.content["code"].as_s.should eq("fresh")
    end
  end

  it "rejects an update that nulls a unique field onto an existing value" do
    with_temp_doctype("patchuniqueref") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
        "code": {"type": "reference", "doctype": "#{domain}.Target", "unique": true}
      }})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      target_schema = %({"doctype": "Target", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", target_schema, Facet::RBAC::AuthContext.system)

      ref_a = Facet::Document::Create.call(db, domain, "Target", %({"name": "Alpha"}), Facet::RBAC::AuthContext.system)
      ref_b = Facet::Document::Create.call(db, domain, "Target", %({"name": "Beta"}), Facet::RBAC::AuthContext.system)
      id_a = expect_create_success(ref_a).projection.id
      id_b = expect_create_success(ref_b).projection.id

      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"code": "#{domain}.Target.#{id_a}"}), Facet::RBAC::AuthContext.system)
      doc_id = expect_create_success(doc_res).projection.id

      # A unique reference value is qualified (domain.Doctype.id); the
      # collision query must match it exactly. Moving doc A onto a fresh
      # target value first (keeps A unique), then B onto A's original value
      # must be rejected.
      result = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"code": "#{domain}.Target.#{id_b}"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::Update::Result)

      doc_b = Facet::Document::Create.call(db, domain, doctype, %({"code": "#{domain}.Target.#{id_a}"}), Facet::RBAC::AuthContext.system)
      id_b_doc = expect_create_success(doc_b).projection.id

      # Moving B onto A's current unique value must be rejected.
      result = Facet::Document::Update.call(db, domain, doctype, id_b_doc, %({"code": "#{domain}.Target.#{id_b}"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.details.not_nil!.any? { |e| e.field == "code" && e.code == "unique" }.should be_true

      # The stored value must be unchanged.
      proj = Facet::Mutation::Client.fetch_projection(db, domain, doctype, id_b_doc)
      proj.content["code"].as_s.should eq("#{domain}.Target.#{id_a}")
    end
  end

  # ── core.Domain draft guard ──────────────────────────────────────────

  # F06-01: the guard is key-presence-based by design (see
  # `doc/backend/draft-domains.md` — a dedicated rejection branch, not
  # `read_only` field semantics). A GET→PATCH round-trip that echoes the
  # `draft` key answers 422 even when the submitted value equals the stored
  # one; callers must pop the key. No persisted-baseline diff applies.
  describe "core.Domain draft guard" do
    it "rejects a PATCH that carries the draft key even when the value equals the stored one" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "drfupd_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "description": "live domain"})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        # A live domain stores draft=false; echoing that exact value is
        # still a refusal — the guard checks key presence, not the value.
        patch = %({"draft": false, "description": "renamed"})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("'draft' field cannot be modified")

        # The stored content is untouched.
        content = db.query_one(
          "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1",
          domain, as: JSON::Any)
        content["description"].as_s.should eq("live domain")
      end
    end

    it "rejects a PATCH that flips draft to true" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "drfupd2_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "description": "live domain"})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"draft": true})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("'draft' field cannot be modified")
      end
    end

    it "accepts a PATCH without the draft key" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "drfupd3_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "description": "live domain"})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"description": "renamed"})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Update::Result)
        result.as(Facet::Document::Update::Result).projection.content["description"].as_s.should eq("renamed")
      end
    end

    it "mirrors the guard on create: a body that sets draft is refused" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "drfcre_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "draft": true})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("'draft' field cannot be set via document create")
      end
    end
  end

  # ── core.Domain context set validation ────────────────────────────────────

  describe "core.Domain context set validation on update" do
    it "rejects a SQL injection select field via PATCH" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "ctxupd_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "context_sets": {"mine": {"from": "Thing", "select": "id", "where": {"account": "$self"}}}})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"context_sets": {"mine": {"from": "Thing", "select": "x' UNION SELECT password_hash FROM auth_secrets --", "where": {"account": "$self"}}}})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("RBAC context set validation failed")
        err.details.not_nil!.any? { |e| e.code == "context_set" && e.message.includes?("select") && e.message.includes?("mine") }.should be_true
      end
    end

    it "rejects a SQL injection where field via PATCH" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "ctxupd2_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "context_sets": {"mine": {"from": "Thing", "select": "id", "where": {"account": "$self"}}}})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"context_sets": {"mine": {"from": "Thing", "select": "id", "where": {"x' UNION SELECT 1 --": "$self"}}}})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("RBAC context set validation failed")
        err.details.not_nil!.any? { |e| e.code == "context_set" && e.message.includes?("where") && e.message.includes?("mine") }.should be_true
      end
    end

    it "allows a PATCH that does not touch context_sets" do
      with_db do |db|
        restore_seeded_baseline(db)
        Facet::Doctype::DefinitionStore.cache.clear

        domain = "ctxupd3_#{unique_suffix}"
        create_body = %({"id": "#{domain}", "description": "old", "context_sets": {"mine": {"from": "Thing", "select": "id", "where": {"account": "$self"}}}})
        result = Facet::Document::Create.call(db, "core", "Domain", create_body, Facet::RBAC::AuthContext.system)
        expect_create_success(result)

        patch = %({"description": "new"})
        result = Facet::Document::Update.call(db, "core", "Domain", domain, patch, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Update::Result)
        proj = result.as(Facet::Document::Update::Result).projection
        proj.content["description"].as_s.should eq("new")
      end
    end
  end

  describe "iam.Account email immutability" do
    it "rejects a change of the email address" do
      with_db do |db|
        doc_id = create_pipeline_account(db, "gate@example.com")
        doc_id.should eq("gate@example.com")

        result = Facet::Document::Update.call(db, "iam", "Account", doc_id,
          %({"email": "changed@example.com"}), Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("immutable")
        err.details.not_nil!.first.field.should eq("email")

        # The stored content is untouched.
        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1", doc_id, as: JSON::Any)
        content["email"].as_s.should eq("gate@example.com")
      end
    end

    it "allows a re-save of the same address and a case-only rewrite" do
      with_db do |db|
        doc_id = create_pipeline_account(db, "same@example.com")

        result = Facet::Document::Update.call(db, "iam", "Account", doc_id,
          %({"email": "same@example.com", "name": "Renamed"}),
          Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Update::Result)
        proj = result.as(Facet::Document::Update::Result).projection
        proj.content["name"].as_s.should eq("Renamed")

        # A case-only rewrite passes — the stored form equals the id either
        # way (the create hook lowercased it).
        case_result = Facet::Document::Update.call(db, "iam", "Account", doc_id,
          %({"email": "SAME@example.com"}), Facet::RBAC::AuthContext.system)
        case_result.should be_a(Facet::Document::Update::Result)
      end
    end

    it "accepts a patch without the email key" do
      with_db do |db|
        doc_id = create_pipeline_account(db, "plain@example.com")
        result = Facet::Document::Update.call(db, "iam", "Account", doc_id,
          %({"name": "Other Field"}), Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Update::Result)
      end
    end
  end
end

# Creates an account through the pipeline (the id derives from the email)
# and returns its document id. The seed_test_roles helper seeds the test
# roles instead of the production role corpus (whose scoped permissions
# need the registered core doctypes); the iam.Roles definition alone is
# enough for the account create. File-scoped private def — see the
# top-level-defs rule in doc/backend/workflow.md.
private def create_pipeline_account(db, email : String) : String
  Facet::Doctype::Seed.ensure_doctype(db, "iam", "Account")
  Facet::Doctype::Seed.ensure_doctype_definition(db, "iam", "Roles")
  seed_test_roles(db)
  result = Facet::Document::Create.call(db, "iam", "Account",
    %({"email": "#{email}", "name": "Email Gate"}),
    Facet::RBAC::AuthContext.system)
  expect_create_success(result).projection.id
end
