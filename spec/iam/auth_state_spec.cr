# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "pg"
require "../../src/iam/auth_state"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"

# ── Fixture helpers ──────────────────────────────────────────────────────

AUTH_STATE_DOMAIN  = "secretstore"
AUTH_STATE_DOCTYPE = "Widget"

def auth_state_doc_ref(doc_id : String) : String
  "#{AUTH_STATE_DOMAIN}.#{AUTH_STATE_DOCTYPE}.#{doc_id}"
end

def create_auth_state_doc(name : String) : String
  with_db do |db|
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, AUTH_STATE_DOMAIN, AUTH_STATE_DOCTYPE,
      doc_id: doc_id,
      content: %({"name": #{name.to_json}}),
      actioner_id: "system:auth-state-spec",
    )
    doc_id
  end
end

def fetch_last_totp_step(doc_id : String) : Int64?
  with_db do |db|
    db.query_one?(
      "SELECT last_totp_step FROM auth_state " \
      "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3",
      AUTH_STATE_DOMAIN, AUTH_STATE_DOCTYPE, doc_id,
      as: Int64?,
    )
  end
end

# ── Specs ────────────────────────────────────────────────────────────────

describe Facet::IAM::AuthState do
  before_each do
    with_db do |db|
      ensure_domain(db, AUTH_STATE_DOMAIN)
      Facet::Doctype::DefinitionStore.cache.clear
      body = %({
        "doctype": "#{AUTH_STATE_DOCTYPE}",
        "domain": "#{AUTH_STATE_DOMAIN}",
        "aggregate_root": true, "search": "{{ display_name }}",
        "fields": {
          "name": { "type": "string" }
        }
      })
      result = Facet::Document::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
      raise "auth_state spec doctype create failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
    end
  end

  it "accepts the first step and upserts the row" do
    doc_id = create_auth_state_doc("totp-first")
    ref = auth_state_doc_ref(doc_id)
    with_db do |db|
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64).should be_true
      fetch_last_totp_step(doc_id).should eq(42_i64)
    end
  end

  it "accepts a strictly greater step" do
    doc_id = create_auth_state_doc("totp-greater")
    ref = auth_state_doc_ref(doc_id)
    with_db do |db|
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64).should be_true
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 43_i64).should be_true
      fetch_last_totp_step(doc_id).should eq(43_i64)
    end
  end

  it "rejects a replayed equal step" do
    doc_id = create_auth_state_doc("totp-replay")
    ref = auth_state_doc_ref(doc_id)
    with_db do |db|
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64).should be_true
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64).should be_false
      fetch_last_totp_step(doc_id).should eq(42_i64)
    end
  end

  it "rejects a lower step" do
    doc_id = create_auth_state_doc("totp-lower")
    ref = auth_state_doc_ref(doc_id)
    with_db do |db|
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64).should be_true
      Facet::IAM::AuthState.try_advance_totp_step(db, ref, 41_i64).should be_false
      fetch_last_totp_step(doc_id).should eq(42_i64)
    end
  end

  it "serializes concurrent advances — exactly one of two identical steps wins" do
    doc_id = create_auth_state_doc("totp-race")
    ref = auth_state_doc_ref(doc_id)

    results = Channel(Bool).new(2)
    2.times do
      spawn do
        with_db do |db|
          results.send(Facet::IAM::AuthState.try_advance_totp_step(db, ref, 42_i64))
        end
      end
    end

    first = results.receive
    second = results.receive
    (first || second).should be_true
    (first && second).should be_false
  end
end
