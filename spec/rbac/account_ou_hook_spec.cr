# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/document"
require "../../src/mutation/client"
require "../support/doctype_helper"

# ── Helpers ────────────────────────────────────────────────────────────────

# Registers the `iam.Account` doctype from the fixture bundle (idempotent —
# the seed already registered it in the template DB) and creates an account
# through the document service so the Lua lifecycle hooks and field defaults
# run.
def create_ou_account(db, account_id, content_overrides = {} of String => String)
  ensure_domain(db, "iam")
  create_doctype_from_data("iam.Account/definition.yml")
  content = {
    "email" => JSON::Any.new("#{account_id}@facet.local"),
    "name"  => JSON::Any.new(account_id),
    "roles" => JSON::Any.new([] of JSON::Any),
  }
  content_overrides.each { |k, v| content[k] = JSON::Any.new(v) }
  result = Facet::Document::Create.call(
    db, "iam", "Account",
    JSON::Any.new(content).to_json,
    Facet::RBAC::AuthContext.system,
    doc_id: account_id,
  )
  case result
  in Facet::Document::Create::Result then result
  in Facet::ServiceError
    details = result.details.try(&.map(&.message).join("; ")) || ""
    fail "Account create failed: #{result.message} #{details}"
  end
end

def fetch_ou(db, account_id) : String?
  begin
    content = Facet::Mutation::Client.fetch_content(db, "iam", "Account", account_id)
  rescue DB::NoResultsError
    return nil
  end
  h = content.as_h?
  return nil if h.nil?
  h["organizational_unit"]?.try(&.as_s?)
end

module Facet::RBAC
  describe "iam.Account organizational_unit normalization (Lua hook)" do
    it "falls back to the '/' root default when the field is omitted" do
      with_db do |db|
        create_ou_account(db, "ou_default")
        fetch_ou(db, "ou_default").should eq("/")
      end
    end

    it "keeps the root '/' as-is" do
      with_db do |db|
        create_ou_account(db, "ou_root", {"organizational_unit" => "/"})
        fetch_ou(db, "ou_root").should eq("/")
      end
    end

    it "appends the trailing slash" do
      with_db do |db|
        create_ou_account(db, "ou_trail", {"organizational_unit" => "/engineering"})
        fetch_ou(db, "ou_trail").should eq("/engineering/")
      end
    end

    it "prepends the leading slash" do
      with_db do |db|
        create_ou_account(db, "ou_lead", {"organizational_unit" => "engineering/"})
        fetch_ou(db, "ou_lead").should eq("/engineering/")
      end
    end

    it "prepends and appends when both are missing" do
      with_db do |db|
        create_ou_account(db, "ou_bare", {"organizational_unit" => "engineering"})
        fetch_ou(db, "ou_bare").should eq("/engineering/")
      end
    end

    it "collapses duplicate trailing slashes" do
      with_db do |db|
        create_ou_account(db, "ou_dup", {"organizational_unit" => "/engineering//"})
        fetch_ou(db, "ou_dup").should eq("/engineering/")
      end
    end

    it "collapses a leading duplicate slash" do
      with_db do |db|
        create_ou_account(db, "ou_duplead", {"organizational_unit" => "//engineering/"})
        fetch_ou(db, "ou_duplead").should eq("/engineering/")
      end
    end

    it "leaves the inner path untouched" do
      with_db do |db|
        create_ou_account(db, "ou_inner", {"organizational_unit" => "/engineering//backend/"})
        fetch_ou(db, "ou_inner").should eq("/engineering//backend/")
      end
    end

    it "collapses an empty string to the root" do
      with_db do |db|
        create_ou_account(db, "ou_empty", {"organizational_unit" => ""})
        fetch_ou(db, "ou_empty").should eq("/")
      end
    end

    it "rejects a non-string value" do
      with_db do |db|
        ensure_domain(db, "iam")
        create_doctype_from_data("iam.Account/definition.yml")
        content = {
          "email"               => JSON::Any.new("ou_badtype@facet.local"),
          "name"                => JSON::Any.new("ou_badtype"),
          "roles"               => JSON::Any.new([] of JSON::Any),
          "organizational_unit" => JSON::Any.new(42_i64),
        }
        # The doctype string-type validator is the primary gate; the Lua
        # hook is defence in depth. Either rejection path is acceptable —
        # the write must not persist.
        rejected = false
        begin
          result = Facet::Document::Create.call(
            db, "iam", "Account",
            JSON::Any.new(content).to_json,
            Facet::RBAC::AuthContext.system,
            doc_id: "ou_badtype",
          )
          rejected = true if result.is_a?(Facet::ServiceError)
        rescue
          rejected = true
        end
        rejected.should be_true
        fetch_ou(db, "ou_badtype").should be_nil
      end
    end

    it "normalizes on update as well" do
      with_db do |db|
        create_ou_account(db, "ou_upd", {"organizational_unit" => "/"})
        result = Facet::Document::Update.call(
          db, "iam", "Account", "ou_upd",
          %({"organizational_unit": "engineering"}),
          Facet::RBAC::AuthContext.system,
        )
        result.should be_a(Facet::Document::Update::Result)
        fetch_ou(db, "ou_upd").should eq("/engineering/")
      end
    end
  end
end
