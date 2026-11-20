# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "json"

module Facet
  module Event
    # A message travelling through the event system.
    #
    # Serialized as JSON. Fields use short keys to minimize wire size:
    #   `i` → id (message unique identifier)
    #   `c` → content (payload body)
    #   `h` → headers (metadata hash)
    #   `r` → reply_to (optional reply channel)
    class Message
      getter id : String
      getter content : JSON::Any
      getter headers : Hash(String, JSON::Any)
      getter reply_to : String?

      getter channel : String?
      getter consumer_group : String?

      def initialize(
        @content : JSON::Any,
        @headers : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
        @reply_to : String? = nil,
        @id : String = Random.new.hex(8),
        @channel : String? = nil,
        @consumer_group : String? = nil,
      )
      end

      # Serialize the message to a JSON string.
      def pack : String
        {
          i: @id,
          c: @content,
          h: @headers,
          r: @reply_to,
        }.to_json
      end

      # Deserialize a message from a JSON string.
      #
      # *id* overrides the packed id. The Redis Streams consumer passes the
      # stream entry id here, so the consumer path identifies a message by
      # its stream entry id — `raw["i"]` is the producer's message id.
      def self.unpack(
        data : String,
        channel : String? = nil,
        consumer_group : String? = nil,
        id : String? = nil,
      ) : self
        raw = JSON.parse(data)

        headers_raw = raw["h"]
        headers = headers_raw.as_h.transform_values { |v| v }

        event_suffix = headers["event"]?.try { |v| v.as_s if v.raw.is_a?(String) }
        resolved_channel = if channel && event_suffix
                             "#{channel}:#{event_suffix}"
                           else
                             channel
                           end

        reply_to_raw = raw["r"]?
        reply_to = reply_to_raw.as_s if reply_to_raw && reply_to_raw.raw.is_a?(String)

        new(
          content: raw["c"],
          headers: headers,
          reply_to: reply_to,
          id: id || raw["i"].as_s,
          channel: resolved_channel,
          consumer_group: consumer_group
        )
      end
    end
  end
end
