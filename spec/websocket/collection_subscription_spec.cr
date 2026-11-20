# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/websocket"
require "../../src/rbac"
require "../../src/document"
require "../../src/mutation/client"

# ── Doubles (same shape as manager_spec, extended with an auth context) ──

class CollectionFakeFanout
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

class CollectionFakeConnection
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

COLLTEST_DOMAIN = "colltest"

# Builds the collection-test doctype: a `owner` reference field plus a
# named scope `own` (`owner == $self`) that the scoped role references.
def setup_collection_doctype(db) : Nil
  ensure_iam_account(db, "account_coll")
  ensure_iam_account(db, "account_other")
  ensure_iam_account(db, "someone_else")

  result = Facet::Document::Create.call(db, "core", "Domain", %({"domain": "#{COLLTEST_DOMAIN}"}), Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  schema = %({
    "doctype": "Ticket",
    "domain": "#{COLLTEST_DOMAIN}",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string"},
      "owner": {"type": "reference", "doctype": "iam.Account"}
    },
    "scopes": {
      "own": {
        "description": "Tickets owned by the actioner",
        "where": {"owner": "$self"}
      }
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

# Creates a Ticket owned by the given (bare or qualified) account id.
def create_collection_ticket(db, doc_id : String, owner_account : String) : Nil
  content = %({"name": "t", "owner": "iam.Account.#{owner_account}"})
  result = Facet::Document::Create.call(db, COLLTEST_DOMAIN, "Ticket", content, Facet::RBAC::AuthContext.system, doc_id: doc_id)
  result.should be_a(Facet::Document::Create::Result)
end

# Creates an ad-hoc role. With `scoped: true` the role holds ONLY an
# owner-scoped read on the ticket doctype — the principal passes the
# collection subscribe-time ceiling (Scoped, not Denied) but the per-emit
# row check filters on `owner`. With `scoped: false` the role holds read on
# an unrelated doctype only, so the subscribe-time ceiling denies
# colltest.Ticket outright.
def create_scoped_collection_role(db, role_id : String, scoped : Bool = true) : Nil
  permission = if scoped
                 %({"action": "read", "on": "#{COLLTEST_DOMAIN}.Ticket", "scope": ["$own"]})
               else
                 %({"action": "read", "on": "core.Comment"})
               end
  content = %({
    "name": "#{role_id}",
    "level": 20,
    "description": "collection subscription test role",
    "visible_tags": ["default"],
    "permissions": [#{permission}]
  })
  result = Facet::Mutation::Client.create(db, "iam", "Roles", doc_id: role_id, content: content, actioner_id: "system")
  result.should be_a(String)
end

def scoped_auth_context(db, role_id : String, account_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Roles", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

def collection_message(doc_id : String, event : String = "created") : Facet::Event::Message
  Facet::Event::Message.unpack(
    %({"i":"m-#{doc_id}","c":{"id":"#{doc_id}"},"h":{"event":"#{event}"}}),
    channel: "fanout:#{COLLTEST_DOMAIN}.Ticket",
  )
end

# ── Specs ────────────────────────────────────────────────────────────────

describe "WebSocket collection subscriptions" do
  before_each do
    with_db do |db|
      setup_collection_doctype(db)
    end
  end

  describe "SubscriptionResolver" do
    it "resolves a two-segment path to the collection channel" do
      with_db do |db|
        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/#{COLLTEST_DOMAIN}/Ticket", Facet::RBAC::AuthContext.system
        )

        case resolved
        in Facet::Websocket::SubscriptionResolver::Resolved
          resolved.collection?.should be_true
          resolved.doc_id.should be_nil
          resolved.fanout_channel.should eq("fanout:#{COLLTEST_DOMAIN}.Ticket")
        in Facet::ServiceError
          fail "Expected resolved, got error: #{resolved.message}"
        end
      end
    end

    it "denies a principal with no read grant on the doctype (non-disclosing)" do
      with_db do |db|
        # A role whose ONLY read grant targets an unrelated doctype — the
        # role ceiling denies colltest.Ticket at subscribe time.
        create_scoped_collection_role(db, "iam.Roles.coll_noaccess", scoped: false)
        auth = scoped_auth_context(db, "iam.Roles.coll_noaccess", "account_coll")

        resolved = Facet::Websocket::SubscriptionResolver.resolve_and_authorize(
          db, "/#{COLLTEST_DOMAIN}/Ticket", auth
        )

        case resolved
        in Facet::ServiceError
          resolved.status.should eq(403)
          resolved.message.should eq("not found or forbidden")
        in Facet::Websocket::SubscriptionResolver::Resolved
          fail "Expected subscribe-time denial"
        end
      end
    end

    it "resolves the two-segment path for unsubscribe (resolve_channel)" do
      channel = Facet::Websocket::SubscriptionResolver.resolve_channel("/#{COLLTEST_DOMAIN}/Ticket")
      channel.should eq("fanout:#{COLLTEST_DOMAIN}.Ticket")
    end
  end

  describe "Manager#dispatch on a collection channel" do
    it "delivers to a connection whose scope matches the document" do
      with_db do |db|
        create_scoped_collection_role(db, "iam.Roles.coll_owner")
        auth = scoped_auth_context(db, "iam.Roles.coll_owner", "account_coll")
        create_collection_ticket(db, "#{COLLTEST_DOMAIN}.Ticket.t1", "account_coll")

        fanout = CollectionFakeFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        conn = CollectionFakeConnection.new(auth)
        manager.register(conn, "fanout:#{COLLTEST_DOMAIN}.Ticket")

        manager.dispatch("fanout:#{COLLTEST_DOMAIN}.Ticket", collection_message("#{COLLTEST_DOMAIN}.Ticket.t1"))

        conn.delivered_messages.size.should eq(1)
        conn.delivered_messages[0].content["id"].as_s.should eq("#{COLLTEST_DOMAIN}.Ticket.t1")
      end
    end

    it "suppresses delivery to a connection whose scope does not match" do
      with_db do |db|
        create_scoped_collection_role(db, "iam.Roles.coll_owner")
        auth = scoped_auth_context(db, "iam.Roles.coll_owner", "account_coll")
        # Owned by someone else — the scoped principal must not see it.
        create_collection_ticket(db, "#{COLLTEST_DOMAIN}.Ticket.t2", "someone_else")

        fanout = CollectionFakeFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        filtered = CollectionFakeConnection.new(auth)
        allowed = CollectionFakeConnection.new # system principal — bypasses RBAC
        manager.register(filtered, "fanout:#{COLLTEST_DOMAIN}.Ticket")
        manager.register(allowed, "fanout:#{COLLTEST_DOMAIN}.Ticket")

        manager.dispatch("fanout:#{COLLTEST_DOMAIN}.Ticket", collection_message("#{COLLTEST_DOMAIN}.Ticket.t2"))

        filtered.delivered_messages.size.should eq(0)
        allowed.delivered_messages.size.should eq(1)
      end
    end

    it "drops a message whose payload carries no document id" do
      fanout = CollectionFakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = CollectionFakeConnection.new
      manager.register(conn, "fanout:#{COLLTEST_DOMAIN}.Ticket")

      broken = Facet::Event::Message.unpack(
        %({"i":"m-x","c":{"other":"value"},"h":{"event":"created"}}),
        channel: "fanout:#{COLLTEST_DOMAIN}.Ticket",
      )
      manager.dispatch("fanout:#{COLLTEST_DOMAIN}.Ticket", broken)

      conn.delivered_messages.size.should eq(0)
    end
  end

  describe "per-document channels (regression guard)" do
    it "delivers directly with no per-emit RBAC check" do
      with_db do |db|
        create_scoped_collection_role(db, "iam.Roles.coll_owner")
        auth = scoped_auth_context(db, "iam.Roles.coll_owner", "account_coll")
        # Owned by someone else: the per-emit filter WOULD suppress this on
        # the collection channel. The per-document channel must not filter.
        create_collection_ticket(db, "#{COLLTEST_DOMAIN}.Ticket.t3", "someone_else")

        fanout = CollectionFakeFanout.new
        manager = Facet::Websocket::Manager.new(fanout)
        conn = CollectionFakeConnection.new(auth)
        doc_channel = "fanout:#{COLLTEST_DOMAIN}.Ticket:#{COLLTEST_DOMAIN}.Ticket.t3"
        manager.register(conn, doc_channel)

        manager.dispatch(doc_channel, collection_message("#{COLLTEST_DOMAIN}.Ticket.t3"))

        conn.delivered_messages.size.should eq(1)
      end
    end
  end

  describe "subscriber cap" do
    it "rejects registration past the cap; the socket path stays open" do
      fanout = CollectionFakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      channel = "fanout:#{COLLTEST_DOMAIN}.Ticket"

      conn1 = CollectionFakeConnection.new
      conn2 = CollectionFakeConnection.new
      conn3 = CollectionFakeConnection.new

      manager.register(conn1, channel, cap: 2).should be_true
      manager.register(conn2, channel, cap: 2).should be_true
      manager.register(conn3, channel, cap: 2).should be_false

      # The over-cap connection is not registered and no extra Redis
      # SUBSCRIBE was issued.
      manager.listened_resources[channel].size.should eq(2)
      subscribe_calls = fanout.commands.count({:subscribe, channel})
      subscribe_calls.should eq(1)
    end
  end

  describe "unsubscribe and cleanup" do
    it "unregisters via the two-segment resolve_channel path" do
      fanout = CollectionFakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = CollectionFakeConnection.new
      channel = "fanout:#{COLLTEST_DOMAIN}.Ticket"

      manager.register(conn, channel)
      resolved = Facet::Websocket::SubscriptionResolver.resolve_channel("/#{COLLTEST_DOMAIN}/Ticket")
      manager.unregister(conn, resolved.not_nil!)

      manager.listened_resources.has_key?(channel).should be_false
      fanout.commands.should contain({:unsubscribe, channel})
    end

    it "removes the collection channel on unregister_all (socket close)" do
      fanout = CollectionFakeFanout.new
      manager = Facet::Websocket::Manager.new(fanout)
      conn = CollectionFakeConnection.new
      channel = "fanout:#{COLLTEST_DOMAIN}.Ticket"

      manager.register(conn, channel)
      conn.subscribed_channels << channel

      manager.unregister_all(conn)

      manager.listened_resources.has_key?(channel).should be_false
      fanout.commands.should contain({:unsubscribe, channel})
    end
  end
end
