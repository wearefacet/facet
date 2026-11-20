# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/stream/session"
require "../../../src/assistant/stream/cancel_bus"
require "../../../src/assistant/conversation"
require "../../../src/assistant/turn"
require "../../../src/assistant/resume"
require "../../../src/system_settings"
require "../../../src/doctype/seed"
# `spec_helper` loads `src/http/auth_handler`. Its bearer-bypass rule reads
# `Facet::MCP::PATH_PREFIX`, and the mock server below makes every
# `HTTP::Handler` in the program reachable, so that line gets type-checked
# even though no handler runs. `auth_handler.cr` requires the MCP module
# itself, so a standalone run type-checks without extra requires.
require "../../support/http_helper"
require "http"
require "json"

# A mock OpenAI-compatible server that streams deterministic SSE responses.
# Modeled on lib/agent-cr/spec/agent_spec.cr's `with_mock_server`. Lets the
# session spec exercise happy/cancel/error paths without the real OpenAI API.
#
# The server is parameterized by a `Mode` that controls what it sends:
# - `Happy`: emits content chunks + a final message with finish_reason "stop".
# - `Error`: returns a non-2xx HTTP status so agent-cr raises ApiError.
# - `Slow`: blocks on the gate after the first chunk, so the cancel spec
#   can publish a cancel mid-stream.
# - `ToolLoop`: first request returns a tool call (finish_reason
#   "tool_calls", usage 10/5/15), second request returns content
#   (finish_reason "stop", usage 20/8/28). With a tool registered and
#   `auto_execute_tools`, the session runs a two-iteration loop; every
#   iteration bills separately. `request_count` records how many provider
#   calls were made.
# - `HappyNoUsage`: like `Happy`, but the final chunk carries no `usage`
#   object — the wire shape of an OpenAI-compatible provider that never
#   receives `stream_options: {include_usage: true}`. The turn succeeds;
#   the ledger must bill the anti-siphon estimate.
# - `Truncated`: streams content deltas then closes the connection
#   without a finish_reason chunk or a [DONE] sentinel — the provider
#   died mid-turn.
# A hard mid-stream drop — the socket closes before the chunked body is
# terminated, so the client's chunk decoder raises mid-frame and agent-cr
# wraps it as a ConnectionError — cannot be produced by an HTTP::Server
# handler (closing the response still writes the chunked terminator, which
# the client reads as a clean stream end). That shape lives in
# `HardDropServer` below.
class MockLLMServer
  enum Mode
    Happy
    HappyNoUsage
    Error
    Slow
    ToolLoop
    Truncated
    Cap
    Checkpoint
  end

  getter mode : Mode
  getter port : Int32
  getter request_count : Int32
  property gate : Channel(Nil)?
  @server : HTTP::Server
  @gated = false
  @tool_loop_requests = 0
  @checkpoint_requests = 0

  def initialize(@mode : Mode = Mode::Happy)
    @server = HTTP::Server.new do |ctx|
      handle(ctx)
    end
    address = @server.bind_tcp(0)
    @port = address.port
    @request_count = 0
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    if @mode.error?
      ctx.response.status_code = 500
      ctx.response.print("internal server error")
      return
    end

    if @mode.happy_no_usage?
      stream_happy(ctx, with_usage: false)
      return
    end

    if @mode.truncated?
      stream_truncated(ctx)
      return
    end

    if @mode.tool_loop?
      stream_tool_loop(ctx)
      return
    end

    if @mode.cap?
      stream_cap(ctx)
      return
    end

    if @mode.checkpoint?
      stream_checkpoint(ctx)
      return
    end

    stream_happy(ctx, with_usage: true)
  end

  # The happy path: content deltas, then a final chunk with finish_reason
  # "stop" and — when `with_usage` holds — the usage report. Without the
  # report the wire matches a provider that never asks for usage on
  # streams; the turn still completes normally.
  private def stream_happy(ctx : HTTP::Server::Context, with_usage : Bool) : Nil
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    chunks = ["Hel", "lo", " world"]
    chunks.each_with_index do |text, _idx|
      data = {
        choices: [{
          delta: {content: text},
          index: 0,
        }],
      }
      ctx.response.puts "data: #{data.to_json}"
      ctx.response.flush

      # In slow mode, block after the first chunk until the spec releases
      # the gate. The cancel publish then lands in Redis before the next
      # chunk, so the agent's between-lines cancel check observes it.
      # Gate once per request: after a cancel the session stops reading,
      # and a second receive would block this fiber forever.
      if @mode.slow? && !@gated
        @gated = true
        @gate.try(&.receive)
      end
    end

    final = if with_usage
              {
                choices: [{
                  delta:         {} of String => JSON::Any,
                  index:         0,
                  finish_reason: "stop",
                }],
                usage: {
                  prompt_tokens:     10,
                  completion_tokens: 5,
                  total_tokens:      15,
                },
              }
            else
              {
                choices: [{
                  delta:         {} of String => JSON::Any,
                  index:         0,
                  finish_reason: "stop",
                }],
              }
            end
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end

  # Streams partial content then closes the connection mid-turn: no
  # finish_reason chunk, no [DONE] sentinel, no usage report. The provider
  # died after delivering "Hello"; the turn must not read as a success.
  private def stream_truncated(ctx : HTTP::Server::Context) : Nil
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    ["Hel", "lo"].each do |text|
      data = {
        choices: [{
          delta: {content: text},
          index: 0,
        }],
      }
      ctx.response.puts "data: #{data.to_json}"
      ctx.response.flush
    end

    ctx.response.close
  end

  # Streams the two scripted turns of a tool loop. Request 1 answers with a
  # tool call and its own usage; request 2 (after the agent executes the
  # registered tool) answers with content and different usage. Each iteration
  # therefore bills its own tokens on the wire.
  # Every request answers with one tool-call stream. agent-cr loops until
  # its `max_tool_iterations` cap fires, so the turn exercises the capped
  # exit path end to end (100 provider calls, then `ToolLoopError`).
  private def stream_cap(ctx : HTTP::Server::Context) : Nil
    ctx.request.body.try(&.gets_to_end)
    @request_count += 1
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    call_1 = {
      choices: [{
        delta: {
          tool_calls: [{
            index:    0,
            id:       "call_#{@request_count}",
            type:     "function",
            function: {name: "lookup_weather", arguments: ""},
          }],
        },
        index: 0,
      }],
    }
    call_2 = {
      choices: [{
        delta: {
          tool_calls: [{
            index:    0,
            function: {arguments: %({"city":"Paris"})},
          }],
        },
        index: 0,
      }],
    }
    final = {
      choices: [{
        delta:         {} of String => JSON::Any,
        index:         0,
        finish_reason: "tool_calls",
      }],
      usage: {
        prompt_tokens:     10,
        completion_tokens: 5,
        total_tokens:      15,
      },
    }
    ctx.response.puts "data: #{call_1.to_json}"
    ctx.response.puts "data: #{call_2.to_json}"
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end

  # Iteration 1 answers with a tool-call stream (a complete exchange
  # commits to the history); iteration 2 sleeps past the session's
  # 2s checkpoint throttle, streams one content chunk, then blocks on
  # the gate. While the gate holds, the spec observes the checkpoint of
  # the committed first iteration in the running row.
  private def stream_checkpoint(ctx : HTTP::Server::Context) : Nil
    ctx.request.body.try(&.gets_to_end)
    @checkpoint_requests += 1
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    if @checkpoint_requests == 1
      write_tool_call_stream(ctx, "call_1")
    else
      sleep 2.2.seconds
      content = {
        choices: [{
          delta: {content: "Working"},
          index: 0,
        }],
      }
      ctx.response.puts "data: #{content.to_json}"
      ctx.response.flush
      @gate.try(&.receive)
      final = {
        choices: [{
          delta:         {} of String => JSON::Any,
          index:         0,
          finish_reason: "stop",
        }],
        usage: {
          prompt_tokens:     20,
          completion_tokens: 8,
          total_tokens:      28,
        },
      }
      ctx.response.puts "data: #{final.to_json}"
      ctx.response.puts "data: [DONE]"
      ctx.response.flush
      ctx.response.close
    end
  end

  # One tool-call exchange as SSE deltas: id + empty arguments, then the
  # arguments, then `finish_reason: "tool_calls"` with a usage report.
  private def write_tool_call_stream(ctx : HTTP::Server::Context, call_id : String) : Nil
    call_1 = {
      choices: [{
        delta: {
          tool_calls: [{
            index:    0,
            id:       call_id,
            type:     "function",
            function: {name: "lookup_weather", arguments: ""},
          }],
        },
        index: 0,
      }],
    }
    call_2 = {
      choices: [{
        delta: {
          tool_calls: [{
            index:    0,
            function: {arguments: %({"city":"Paris"})},
          }],
        },
        index: 0,
      }],
    }
    final = {
      choices: [{
        delta:         {} of String => JSON::Any,
        index:         0,
        finish_reason: "tool_calls",
      }],
      usage: {
        prompt_tokens:     10,
        completion_tokens: 5,
        total_tokens:      15,
      },
    }
    ctx.response.puts "data: #{call_1.to_json}"
    ctx.response.puts "data: #{call_2.to_json}"
    ctx.response.puts "data: #{final.to_json}"
    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end

  private def stream_tool_loop(ctx : HTTP::Server::Context) : Nil
    # Drain the request body so keep-alive framing stays valid for the
    # second request on the same pooled connection.
    ctx.request.body.try(&.gets_to_end)
    @tool_loop_requests += 1
    @request_count = @tool_loop_requests
    ctx.response.content_type = "text/event-stream"
    ctx.response.status_code = 200

    if @tool_loop_requests == 1
      call_1 = {
        choices: [{
          delta: {
            tool_calls: [{
              index:    0,
              id:       "call_1",
              type:     "function",
              function: {name: "lookup_weather", arguments: ""},
            }],
          },
          index: 0,
        }],
      }
      call_2 = {
        choices: [{
          delta: {
            tool_calls: [{
              index:    0,
              function: {arguments: %({"city":"Paris"})},
            }],
          },
          index: 0,
        }],
      }
      final = {
        choices: [{
          delta:         {} of String => JSON::Any,
          index:         0,
          finish_reason: "tool_calls",
        }],
        usage: {
          prompt_tokens:     10,
          completion_tokens: 5,
          total_tokens:      15,
        },
      }
      ctx.response.puts "data: #{call_1.to_json}"
      ctx.response.puts "data: #{call_2.to_json}"
      ctx.response.puts "data: #{final.to_json}"
    else
      content = {
        choices: [{
          delta: {content: "Paris is sunny"},
          index: 0,
        }],
      }
      final = {
        choices: [{
          delta:         {} of String => JSON::Any,
          index:         0,
          finish_reason: "stop",
        }],
        usage: {
          prompt_tokens:     20,
          completion_tokens: 8,
          total_tokens:      28,
        },
      }
      ctx.response.puts "data: #{content.to_json}"
      ctx.response.puts "data: #{final.to_json}"
    end

    ctx.response.puts "data: [DONE]"
    ctx.response.flush
    ctx.response.close
  end
end

# A raw TCP server that reproduces the genuine hard provider drop: it
# answers one streamed SSE chunk, then closes the socket before the
# chunked body is terminated. The client's chunk decoder hits a mid-frame
# EOF and raises ("End of file reached"); agent-cr wraps it as a
# ConnectionError, and its request loop rolls the history back to the turn
# boundary — the wire shape of a provider container restart mid-stream
# (B-373). An HTTP::Server handler cannot produce this: closing the
# response still writes the chunked terminator, which the client reads as
# a clean stream end.
class HardDropServer
  getter port : Int32
  @server : TCPServer

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    loop do
      sock = @server.accept? || break
      spawn { drop_after_first_chunk(sock) }
    end
  rescue IO::Error
    # Server closed — the spec is tearing the mock down.
  end

  # One framed SSE chunk with content "Hel", then an abrupt socket close.
  # The request is drained first so the close lands as a FIN (mid-frame
  # EOF) rather than a reset — a reset could discard buffered bytes before
  # the client reads them.
  private def drop_after_first_chunk(sock : TCPSocket) : Nil
    drain_request(sock)
    sock.write "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice
    body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"},\"index\":0}]}\n\n"
    sock.write "#{body.bytesize.to_s(16)}\r\n#{body}\r\n".to_slice
    sock.flush
    sock.close
  rescue IO::Error
    sock.close
  rescue
    # The spec tore the socket down mid-handshake — nothing to answer.
  end

  # Reads the request head and, when Content-Length is present, its body so
  # the socket holds no unread bytes when the response closes.
  private def drain_request(sock : TCPSocket) : Nil
    content_length = 0
    while line = sock.gets(chomp: true)
      break if line.empty?
      value = line.match(/Content-Length: (\d+)/i).try(&.[1])
      content_length = value.to_i if value
    end
    buffer = Bytes.new(4096)
    while content_length > 0
      read = sock.read(buffer)
      break if read.zero?
      content_length -= read
    end
  rescue IO::Error
    # Client went away mid-request — the close below is a no-op then.
  end
end

# A raw TCP server for a drop whose only output was a tool call: the first
# request answers a complete tool-call turn (finish_reason `tool_calls`,
# usage) so the agent executes the tool and commits its result to history;
# the second request — after the tool loop — drops the socket mid-frame
# before any content chunk. No content or reasoning chunk ever reaches the
# client, so `streamed_content`/`streamed_reasoning` stay empty, but the
# tool result is already in `agent.history` (NS-17).
class ToolDropServer
  getter port : Int32
  @server : TCPServer
  @requests = 0

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    loop do
      sock = @server.accept? || break
      spawn { handle(sock) }
    end
  rescue IO::Error
    # Server closed — the spec is tearing the mock down.
  end

  private def handle(sock : TCPSocket) : Nil
    drain_request(sock)
    @requests += 1
    sock.write "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".to_slice
    if @requests == 1
      write_tool_call_turn(sock)
      # The request closes cleanly (chunked terminator) so the agent's tool
      # loop continues to the second request.
      sock.write "0\r\n\r\n".to_slice
    else
      # The drop: one empty frame then an abrupt close mid-frame.
      body = "data: {\"choices\":[{\"delta\":{},\"index\":0}]}\n\n"
      sock.write "#{body.bytesize.to_s(16)}\r\n#{body}\r\n".to_slice
    end
    sock.flush
    sock.close
  rescue IO::Error
    sock.close
  rescue
    # The spec tore the socket down mid-handshake — nothing to answer.
  end

  private def write_tool_call_turn(sock : TCPSocket) : Nil
    delta = %({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]},"index":0}]})
    finish = %({"choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
    done = "[DONE]"
    body = "data: #{delta}\n\ndata: #{finish}\n\ndata: #{done}\n\n"
    sock.write "#{body.bytesize.to_s(16)}\r\n#{body}\r\n".to_slice
  end

  private def drain_request(sock : TCPSocket) : Nil
    content_length = 0
    while line = sock.gets(chomp: true)
      break if line.empty?
      value = line.match(/Content-Length: (\d+)/i).try(&.[1])
      content_length = value.to_i if value
    end
    buffer = Bytes.new(4096)
    while content_length > 0
      read = sock.read(buffer)
      break if read.zero?
      content_length -= read
    end
  rescue IO::Error
    # Client went away mid-request — the close below is a no-op then.
  end
end

# A tiny IO that captures all writes and supports flush as a no-op. Used so the
# session spec can inspect the exact SSE output the Session produced.
class SSECapture < IO
  getter chunks : Array(String) = [] of String

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @chunks << String.new(slice)
  end

  def flush : Nil
  end

  def to_s : String
    @chunks.join
  end
end

# An SSE sink that dies on the FLUSH — the exact signature of a client
# disconnect (Crystal wraps the flush failure in `ClientError`). Verifies
# the guard: writes before the first flush succeed, everything after the
# first flush is a silent no-op, and the turn itself carries on.
class DeadOnFlushSSE < IO
  getter chunks : Array(String) = [] of String
  getter write_count : Int32 = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @write_count += 1
    @chunks << String.new(slice)
  end

  def flush : Nil
    raise ::HTTP::Server::ClientError.new("Error while flushing data to the client")
  end

  def to_s : String
    @chunks.join
  end
end

# An SSE sink that dies on the first WRITE with the raw `IO::Error` the
# closed response output raises (`check_open` → "Closed stream").
class DeadOnWriteSSE < IO
  getter chunks : Array(String) = [] of String
  getter write_count : Int32 = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @write_count += 1
    raise IO::Error.new("Closed stream")
  end

  def flush : Nil
  end

  def to_s : String
    @chunks.join
  end
end

# Builds a real `OpenSSL::SSL::Error` for the disconnect-guard specs. The
# constructor derives its message through `SSL_get_error`, which returns
# `SSL_ERROR_NONE` without dereferencing the SSL handle when the return
# code is positive — so a null handle with a positive code yields a valid
# instance. Only its class (no `IO::Error` subclass) and message matter to
# the transport guards.
private def tls_transport_error : OpenSSL::SSL::Error
  ssl_handle = uninitialized LibSSL::SSL
  OpenSSL::SSL::Error.new(ssl_handle, 1, "SSL_write")
end

# An SSE sink that dies on the first WRITE with the `OpenSSL::SSL::Error`
# a TLS-terminated listener raises from `SSL_write` when the client
# disconnects mid-stream. The class is no `IO::Error` subclass, so the
# disconnect guard must name it explicitly — the exact F10-L gap.
class DeadOnTLSWriteSSE < IO
  getter chunks : Array(String) = [] of String
  getter write_count : Int32 = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @write_count += 1
    raise tls_transport_error
  end

  def flush : Nil
  end

  def to_s : String
    @chunks.join
  end
end

private def create_test_conversation(db, api_endpoint, session_id = "sess-stream", cache_key = "ck-stream", max_history : Int32? = nil)
  # The connection resolves from the effective settings at turn start, so
  # the spec pins the endpoint (and the model the usage assertions expect)
  # on the settings singleton — the same save an admin would make. The
  # seed helper re-created the doctype + null singleton this example.
  Facet::Doctype::Seed.ensure_doctype(db, "core", "SystemSettings")
  assistant_json = if max_history
                     %({"assistant": {"api_endpoint": "#{api_endpoint}/v1", "model": "gpt-4o", "max_history": #{max_history}}})
                   else
                     %({"assistant": {"api_endpoint": "#{api_endpoint}/v1", "model": "gpt-4o"}})
                   end
  result = Facet::Document::Update.call(
    db, "core", "SystemSettings", Facet::SystemSettings::DOC_ID,
    assistant_json,
    Facet::RBAC::AuthContext.system,
  )
  result.should be_a(Facet::Document::Update::Result)
  Facet::SystemSettings.mark_stale

  conv = Facet::Assistant::Conversation.create(
    db,
    session_id: session_id,
    cache_key: cache_key,
    system_prompt: "You are a test assistant.",
    context: "{}",
    enabled_tools: "[]",
  )
  conv.as(Facet::Assistant::Conversation::Result::Created).record.id
end

# Opens a `running` turn row for the conversation, mirroring what the
# stream route does before `Session#run`. Returns the turn id.
private def open_test_turn(db, conversation_id, content) : String
  result = Facet::Assistant::Turn.open(
    db,
    conversation_id,
    Facet::Assistant::Stream::Session.request_messages_json(content),
  )
  result.as(Facet::Assistant::Turn::Result::Created).record.id
end

# Queries the `assistant_usage` rows of one conversation.
private def usage_rows(db, conversation_id)
  db.query_all(
    "SELECT account_id, conversation_id, turn_id, model, input_tokens, output_tokens, estimated " \
    "FROM assistant_usage WHERE conversation_id = $1",
    conversation_id,
    as: {String, String, String, String?, Int64, Int64, Bool},
  )
end

# Serialises messages into the shape the `agent_turns` jsonb columns hold.
private def turn_messages_json(messages : Array(Agent::Message)) : String
  JSON.build { |json| json.array { messages.each(&.to_json(json)) } }
end

private def turn_usage_json(prompt : Int32, completion : Int32) : String
  Agent::Usage.new(
    prompt_tokens: prompt,
    completion_tokens: completion,
    total_tokens: prompt + completion,
  ).to_json
end

# Seeds one completed turn row. Its request + response messages join the
# replay context the next turn's `Resume` reconstructs — the same shape a
# streamed done turn leaves behind.
private def seed_done_turn(db, conversation_id, content, reply) : Nil
  Facet::Assistant::Turn.create(
    db,
    conversation_id,
    Facet::Assistant::Stream::Session.request_messages_json(content),
    turn_messages_json([Agent::Message.assistant(reply)]),
    turn_usage_json(1, 1),
    finish_reason: "stop",
  )
end

describe Facet::Assistant::Stream::Session do
  redis_url = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

  before_each do
    # Flush the cancel-bus Redis DB.
    client = ::Redis::Client.new(URI.parse(redis_url))
    client.flushdb
    client.close
  end

  # Builds a conversation row directly in the DB whose config endpoint points
  # at the given mock server port. Bypasses the HTTP create route so the
  # session spec has a conversation to stream against.
  # (moved above the describe — Crystal doesn't allow def inside describe)

  describe "happy path" do
    it "emits the route-provided turn token on the meta event" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          # The stream route generates the token before `Turn.open` and hands
          # the same value to the session, so the persisted row and the live
          # cancel channel agree from the start.
          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            turn_token: "route-generated-token",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          session.run(capture, redis_url, 5, turn_id)

          capture.to_s.should contain(
            "event: meta\ndata: {\"turn_token\":\"route-generated-token\"}")
        end
      ensure
        server.close
      end
    end

    it "streams chunks and persists a turn with finish_reason stop" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          sse = capture.to_s
          sse.should contain("event: meta")
          sse.scan("event: chunk").size.should eq(3)
          sse.should contain("event: done")
          sse.should contain("\"finish_reason\":\"stop\"")

          result.cancelled.should be_false
          result.error.should be_nil
          result.finish_reason.should eq("stop")
          result.turn_id.should eq(turn_id)

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("done")
          turn.finish_reason.should eq("stop")
          turn.error.should be_nil
          request = turn.request_messages.as_a
          request.size.should eq(1)
          request.first["role"].as_s.should eq("user")
          request.first["content"].as_s.should eq("hello")
          response = turn.response_messages.as_a
          response.size.should be >= 1
          response.last["role"].as_s.should eq("assistant")
          response.last["content"].as_s.should eq("Hello world")
        end
      ensure
        server.close
      end
    end
  end

  describe "error path" do
    it "persists a turn with error when provider returns 5xx" do
      server = MockLLMServer.new(MockLLMServer::Mode::Error)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hi",
          )

          turn_id = open_test_turn(db, conversation_id, "hi")
          result = session.run(capture, redis_url, 5, turn_id)

          sse = capture.to_s
          sse.should contain("event: error")
          result.error.should_not be_nil
          result.cancelled.should be_false

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("error")
          turn.error.should_not be_nil
          turn.finish_reason.should be_nil
          turn.response_messages.as_a.should be_empty
        end
      ensure
        server.close
      end
    end
  end

  describe "truncation path" do
    it "persists an error turn when the stream ends without a finish reason" do
      server = MockLLMServer.new(MockLLMServer::Mode::Truncated)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          sse = capture.to_s
          # The terminal event is an error, never a done.
          sse.should contain("event: error")
          sse.should contain("provider stream ended before the response completed")
          sse.should_not contain("event: done")

          result.cancelled.should be_false
          result.finish_reason.should be_nil
          result.error.should eq(
            "truncated: provider stream ended before the response completed",
          )
          result.turn_id.should eq(turn_id)

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("error")
          turn.finish_reason.should be_nil
          turn.error.should eq(
            "truncated: provider stream ended before the response completed",
          )
          # The partial exchange survives so `Resume` restores it on the
          # next ask — same contract as a cancelled turn.
          response = turn.response_messages.as_a
          response.should_not be_empty
          response.last["role"].as_s.should eq("assistant")
          response.last["content"].as_s.should eq("Hello")
        end
      ensure
        server.close
      end
    end

    it "bills an estimated row for a successful turn the provider never reported on" do
      server = MockLLMServer.new(MockLLMServer::Mode::HappyNoUsage)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            account_id: "acct_1",
          )
          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          # The turn itself is a normal success.
          result.error.should be_nil
          capture.to_s.should contain("event: done")

          # A provider without a usage report still delivered the answer —
          # the anti-siphon estimate bills it, so the token budget sees
          # every streamed turn.
          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          _account_id, _conv, row_turn_id, model, input_tokens, output_tokens, estimated = rows.first
          row_turn_id.should eq(Facet::Assistant::Turn.list(db, conversation_id).first.id)
          model.should eq("gpt-4o")
          estimated.should be_true
          (input_tokens + output_tokens).should be > 0
        end
      ensure
        server.close
      end
    end

    it "bills an estimated row for a truncated turn the provider never reported on" do
      server = MockLLMServer.new(MockLLMServer::Mode::Truncated)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            account_id: "acct_1",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)
          result.error.should_not be_nil
          result.cancelled.should be_false

          # The turn delivered streamed output — the anti-siphon estimate
          # bills it, like a cancelled turn: one `estimated` row with
          # non-zero counts.
          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          _account_id, _conv, row_turn_id, model, input_tokens, output_tokens, estimated = rows.first
          row_turn_id.should eq(Facet::Assistant::Turn.list(db, conversation_id).first.id)
          model.should eq("gpt-4o")
          estimated.should be_true
          (input_tokens + output_tokens).should be > 0
        end
      ensure
        server.close
      end
    end
    it "persists the streamed partial when a hard mid-stream drop rolls history back" do
      server = HardDropServer.new
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            account_id: "acct_1",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          sse = capture.to_s
          # The raw IO message never reaches the client or the audit trail:
          # a drop that delivered content is a truncation, not a provider
          # error of unknown shape.
          sse.should contain("event: error")
          sse.should contain("truncated: provider stream ended before the response completed")
          sse.should_not contain("End of file reached")

          result.error.should eq(
            "truncated: provider stream ended before the response completed",
          )
          result.cancelled.should be_false
          result.turn_id.should eq(turn_id)

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("error")
          turn.error.should eq(
            "truncated: provider stream ended before the response completed",
          )
          # B-373: the drop makes agent-cr roll history back to the turn
          # boundary, so the session rebuilds the assistant partial from the
          # drained chunks — exactly the streamed text, nothing else.
          response = turn.response_messages.as_a
          response.size.should eq(1)
          response.first["role"].as_s.should eq("assistant")
          response.first["content"].as_s.should eq("Hel")
        end
      ensure
        server.close
      end
    end

    it "persists the committed tool result when a drop delivered no text chunk" do
      server = ToolDropServer.new
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          registrar = ->(agent : Agent) do
            agent.register_tool(
              "lookup_weather",
              "Look up the weather for a city",
              parameters: Agent::JSONConverter.from({
                type:       "object",
                properties: {
                  city: {type: "string"},
                },
                required: ["city"],
              }),
            ) do |args|
              city = args["city"]?.try(&.as_s) || "unknown"
              "Sunny, 18 degrees in #{city}"
            end
          end

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "What is the weather in Paris?",
            account_id: "acct_1",
            tool_registrar: registrar,
          )

          turn_id = open_test_turn(db, conversation_id, "What is the weather in Paris?")
          result = session.run(capture, redis_url, 5, turn_id)

          result.error.should eq(
            "truncated: provider stream ended before the response completed",
          )

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turn = turns.first
          turn.status.should eq("error")
          # NS-17: a drop after a tool-call turn keeps the committed history.
          # The row must not be the empty "failed before output" shape.
          response = turn.response_messages.as_a
          response.should_not be_empty
          response.last["role"].as_s.should eq("assistant")
          response.last["tool_calls"].as_a.should_not be_empty
        end
      ensure
        server.close
      end
    end
  end

  describe "cancel path" do
    it "persists a cancelled turn when cancel arrives mid-stream" do
      server = MockLLMServer.new(MockLLMServer::Mode::Slow)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          # Run on a background fiber so we can parse the meta event and
          # publish a cancel while the stream is still draining. The mock
          # blocks on the gate after its first chunk; release it only after
          # the cancel is in Redis.
          gate = Channel(Nil).new
          server.gate = gate

          turn_id = open_test_turn(db, conversation_id, "hello")
          done = Channel(Facet::Assistant::Stream::Session::Result).new
          spawn do
            done.send(session.run(capture, redis_url, 5, turn_id))
          end

          # Wait for the meta event, then publish a cancel.
          match = wait_for { capture.to_s.match(/event: meta\ndata: \{"turn_token":"([^"]+)"\}/) }
          turn_token = match.try(&.[1])
          turn_token.should_not be_nil

          Facet::Assistant::Stream::CancelBus.publish(turn_token.not_nil!, redis_url, 5)
          # Wait until the cancel subscriber has observably flipped the flag
          # BEFORE the gate release: the parser checks cancellation before
          # each blocking read, so the flag must be set by the time the
          # post-gate burst arrives — otherwise the turn races to a normal
          # finish and the cancelled-turn assertions below fail by chance.
          wait_for { session.cancel_requested? }.should be_true
          gate.send(nil)

          result = done.receive

          sse = capture.to_s
          sse.should contain("event: cancelled")
          result.cancelled.should be_true
          result.error.should eq("cancelled")

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("cancelled")
          turn.error.should eq("cancelled")
          turn.finish_reason.should be_nil
          # The cancelled turn keeps the partial context (the streamed assistant
          # reply) so `Resume` can restore it on the next #ask. The turn's own
          # user message is NOT part of it — `request_messages` already carries
          # it, and a duplicate would replay the user turn twice.
          turn.response_messages.as_a.should_not be_empty
          turn.response_messages.as_a.first["role"].as_s.should eq("assistant")
        end
      ensure
        server.close
      end
    end
  end

  describe "tool-loop cap path" do
    it "persists a capped turn with the resumable partial exchange" do
      server = MockLLMServer.new(MockLLMServer::Mode::Cap)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          registrar = ->(agent : Agent) do
            agent.register_tool(
              "lookup_weather",
              "Look up the weather for a city",
              parameters: Agent::JSONConverter.from({
                type:       "object",
                properties: {
                  city: {type: "string"},
                },
                required: ["city"],
              }),
            ) do |args|
              city = args["city"]?.try(&.as_s) || "unknown"
              "Sunny, 18 degrees in #{city}"
            end
          end

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "What is the weather in Paris?",
            account_id: "acct_1",
            tool_registrar: registrar,
          )

          turn_id = open_test_turn(db, conversation_id, "What is the weather in Paris?")
          result = session.run(capture, redis_url, 5, turn_id)

          # The loop ran to the cap: 100 provider calls, then the pre-flight
          # bailout before the 101st.
          server.request_count.should eq(100)
          sse = capture.to_s
          sse.should contain("event: error")
          sse.should contain("tool call iteration limit (100) exceeded")
          result.error.not_nil!.should contain("tool call iteration limit (100)")
          result.cancelled.should be_false
          result.turn_id.should eq(turn_id)

          turns = Facet::Assistant::Turn.list(db, conversation_id)
          turns.size.should eq(1)
          turn = turns.first
          turn.status.should eq("capped")
          turn.error.not_nil!.should contain("tool call iteration limit (100)")
          turn.finish_reason.should be_nil

          # The partial exchange is complete at every iteration boundary:
          # it starts with the first assistant tool_calls message (the user
          # message lives in request_messages) and ends on a committed tool
          # result — a valid provider prefix the next ask continues from.
          response = turn.response_messages.as_a
          response.should_not be_empty
          response.first["role"].as_s.should eq("assistant")
          response.first["tool_calls"].as_a.should_not be_empty
          response.last["role"].as_s.should eq("tool")

          # The capped turn feeds the next turn's replay context.
          resume = Facet::Assistant::Resume.call(db, conversation_id)
          history = resume.as(Facet::Assistant::Resume::Result::Restored).session.history
          history.size.should be > 2
          history.first.role.to_s.should eq("user")
          history.last.role.to_s.should eq("tool")

          # The turn delivered output, so the ledger billed it.
          usage_rows(db, conversation_id).size.should eq(1)
        end
      ensure
        server.close
      end
    end
  end

  describe "running-turn checkpoint" do
    it "persists the committed iteration into the running row while the provider streams" do
      server = MockLLMServer.new(MockLLMServer::Mode::Checkpoint)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          registrar = ->(agent : Agent) do
            agent.register_tool(
              "lookup_weather",
              "Look up the weather for a city",
              parameters: Agent::JSONConverter.from({
                type:       "object",
                properties: {
                  city: {type: "string"},
                },
                required: ["city"],
              }),
            ) do |args|
              city = args["city"]?.try(&.as_s) || "unknown"
              "Sunny, 18 degrees in #{city}"
            end
          end

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "What is the weather in Paris?",
            tool_registrar: registrar,
          )

          gate = Channel(Nil).new
          server.gate = gate

          turn_id = open_test_turn(db, conversation_id, "What is the weather in Paris?")
          done = Channel(Facet::Assistant::Stream::Session::Result).new
          spawn do
            done.send(session.run(capture, redis_url, 5, turn_id))
          end

          # Iteration 1 committed (tool result in the history) and
          # iteration 2's first content chunk arrived (after the mock's
          # 2.2s delay, so the checkpoint throttle window has passed) —
          # the checkpoint of the committed exchange must be in the
          # running row now.
          checkpointed = wait_for(10.0) do
            turn = Facet::Assistant::Turn.list(db, conversation_id).first
            turn.status == "running" && turn.response_messages.as_a.size == 2
          end
          checkpointed.should be_true
          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("running")
          response = turn.response_messages.as_a
          response.first["role"].as_s.should eq("assistant")
          response.first["tool_calls"].as_a.should_not be_empty
          response.last["role"].as_s.should eq("tool")

          # The catch-up poll sees the same partial.
          latest = Facet::Assistant::Turn.latest(db, conversation_id)
          latest.not_nil!.response_messages.as_a.size.should eq(2)

          # Release the gate; the turn completes normally and the terminal
          # persist overwrites the checkpoint with the full exchange.
          gate.send(nil)
          result = done.receive
          result.error.should be_nil
          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("done")
          turn.response_messages.as_a.size.should eq(3)
        end
      ensure
        server.close
      end
    end
  end

  describe "usage ledger" do
    it "inserts one usage row for a billed turn of an account-attributed session" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            account_id: "acct_1",
          )
          turn_id = open_test_turn(db, conversation_id, "hello")
          session.run(capture, redis_url, 5, turn_id)

          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          account_id, _conv, row_turn_id, model, input_tokens, output_tokens, estimated = rows.first
          account_id.should eq("acct_1")
          row_turn_id.should eq(Facet::Assistant::Turn.list(db, conversation_id).first.id)
          model.should eq("gpt-4o")
          input_tokens.should eq(10)
          output_tokens.should eq(5)
          # The provider reported real counts — the row is not an estimate.
          estimated.should be_false
        end
      ensure
        server.close
      end
    end

    it "inserts no usage row when the session has no account_id" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )
          turn_id = open_test_turn(db, conversation_id, "hello")
          session.run(capture, redis_url, 5, turn_id)

          # The turn persisted, but nothing was attributed.
          Facet::Assistant::Turn.list(db, conversation_id).size.should eq(1)
          usage_rows(db, conversation_id).should be_empty
        end
      ensure
        server.close
      end
    end

    it "bills an estimated row for a cancelled turn the provider never reported on" do
      server = MockLLMServer.new(MockLLMServer::Mode::Slow)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
            account_id: "acct_1",
          )

          gate = Channel(Nil).new
          server.gate = gate

          turn_id = open_test_turn(db, conversation_id, "hello")
          done = Channel(Facet::Assistant::Stream::Session::Result).new
          spawn do
            done.send(session.run(capture, redis_url, 5, turn_id))
          end

          match = wait_for { capture.to_s.match(/event: meta\ndata: \{"turn_token":"([^"]+)"\}/) }
          turn_token = match.try(&.[1])
          turn_token.should_not be_nil

          Facet::Assistant::Stream::CancelBus.publish(turn_token.not_nil!, redis_url, 5)
          # Wait until the cancel subscriber has observably flipped the flag
          # BEFORE the gate release: the parser checks cancellation before
          # each blocking read, so the flag must be set by the time the
          # post-gate burst arrives — otherwise the turn races to a normal
          # finish with real usage (and the row is legitimately not
          # estimated).
          wait_for { session.cancel_requested? }.should be_true
          gate.send(nil)
          result = done.receive
          result.cancelled.should be_true

          # The abort kills the provider's final usage report, but the turn
          # delivered streamed output — the anti-siphon estimate bills it:
          # one `estimated` row with non-zero counts (the serialized prompt
          # alone guarantees a non-zero input side).
          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          _account_id, _conv, row_turn_id, model, input_tokens, output_tokens, estimated = rows.first
          row_turn_id.should eq(Facet::Assistant::Turn.list(db, conversation_id).first.id)
          model.should eq("gpt-4o")
          estimated.should be_true
          (input_tokens + output_tokens).should be > 0
        end
      ensure
        server.close
      end
    end

    it "inserts no usage row for a cancelled turn with no account attribution" do
      server = MockLLMServer.new(MockLLMServer::Mode::Slow)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          gate = Channel(Nil).new
          server.gate = gate

          turn_id = open_test_turn(db, conversation_id, "hello")
          done = Channel(Facet::Assistant::Stream::Session::Result).new
          spawn do
            done.send(session.run(capture, redis_url, 5, turn_id))
          end

          match = wait_for { capture.to_s.match(/event: meta\ndata: \{"turn_token":"([^"]+)"\}/) }
          turn_token = match.try(&.[1])
          turn_token.should_not be_nil

          Facet::Assistant::Stream::CancelBus.publish(turn_token.not_nil!, redis_url, 5)
          # Wait until the cancel subscriber has observably flipped the flag
          # BEFORE the gate release — same synchronization as the cancel-path
          # test above: an early gate release races the turn to a normal
          # finish, and `result.cancelled` is false by chance, not by design.
          wait_for { session.cancel_requested? }.should be_true
          gate.send(nil)
          result = done.receive
          result.cancelled.should be_true

          # The turn persisted, but nothing was attributed.
          Facet::Assistant::Turn.list(db, conversation_id).size.should eq(1)
          usage_rows(db, conversation_id).should be_empty
        end
      ensure
        server.close
      end
    end

    it "inserts no usage row for a terminal error turn (reported-only counting)" do
      server = MockLLMServer.new(MockLLMServer::Mode::Error)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hi",
            account_id: "acct_1",
          )
          turn_id = open_test_turn(db, conversation_id, "hi")
          result = session.run(capture, redis_url, 5, turn_id)

          result.error.should_not be_nil
          result.cancelled.should be_false

          # Errors never estimate: nothing was delivered, so there is
          # nothing to siphon, and the provider reported nothing.
          Facet::Assistant::Turn.list(db, conversation_id).size.should eq(1)
          usage_rows(db, conversation_id).should be_empty
        end
      ensure
        server.close
      end
    end
  end

  # A turn with N provider calls (a tool loop) must bill every iteration's
  # usage. This spec runs a two-iteration loop against a mock that bills both
  # iterations and asserts the persisted ledger usage (10+20 in, 5+8 out).
  describe "usage ledger — multi-iteration tool loop" do
    it "sums the usage of every iteration into the ledger" do
      server = MockLLMServer.new(MockLLMServer::Mode::ToolLoop)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          registrar = ->(agent : Agent) do
            agent.register_tool(
              "lookup_weather",
              "Look up the weather for a city",
              parameters: Agent::JSONConverter.from({
                type:       "object",
                properties: {
                  city: {type: "string"},
                },
                required: ["city"],
              }),
            ) do |args|
              city = args["city"]?.try(&.as_s) || "unknown"
              "Sunny, 18 degrees in #{city}"
            end
          end

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "What is the weather in Paris?",
            account_id: "acct_1",
            tool_registrar: registrar,
          )
          turn_id = open_test_turn(db, conversation_id, "What is the weather in Paris?")
          result = session.run(capture, redis_url, 5, turn_id)

          # The loop really ran: two provider calls, then a clean finish.
          server.request_count.should eq(2)
          result.cancelled.should be_false
          result.error.should be_nil
          result.finish_reason.should eq("stop")
          result.turn_id.should eq(turn_id)

          # One ledger row holding the SUM of both iterations' usage:
          # iteration 1 bills 10 in / 5 out, iteration 2 bills 20 in / 8 out.
          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          _account_id, _conversation_id, turn_id, model, input_tokens, output_tokens, estimated = rows.first
          model.should eq("gpt-4o")
          input_tokens.should eq(30)
          output_tokens.should eq(13)
          estimated.should be_false
          turn_id.should eq(Facet::Assistant::Turn.list(db, conversation_id).first.id)
        end
      ensure
        server.close
      end
    end
  end

  # The client-disconnect contract: a dead SSE sink is a transport fact,
  # never a turn failure. Both failure signatures occur in production —
  # the first flush after a browser refresh raises `ClientError`, every
  # later write on the closed output raises `IO::Error("Closed stream")`.
  # In both cases the turn must carry on server-side and persist its full
  # result, so a reconnecting client reads the complete reply.
  describe "client disconnect" do
    it "completes the turn when the sink dies on flush (ClientError)" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = DeadOnFlushSSE.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          # The turn completed server-side despite the dead sink.
          result.cancelled.should be_false
          result.error.should be_nil
          result.finish_reason.should eq("stop")
          result.turn_id.should eq(turn_id)

          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("done")
          turn.response_messages.as_a.last["content"].as_s.should eq("Hello world")
        end
      ensure
        server.close
      end
    end

    it "completes the turn when the sink dies on write (Closed stream)" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = DeadOnWriteSSE.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          result.cancelled.should be_false
          result.error.should be_nil
          result.finish_reason.should eq("stop")

          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("done")
          turn.response_messages.as_a.last["content"].as_s.should eq("Hello world")
        end
      ensure
        server.close
      end
    end

    it "completes the turn when the sink dies on write with a TLS transport error (OpenSSL::SSL::Error)" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = DeadOnTLSWriteSSE.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          turn_id = open_test_turn(db, conversation_id, "hello")
          result = session.run(capture, redis_url, 5, turn_id)

          # The TLS failure is a transport fact like any other dead sink:
          # the turn completes server-side and persists its full result.
          result.cancelled.should be_false
          result.error.should be_nil
          result.finish_reason.should eq("stop")

          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("done")
          turn.response_messages.as_a.last["content"].as_s.should eq("Hello world")
        end
      ensure
        server.close
      end
    end

    it "carries the tool loop through a dead sink and bills the ledger" do
      server = MockLLMServer.new(MockLLMServer::Mode::ToolLoop)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = DeadOnWriteSSE.new

          registrar = ->(agent : Agent) do
            agent.register_tool(
              "lookup_weather",
              "Look up the weather for a city",
              parameters: Agent::JSONConverter.from({
                type:       "object",
                properties: {
                  city: {type: "string"},
                },
                required: ["city"],
              }),
            ) do |args|
              city = args["city"]?.try(&.as_s) || "unknown"
              "Sunny, 18 degrees in #{city}"
            end
          end

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "What is the weather in Paris?",
            account_id: "acct_1",
            tool_registrar: registrar,
          )

          turn_id = open_test_turn(db, conversation_id, "What is the weather in Paris?")
          result = session.run(capture, redis_url, 5, turn_id)

          # The tool loop still ran to completion: the trace write could
          # not kill the agent fiber.
          server.request_count.should eq(2)
          result.error.should be_nil
          result.finish_reason.should eq("stop")

          turn = Facet::Assistant::Turn.list(db, conversation_id).first
          turn.status.should eq("done")
          rows = usage_rows(db, conversation_id)
          rows.size.should eq(1)
          _account_id, _conv, row_turn_id, _model, input_tokens, output_tokens = rows.first
          input_tokens.should eq(30)
          output_tokens.should eq(13)
          row_turn_id.should eq(turn_id)
        end
      ensure
        server.close
      end
    end

    it "keeps a running turn row observable while the provider streams" do
      server = MockLLMServer.new(MockLLMServer::Mode::Slow)
      begin
        with_db do |db|
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}")
          capture = SSECapture.new

          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "hello",
          )

          gate = Channel(Nil).new
          server.gate = gate

          turn_id = open_test_turn(db, conversation_id, "hello")
          done = Channel(Facet::Assistant::Stream::Session::Result).new
          spawn do
            done.send(session.run(capture, redis_url, 5, turn_id))
          end

          match = wait_for { capture.to_s.match(/event: meta\ndata: \{"turn_token":"([^"]+)"\}/) }
          turn_token = match.try(&.[1])
          turn_token.should_not be_nil

          # The pre-opened row is `running` while the provider streams.
          running = wait_for { Facet::Assistant::Turn.running_turn(db, conversation_id) }
          running.should_not be_nil
          running.not_nil!.id.should eq(turn_id)

          # `latest` exposes the same row to the catch-up poll.
          latest = Facet::Assistant::Turn.latest(db, conversation_id)
          latest.should_not be_nil
          latest.not_nil!.status.should eq("running")

          Facet::Assistant::Stream::CancelBus.publish(turn_token.not_nil!, redis_url, 5)
          gate.send(nil)
          done.receive
        end
      ensure
        server.close
      end
    end
  end

  # The F08-A residual: with a finite `assistant.max_history`, agent-cr's
  # mid-turn trim fires once per turn right before the response finishes
  # and drops a prefix of the history. A slice derived from the pre-ask
  # index goes stale: it loses the turn's leading messages, or raises
  # IndexError when the trim dropped more messages than the turn appended —
  # every later turn re-crashes and the conversation is dead. The persisted
  # `response_messages` must stay exactly this turn's assistant/tool
  # messages, whatever the trim dropped.
  describe "finite max history with a mid-turn trim" do
    it "persists exactly the turn's messages when the trim drops a prefix" do
      server = MockLLMServer.new(MockLLMServer::Mode::Happy)
      begin
        with_db do |db|
          # max_history = 2 keeps at most 4 user+assistant messages in the
          # agent history. Three seeded turns resume as 6, so the turn's own
          # user + assistant messages push the count to 8 and the trim drops
          # the first complete turn (2 messages) from the front — more than
          # the pre-ask index can survive.
          conversation_id = create_test_conversation(db, "http://localhost:#{server.port}", max_history: 2)
          seed_done_turn(db, conversation_id, "first", "reply1")
          seed_done_turn(db, conversation_id, "second", "reply2")
          seed_done_turn(db, conversation_id, "third", "reply3")

          capture = SSECapture.new
          session = Facet::Assistant::Stream::Session.new(
            db,
            conversation_id: conversation_id,
            content: "fourth",
          )

          turn_id = open_test_turn(db, conversation_id, "fourth")
          result = session.run(capture, redis_url, 5, turn_id)

          # The trim fired inside agent-cr before the response finished;
          # the turn must still complete as a normal done turn.
          result.error.should be_nil
          result.finish_reason.should eq("stop")
          capture.to_s.should contain("event: done")

          turn = Facet::Assistant::Turn.list(db, conversation_id).last
          turn.status.should eq("done")
          response = turn.response_messages.as_a
          # Exactly this turn's assistant message: no request message (it
          # lives in request_messages), no message from an earlier turn,
          # nothing lost to the trim.
          response.size.should eq(1)
          response.first["role"].as_s.should eq("assistant")
          response.first["content"].as_s.should eq("Hello world")

          # The replay concatenates both columns: the fourth turn
          # contributes its user message and its answer exactly once, and
          # no earlier turn lost its row.
          resume = Facet::Assistant::Resume.call(db, conversation_id)
          history = resume.as(Facet::Assistant::Resume::Result::Restored).session.history
          history.size.should eq(8)
          roles = history.map(&.role.to_s)
          roles.should eq(["user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant"])
          history.first.content.should eq("first")
          history.last.content.should eq("Hello world")
        end
      ensure
        server.close
      end
    end
  end
end
