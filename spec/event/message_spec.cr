# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

describe Facet::Event::Message do
  payload = JSON.parse(%({"account_id":"123","action":"login"}))
  headers = {
    "source" => ::JSON::Any.new("web"),
    "event"  => ::JSON::Any.new("user.login"),
  }

  describe "pack/unpack roundtrip" do
    it "pack and unpack a basic message" do
      msg = Facet::Event::Message.new(
        content: payload,
        headers: headers.dup,
        channel: "test:channel",
        consumer_group: "test-group"
      )

      packed = msg.pack
      unpacked = Facet::Event::Message.unpack(packed, channel: "test:channel", consumer_group: "test-group")

      unpacked.content.should eq(payload)
      unpacked.headers.should eq(headers)
      unpacked.channel.should eq("test:channel:user.login")
      unpacked.consumer_group.should eq("test-group")
    end

    it "preserves id across pack/unpack" do
      msg = Facet::Event::Message.new(content: payload, id: "custom-id-123")
      packed = msg.pack
      unpacked = Facet::Event::Message.unpack(packed)
      unpacked.id.should eq("custom-id-123")
    end

    it "handles nil reply_to" do
      msg = Facet::Event::Message.new(content: payload)
      packed = msg.pack
      unpacked = Facet::Event::Message.unpack(packed)
      unpacked.reply_to.should be_nil
    end

    it "handles present reply_to" do
      msg = Facet::Event::Message.new(content: payload, reply_to: "reply:chan")
      packed = msg.pack
      unpacked = Facet::Event::Message.unpack(packed)
      unpacked.reply_to.should eq("reply:chan")
    end
  end

  describe "from hash" do
    it "creates a message from a Hash payload" do
      hash = {"name" => ::JSON::Any.new("Alice"), "age" => ::JSON::Any.new(30_i64)}
      msg = Facet::Event::Message.new(content: JSON::Any.new(hash), id: "hash-test")
      msg.content.as_h.should eq(hash)
      msg.id.should eq("hash-test")
    end
  end
end
