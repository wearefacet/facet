# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

describe Facet::Event::Config do
  describe "defaults" do
    it "creates with default values" do
      config = Facet::Event::Config.new
      config.url.should eq("redis://localhost:6379/0")
      config.partitions.should eq(16)
      config.maxlen.should eq(1_000_000)
      config.stream.max_block_time.should eq(2.0)
      config.stream.min_block_time.should eq(0.1)
      config.stream.block_time_delta.should eq(0.7)
      config.stream.max_messages_count.should eq(10)
    end

    it "accepts custom values" do
      config = Facet::Event::Config.new(
        url: "redis://localhost:6380/1",
        partitions: 32,
        maxlen: 500_000_i64,
        stream: Facet::Event::Config::StreamConfig.new(
          max_block_time: 5.0,
          min_block_time: 0.5,
          block_time_delta: 0.8,
          max_messages_count: 100
        )
      )
      config.url.should eq("redis://localhost:6380/1")
      config.partitions.should eq(32)
      config.maxlen.should eq(500_000)
      config.stream.max_block_time.should eq(5.0)
      config.stream.min_block_time.should eq(0.5)
      config.stream.block_time_delta.should eq(0.8)
      config.stream.max_messages_count.should eq(100)
    end
  end

  describe "StreamConfig" do
    it "provides sensible block time delta validation" do
      config = Facet::Event::Config::StreamConfig.new
      config.block_time_delta.should be > 0
      config.block_time_delta.should be <= 1
    end
  end
end
