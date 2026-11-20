# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "opentelemetry"

# The upstream shard's `API::Span#to_protobuf` does not serialize the span
# status — `span.status =` values never reach the collector. Re-open the
# class and attach the status after the upstream serialization.
class OpenTelemetry::API::Span
  def to_protobuf
    span = previous_def
    if status = @status
      span.status = status
    end
    span
  end
end
