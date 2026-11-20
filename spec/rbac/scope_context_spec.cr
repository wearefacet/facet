# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/document"
require "../../src/mutation/client"
require "../support/doctype_helper"

module Facet::RBAC
  describe AccountLoader do
    describe ".organizational_unit" do
      it "returns the stored organizational_unit" do
        with_db do |db|
          ensure_domain(db, "iam")
          create_doctype_from_data("iam.Account/definition.yml")
          content = {
            "email"               => JSON::Any.new("ou_loader@facet.local"),
            "name"                => JSON::Any.new("ou_loader"),
            "roles"               => JSON::Any.new([] of JSON::Any),
            "organizational_unit" => JSON::Any.new("/engineering/"),
          }
          Facet::Document::Create.call(
            db, "iam", "Account", JSON::Any.new(content).to_json,
            Facet::RBAC::AuthContext.system, doc_id: "ou_loader")
          AccountLoader.organizational_unit(db, "ou_loader").should eq("/engineering/")
        end
      end

      it "falls back to the root path for a missing account" do
        with_db do |db|
          AccountLoader.organizational_unit(db, "no_such_account").should eq("/")
        end
      end
    end
  end

  describe ScopeContext do
    describe ".root" do
      it "scopes the actioner to the root path" do
        ctx = ScopeContext.root("system")
        ctx.account_id.should eq("system")
        ctx.organizational_unit.should eq("/")
      end
    end

    describe ".load" do
      it "loads the OU from the iam.Account projection" do
        with_db do |db|
          ensure_domain(db, "iam")
          create_doctype_from_data("iam.Account/definition.yml")
          content = {
            "email"               => JSON::Any.new("ou_ctx@facet.local"),
            "name"                => JSON::Any.new("ou_ctx"),
            "roles"               => JSON::Any.new([] of JSON::Any),
            "organizational_unit" => JSON::Any.new("/engineering/backend/"),
          }
          Facet::Document::Create.call(
            db, "iam", "Account", JSON::Any.new(content).to_json,
            Facet::RBAC::AuthContext.system, doc_id: "ou_ctx")
          ctx = ScopeContext.load(db, "ou_ctx")
          ctx.account_id.should eq("ou_ctx")
          ctx.organizational_unit.should eq("/engineering/backend/")
        end
      end

      it "falls back to the root path for a missing account" do
        with_db do |db|
          ctx = ScopeContext.load(db, "no_such_account")
          ctx.organizational_unit.should eq("/")
        end
      end
    end
  end
end
