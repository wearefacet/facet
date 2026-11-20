# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/websocket"
require "../../src/rbac"
require "../../src/document"
require "../../src/mutation/client"

# ── Doubles (same shape as manager_spec, with an auth context) ──────────

class ChildFrameFanout
  include Facet::Websocket::Subscribable

  getter commands : Array({Symbol, String})

  def initialize
    @commands = [] of {Symbol, String}
  end

  def subscribe(channel : String) : Nil
    @commands << {:subscribe, channel}
  end

  def unsubscribe(channel : String) : Nil
    @commands << {:unsubscribe, channel}
  end

  def start : Nil
  end

  def stop : Nil
  end

  def started? : Bool
    false
  end
end

class ChildFrameConnection
  include Facet::Websocket::Connectable

  getter auth_context : Facet::RBAC::AuthContext
  getter subscribed_channels : Set(String)
  getter delivered_messages : Array(Facet::Event::Message)

  def initialize(@auth_context : Facet::RBAC::AuthContext = Facet::RBAC::AuthContext.system)
    @subscribed_channels = Set(String).new
    @delivered_messages = [] of Facet::Event::Message
  end

  def deliver(message : Facet::Event::Message) : Nil
    @delivered_messages << message
  end

  def close : Nil
  end
end

# ── Helpers ──────────────────────────────────────────────────────────────

CHILD_DOMAIN = "wsagg"

# Parent + child doctypes with the owned-composition spelling, plus the
# parent document and one child row.
def setup_child_frame_pair(db) : {String, String, String, String}
  ensure_iam_account(db, "account_child")
  ensure_iam_account(db, "account_bystander")
  ensure_domain(db, CHILD_DOMAIN)
  parent = "P#{unique_suffix}"
  child = "C#{unique_suffix}"
  parent_defn = %({"doctype": "#{parent}", "domain": "#{CHILD_DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
  child_defn = %({"doctype": "#{child}", "domain": "#{CHILD_DOMAIN}", "aggregate_root": false, "member_of": "#{parent}", "fields": {"name": {"type": "string"}}})
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system))
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system))

  parent_res = expect_create_success(Facet::Document::Create.call(db, CHILD_DOMAIN, parent, %({"name": "root"}), Facet::RBAC::AuthContext.system))
  parent_id = parent_res.projection.id
  child_res = expect_create_success(Facet::Document::Create.call(
    db, CHILD_DOMAIN, child, %({"name": "kid"}), Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
  ))
  {parent, child, parent_id, child_res.projection.id}
end

# Creates an ad-hoc role. `grant` is the permission set: a flat read on the
# child doctype, or a read on the parent only.
def create_child_frame_role(db, role_id : String, grant : String) : Nil
  content = %({
    "name": "#{role_id}",
    "level": 20,
    "description": "child frame dispatch test role",
    "visible_tags": ["default"],
    "permissions": [#{grant}]
  })
  Facet::Mutation::Client.create(db, "iam", "Roles", doc_id: role_id, content: content, actioner_id: "system")
end

def child_frame_auth_context(db, role_id : String, account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Roles", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Builds an aggregate child_changed frame in the wire shape the publisher
# emits: keyed to the parent, with the child pointer in the payload.
def child_changed_wire_message(domain, parent_doctype, parent_doc_id, child_doctype, child_doc_id) : Facet::Event::Message
  Facet::Event::Message.unpack(
    %({"i":"m-1","c":{"id":"#{parent_doc_id}","action":"updated","child":{"doc_type":"#{child_doctype}","doc_id":"#{child_doc_id}"},"parent":{"doc_type":"#{parent_doctype}","doc_id":"#{parent_doc_id}"}},"h":{"event":"child_changed","domain":"#{domain}","doc_type":"#{parent_doctype}"}}),
    channel: "fanout:#{domain}.#{parent_doctype}:#{parent_doc_id}",
  )
end

describe "WebSocket dispatch of aggregate child_changed frames" do
  describe "Manager#dispatch on a per-document parent channel" do
    it "delivers to a connection whose role can read the child" do
      with_db do |db|
        parent, child, parent_id, child_id = setup_child_frame_pair(db)
        create_child_frame_role(db, "iam.Roles.frame_child_reader", %({"action": "read", "on": "#{CHILD_DOMAIN}.#{child}"}))
        auth = child_frame_auth_context(db, "iam.Roles.frame_child_reader", "account_child")

        fanout = ChildFrameFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        conn = ChildFrameConnection.new(auth)
        manager.register(conn, "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}")

        manager.dispatch(
          "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}",
          child_changed_wire_message(CHILD_DOMAIN, parent, parent_id, child, child_id),
        )

        conn.delivered_messages.size.should eq(1)
        conn.delivered_messages[0].content["child"]["doc_id"].as_s.should eq(child_id)
      end
    end

    it "suppresses delivery to a connection whose role cannot read the child" do
      with_db do |db|
        parent, child, parent_id, child_id = setup_child_frame_pair(db)
        # The role reads the PARENT only — subscribe-time RBAC would pass,
        # but the frame names a child the principal must not see.
        create_child_frame_role(db, "iam.Roles.frame_parent_reader", %({"action": "read", "on": "#{CHILD_DOMAIN}.#{parent}"}))
        auth = child_frame_auth_context(db, "iam.Roles.frame_parent_reader", "account_child")

        fanout = ChildFrameFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        filtered = ChildFrameConnection.new(auth)
        allowed = ChildFrameConnection.new # system principal — bypasses RBAC
        manager.register(filtered, "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}")
        manager.register(allowed, "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}")

        manager.dispatch(
          "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}",
          child_changed_wire_message(CHILD_DOMAIN, parent, parent_id, child, child_id),
        )

        filtered.delivered_messages.size.should eq(0)
        allowed.delivered_messages.size.should eq(1)
      end
    end

    it "drops a frame whose payload carries no child pointer" do
      fanout = ChildFrameFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = ChildFrameConnection.new
      manager.register(conn, "fanout:#{CHILD_DOMAIN}.P1:p1")

      broken = Facet::Event::Message.unpack(
        %({"i":"m-2","c":{"id":"p1"},"h":{"event":"child_changed","domain":"#{CHILD_DOMAIN}","doc_type":"P1"}}),
        channel: "fanout:#{CHILD_DOMAIN}.P1:p1",
      )
      manager.dispatch("fanout:#{CHILD_DOMAIN}.P1:p1", broken)

      conn.delivered_messages.size.should eq(0)
    end

    it "keeps the direct-deliver fast path for non-aggregate per-document frames" do
      with_db do |db|
        parent, _, parent_id, _ = setup_child_frame_pair(db)
        # A role that cannot read the CHILD — an ordinary parent update
        # frame must still deliver (per-document channels check RBAC at
        # subscribe time, not per emit).
        create_child_frame_role(db, "iam.Roles.frame_parent_reader", %({"action": "read", "on": "#{CHILD_DOMAIN}.#{parent}"}))
        auth = child_frame_auth_context(db, "iam.Roles.frame_parent_reader", "account_child")

        fanout = ChildFrameFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        conn = ChildFrameConnection.new(auth)
        manager.register(conn, "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}")

        ordinary = Facet::Event::Message.unpack(
          %({"i":"m-3","c":{"id":"#{parent_id}"},"h":{"event":"updated","domain":"#{CHILD_DOMAIN}","doc_type":"#{parent}"}}),
          channel: "fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}",
        )
        manager.dispatch("fanout:#{CHILD_DOMAIN}.#{parent}:#{parent_id}", ordinary)

        conn.delivered_messages.size.should eq(1)
      end
    end
  end
end
