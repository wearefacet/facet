# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"

module Facet
  module Event
    module Subscriber
      # Module-scoped source so every class below resolves `Log` lexically
      # to this constant. Without it, bare `Log` inside `Base` / `Stream`
      # falls through to `Facet::Event::Log` (defined in `manager.cr`) and
      # a nested `Log.for(...)` doubles the source (seen as
      # `facet.event.facet.event.subscriber` on the wire). The sibling
      # subscribers declare their own `Log` constant for the same reason.
      Log = ::Log.for("facet.event.subscriber")

      # Base class for subscribers.
      # Provides the shared start/stop/subscribe interface.
      class Base
        getter channels : Array(Tuple(String, Bool)) # [channel, lock?]

        # The block called on each message: (channel, message) -> Nil
        getter handler : Proc(String, Message, Nil)

        def initialize(@handler : Proc(String, Message, Nil))
          @channels = [] of Tuple(String, Bool)
          @stopped = true
        end

        # Add a channel to listen to.
        # `lock: true` means only one consumer instance processes the message.
        def subscribe(channel : String, lock : Bool = false) : Nil
          raise "cannot subscribe while subscriber is running" unless @stopped

          @channels << {channel, lock}
        end

        def start : Nil
          @stopped = false
        end

        def stop : Nil
          @stopped = true
        end

        def stopped? : Bool
          @stopped
        end

        # Invoke the handler callback for a given channel and message.
        def process_message(channel : String, message : Message) : Nil
          @handler.call(channel, message)
        rescue e : Exception
          Log.error { "Event handler error on #{channel}: #{e.message}" }
          Event::Loss.record_dropped_message
        end
      end
    end
  end
end
