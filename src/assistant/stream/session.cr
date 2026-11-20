# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "sync"
require "sync/exclusive"
require "json"
require "log"

require "agent-cr"
require "../../database"
require "../../util/script_helpers"
require "../conversation"
require "../resume"
require "../../system_settings"
require "../turn"
require "../usage"
require "./cancel_bus"
require "./tool_trace_handler"
require "./terminal_refusal_stop"

module Facet
  module Assistant
    module Stream
      # Orchestrates one streaming turn against `Agent`: builds or resumes
      # the `Agent`, dispatches `#ask`, drains `Response#stream` onto an IO as
      # SSE events, and drives the `Turn` row through its lifecycle
      # (`running` — opened by the route — then `done`/`error`/`cancelled`
      # at the exit path), and tears down the Redis cancel subscription.
      # Every terminal path bills the usage ledger: success and cancel/error
      # turns with reported counts write real numbers, and a cancelled,
      # truncated, or successful turn the provider never reported on writes
      # an estimate (see `write_billed_usage`). The estimate keeps the role
      # token budget honest against providers that report no usage on
      # streamed responses (they omit `stream_options` from the request).
      #
      # The IO is the Kemal `env.response`. The route handler (in
      # `Assistant::Routes`) sets the SSE response headers *before* calling
      # `#run`, and closes the response on return.
      #
      # ## Client disconnect
      #
      # The turn is server-owned work: the SSE sink is only one of its
      # consumers. A dead sink (the browser refreshed, the phone switched
      # networks) must never terminate the turn. Every write therefore
      # runs through a guard that flips `@io_dead` on the first failure —
      # flush failures surface as `HTTP::Server::ClientError`, a later
      # write on the closed output raises `IO::Error`, and a TLS-terminated
      # listener raises `OpenSSL::SSL::Error` (no `IO::Error` subclass —
      # the guard names it explicitly) — and every later write becomes a
      # no-op. The turn then completes normally and the full result lands
      # in the turn row, where a reconnecting client reads it.
      #
      # ## SSE wire format
      #
      #   event: meta        data: {"turn_token":"..."}
      #   event: chunk        data: {"kind":"content","text":"..."}
      #   event: chunk        data: {"kind":"reasoning","text":"..."}
      #   event: chunk        data: {"kind":"tool_call","name":"...","status":"running","detail":"..."}
      #   event: chunk        data: {"kind":"tool_call","name":"...","status":"ok"\|"error","result":"..."}
      #   event: done         data: {"turn_id":"...","finish_reason":"stop"}
      #   event: error        data: {"message":"..."}
      #   event: cancelled    data: {}
      #
      # `tool_call` events are emitted by the `ToolTraceHandler` registered
      # on the agent. `ToolCallName` / `ToolCallArgs` chunks from
      # `Response#stream` are filtered out — they model the drafting phase,
      # not the execution phase. One `running -> ok|error` cycle per
      # tool invocation.
      #
      # A heartbeat comment (`: ping`) is emitted every HEARTBEAT_INTERVAL
      # by a dedicated fiber so proxies (Caddy, carrier NAT) do not cut the
      # connection during quiet stretches of the tool loop. `response.close`
      # is the route handler's responsibility.
      #
      # ## Write concurrency
      #
      # Three fibers write to the same IO: the main fiber (drain loop,
      # terminal events), the agent run-loop fiber (`ToolTraceHandler`),
      # and the heartbeat fiber. `@io_lock` serialises each frame so a
      # heartbeat comment cannot interleave mid-frame. Once `@io_dead` is
      # set the lock is skipped entirely.
      class Session
        Log = ::Log.for("facet.assistant.stream.session")

        # Outcome of a streaming turn. Exactly one terminal condition holds;
        # the route handler has already emitted the matching SSE event inside
        # `#run`, so this is mainly for tests/logging.
        record Result,
          turn_id : String?,
          finish_reason : String?,
          error : String?,
          cancelled : Bool

        # Empty JSON object literal, used for the `cancelled` SSE event payload.
        EMPTY_JSON = "{}"

        # Error string for a turn whose provider stream closed before the
        # model sent a finish reason. The `truncated: ` prefix keeps the
        # audit trail greppable; the rest stays user-legible on the SSE
        # error event.
        private TRUNCATED_MESSAGE = "truncated: provider stream ended before the response completed"

        # Fiber-safe holder for the in-flight `Response` plus the cancel
        # request that may race the request start. The subscriber fiber
        # cancels the response once the main fiber has published it here;
        # before that, it sets `requested` — and the main fiber applies the
        # cancel right after `ask` returns. Both mutations happen under the
        # one lock, so a cancel racing the request start is observed on every
        # interleaving. `Sync::Exclusive` is the established thread-safe
        # wrapper used elsewhere in the codebase (e.g. agent-cr's `@history`).
        private class CancelState
          property response : Agent::Response? = nil
          property? requested : Bool = false
        end

        private getter cancel_state : Sync::Exclusive(CancelState) = Sync::Exclusive(CancelState).new(CancelState.new)

        # True once a cancel for this turn reached the session: either the
        # pre-apply request (the subscriber ran while no response was
        # published yet — a microseconds-wide window before `ask` returns)
        # or the published response carries agent-cr's cancel flag. The
        # response branch is the steady state during a park — `ask` returns
        # the `Response` object immediately and the stream runs on the
        # agent's processing fiber, so a cancel published mid-park lands as
        # `response.cancel`. Observability for the cancel race: a caller
        # can wait for this instead of sleeping past the subscribe race.
        def cancel_requested? : Bool
          cancel_state.lock do |state|
            state.requested? || state.response.try(&.cancelled?) || false
          end
        end

        # Cadence of the SSE heartbeat comment. Long tool calls can leave the
        # stream quiet for a while; proxies and mobile carrier NAT kill idle
        # connections, and the heartbeat keeps those alive.
        private HEARTBEAT_INTERVAL = 15.seconds

        # Chars-per-token ratio of the anti-siphon estimate — the only
        # heuristic in the feature. A turn whose provider never reported
        # usage still delivered streamed output and consumed the prompt,
        # so the ledger bills an approximation instead of letting the turn
        # ride for free — cancelled, truncated, and successful turns
        # without a report alike. ~4 chars/token is the usual prose
        # approximation; the input side errs slightly high because the
        # prompt is serialized JSON (syntax overhead counts as chars).
        private CHARS_PER_TOKEN = 4

        # Minimum gap between two checkpoint writes of the running turn
        # row. A fast tool loop completes iterations in well under a
        # second; the gap bounds the rewrite rate to one row update per
        # interval while the committed exchange still reaches a reloading
        # client within ~2s of each iteration boundary.
        private CHECKPOINT_INTERVAL = 2.seconds

        # Every SSE write goes through `@io_lock` so the three writer fibers
        # (main drain, agent run-loop via `ToolTraceHandler`, heartbeat) never
        # interleave partial frames.
        @io_lock : Sync::Mutex = Sync::Mutex.new

        # Set on the first failed write or flush. The client connection is
        # gone; the turn keeps running and every write becomes a no-op.
        # See the "Client disconnect" note on the class.
        @io_dead : Sync::Exclusive(Bool) = Sync::Exclusive(Bool).new(false)

        # Coordination for the heartbeat fiber: `@heartbeat_stop` flips to
        # true when the turn's drain ended; the fiber polls it every second
        # between ticks so it exits within ~1s and never joins against the
        # main fiber.
        @heartbeat_stop : Sync::Exclusive(Bool) = Sync::Exclusive(Bool).new(false)

        # The turn row opened by the route, persisted to its terminal state
        # at every exit path. `nil` when `Turn.open` failed or reported a
        # conflict — `fail_terminal` inserts a standalone error row instead
        # so the failed attempt stays observable.
        @turn_id : String? = nil

        # Optional hook invoked with the freshly-constructed `Agent` so the
        # caller can register tools (and their callback blocks) on it before
        # `ask`. Application code owns tool definitions; the Session does not
        # impose a tool-callback type. See `Agent#register_tool`.
        @tool_registrar : Proc(Agent, Nil)

        # Names of UI tools whose raw arguments are forwarded to the frontend
        # on the `tool_call` chunk payload. See `ToolTraceHandler`.
        @argument_tools : Set(String)

        # Held as ivars so the `ensure` block of `#run` can clean them up even
        # when an exception fired before they were fully wired.
        @agent : Agent? = nil
        @cancel_handle : CancelBus::SubscriptionHandle? = nil

        # Account attribution for the usage ledger. `nil` (system bypass,
        # anonymous caller) means the turn writes no `assistant_usage` row.
        @account_id : String? = nil

        # Model of this turn, captured in `build_agent` from the effective
        # settings and stamped on the usage row. The per-turn model history
        # survives in `assistant_usage.model` independently of any
        # conversation column.
        @model : String? = nil

        # Checkpoint bookkeeping for the running turn row: the instant of
        # the last write (pre-armed so the first growth fires immediately)
        # and the committed history size it persisted. Only the drain
        # fiber touches both.
        @checkpoint_at : Time::Instant = Time.instant - 2.seconds
        @checkpoint_size : Int32 = 0

        def initialize(
          @db : DB::Connection,
          @conversation_id : String,
          @content : String,
          @attachments : Array(String)? = nil,
          @account_id : String? = nil,
          @tool_registrar : Proc(Agent, Nil) = ->(_agent : Agent) { },
          @argument_tools : Set(String) = Set(String).new,
          @turn_token : String? = nil,
        )
        end

        # Builds a tool-trace handler bound to the given `io`. Wraps the
        # `tool_call` SSE write so the handler doesn't need an `IO` reference
        # of its own — the IO is the same one `drain_stream` writes to and is
        # only accessed from the main fiber where the handler chain runs.
        private def make_tool_trace_handler(io)
          callback = ->(e : {name: String, status: String, detail: String?, result: String?, arguments: String?}) do
            payload = {kind: "tool_call", name: e[:name], status: e[:status]}
            payload = payload.merge({detail: e[:detail]}) unless e[:detail].nil?
            payload = payload.merge({result: e[:result]}) unless e[:result].nil?
            payload = payload.merge({arguments: e[:arguments]}) unless e[:arguments].nil?
            write_event(io, "chunk", payload.to_json)
            flush(io)
          end
          ToolTraceHandler.new(callback, @argument_tools)
        end

        # Runs a streaming turn, writing SSE events to `io`.
        #
        # The turn row is already `running` (opened by the route, `turn_id`
        # passed in). The cancel token comes from the route too — it was
        # generated before `Turn.open` so the persisted row carries it; a
        # nil token (tests, direct use) falls back to a fresh ULID. Spawns
        # the cancel subscriber before `agent.ask` so a cancel that races
        # the request start is still observed. Completes the row on every
        # exit path with the terminal status.
        def run(io : IO, redis_url : String, cancel_ttl : Int32, turn_id : String) : Result
          turn_token = @turn_token || Util::ScriptHelpers.ulid
          @turn_id = turn_id
          built = build_agent(make_tool_trace_handler(io), TerminalRefusalStop.new)
          @agent = built
          # The history size before `ask` appends the request messages. Only
          # the drop-path classifier still reads it (`dropped?`); the
          # persisted slices anchor on the turn's own messages instead — a
          # finite `assistant.max_history` lets agent-cr's mid-turn trim
          # drop a prefix and shift every index (see
          # `response_messages_after_request`).
          pre_ask_size = built.history.size

          # meta event — sent first so the client knows the cancel token
          # before any chunk arrives.
          start_heartbeat(io)

          # Arm the cancel subscriber before the meta event: the client can
          # cancel as soon as it sees the token, and the bus's SET+GET probe
          # closes the pre-subscribe window.
          @cancel_handle = CancelBus.subscribe(turn_token, redis_url) do
            # Called from the subscriber fiber. If `ask` has returned, cancel
            # the response directly; otherwise remember the request — the main
            # fiber applies it the moment `ask` returns.
            cancel_state.lock do |state|
              if response = state.response
                response.cancel
              else
                state.requested = true
              end
            end
          end

          write_event(io, "meta", {turn_token: turn_token}.to_json)
          flush(io)

          resp = built.ask(@content, @attachments, nil)
          cancelled_early = cancel_state.lock do |state|
            state.response = resp
            state.requested?
          end
          resp.cancel if cancelled_early

          result = drain_stream(io, built, resp, pre_ask_size)

          resp.join
          stop_heartbeat
          @cancel_handle.try(&.close)

          result
        rescue IO::Error | OpenSSL::SSL::Error
          # A raw write outside the guarded paths — treat like a dead sink.
          # On a TLS-terminated listener the failing write raises
          # `OpenSSL::SSL::Error`, which is no `IO::Error` subclass, so the
          # guard names it too. A dead sink stays a transport fact: no ERROR
          # log, no raw SSL message in the turn row.
          fail_terminal(io, "client_disconnected")
        rescue ex
          Log.error { "Assistant::Stream::Session unexpected error: #{ex.message}" }
          fail_terminal(io, ex.message || ex.class.name)
        ensure
          stop_heartbeat
          @cancel_handle.try(&.close)
          @agent.try(&.close)
        end

        # Cancels the in-flight request, persists the terminal turn row,
        # writes the terminal `error` SSE event, and returns the failed
        # `Result`. Shared exit path of both rescue arms of `#run`. The
        # writes are guarded — a dead sink cannot raise out of here.
        private def fail_terminal(io : IO, message : String) : Result
          cancel_current_response
          turn_id = persist_terminal(error: message)
          write_inflight_usage(turn_id)
          write_event(io, "error", {message: message}.to_json)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: nil, error: message, cancelled: false)
        end

        # ── Agent construction ───────────────────────────────────────────

        # Builds the `Agent` for this turn. `Resume.call` returns the
        # restored session for both empty and non-empty conversations — an
        # empty conversation yields an empty history array, which
        # `Agent#load` accepts. The `tool_trace_handler` is registered on the
        # agent before `load` so it sees every chunk and tool call of the
        # turn; `refusal_stop` rides the same chain and cancels the turn
        # when the model repeats a final refusal (see `RefusalGuard`). Both
        # handlers are constructed per call, so their state never outlives
        # the turn.
        #
        # The connection resolves at every turn start from the effective
        # runtime settings: endpoint, key, model, and the sampling knobs.
        # There is no per-conversation pin — an existing conversation moves
        # to a changed model at its next turn. The prompt stays as stored on
        # the conversation row (the main assistant captured the setting at
        # create; the workspace and builder assistants build their own).
        # Endpoint, key, and model resolve together because they are
        # provider-coupled.
        private def build_agent(tool_trace_handler : ToolTraceHandler, refusal_stop : TerminalRefusalStop) : Agent
          result = Resume.call(@db, @conversation_id)

          case result
          in Resume::Result::Restored
            session = result.session
            config = SystemSettings::AssistantView.build(
              @db,
              session.conversation.system_prompt,
            )
            @model = config.model
            agent = Agent.new(config.to_agent_config)
            @tool_registrar.call(agent)
            agent.use(tool_trace_handler)
            agent.use(refusal_stop)
            agent.load(session.session_json)
            agent
          in Facet::ServiceError
            raise AgentError.new("Failed to resume conversation: #{result.message}")
          end
        end

        # ── Stream drain loop ────────────────────────────────────────────

        # Drains `Response#stream` onto `io` as `chunk` events, then dispatches
        # to the terminal handler matching `resp`'s final state.
        #
        # The chunk writes run through the guarded `write_event`/`flush` — a
        # dead sink never raises here. The loop keeps consuming until the
        # provider closes the stream, so the turn completes server-side and
        # lands in the turn row for the reconnecting client. Streamed
        # content and reasoning characters accumulate alongside the drain —
        # the output side of the anti-siphon estimate on cancelled and
        # truncated turns, and the material for the assistant partial
        # `handle_truncated` rebuilds when agent-cr rolled the history back
        # (B-373). Between chunks, `maybe_checkpoint` persists the turn's
        # committed exchange into the running row.
        #
        # A stream that ends without a finish reason is a truncation, not a
        # success: the provider closed the connection before the model
        # finished. It dispatches to `handle_truncated`, never to
        # `handle_success`. A hard mid-stream drop (socket close — the
        # parser raises instead of seeing a clean EOF) arrives as an
        # `Agent::ConnectionError`; when content already reached the client
        # it is the same failure and routes to `handle_truncated` too (see
        # the dispatch below).
        private def drain_stream(
          io : IO,
          agent : Agent,
          resp : Agent::Response,
          pre_ask_size : Int32,
        ) : Result
          streamed_chars = 0
          streamed_content = String::Builder.new
          streamed_reasoning = String::Builder.new

          resp.stream do |chunk|
            maybe_checkpoint(agent, pre_ask_size)
            next unless chunk.content? || chunk.reasoning?
            kind = chunk.content? ? "content" : "reasoning"
            streamed_chars += chunk.text.size
            if chunk.content?
              streamed_content << chunk.text
            else
              streamed_reasoning << chunk.text
            end
            write_event(io, "chunk", {kind: kind, text: chunk.text}.to_json)
            flush(io)
          end

          resp.join

          return handle_cancelled(io, agent, resp, streamed_chars) if resp.cancelled?
          return handle_capped(io, agent, resp, streamed_chars) if capped?(resp)
          return handle_truncated_drop(io, agent, resp, pre_ask_size, streamed_chars,
            streamed_content.to_s, streamed_reasoning.to_s) if dropped?(resp, streamed_chars, agent, pre_ask_size)
          return handle_error(io, resp) if resp.error?
          return handle_truncated(io, agent, resp, pre_ask_size, streamed_chars,
            streamed_content.to_s, streamed_reasoning.to_s) if resp.finish_reason.nil?

          handle_success(io, agent, resp, streamed_chars)
        end

        # True when the response finished on the tool-loop cap. The cap
        # fires between iterations: every provider call returned, every
        # tool result is committed, and the exchange ends on a complete
        # assistant + tool-results pair. That is a resumable partial, not
        # a failed-before-output error.
        private def capped?(resp : Agent::Response) : Bool
          resp.error.is_a?(Agent::ToolLoopError)
        end

        # True when a hard provider drop must land in the truncated class:
        # either streamed output already reached the client, or the drop
        # committed tool-call history with no text chunk. A drop is
        # agent-cr's `ConnectionError` carrying the raw IO message ("End
        # of file reached"). The size test reads the pre-ask history size:
        # the drop path never trims (the trim only fires on the done/cancel
        # exits), so the pre-ask size stays a valid index into the history
        # the rollback produces.
        private def dropped?(resp : Agent::Response, streamed_chars : Int32, agent : Agent, pre_ask_size : Int32) : Bool
          return false unless resp.error.is_a?(Agent::ConnectionError)
          streamed_chars > 0 || agent.history.size > pre_ask_size
        end

        # The truncated-class exit of a hard provider drop. The drop makes
        # agent-cr roll the history back when output was streamed, so the
        # rebuild carries the drained text when the slice is empty — see
        # `handle_truncated`.
        private def handle_truncated_drop(
          io : IO,
          agent : Agent,
          resp : Agent::Response,
          pre_ask_size : Int32,
          streamed_chars : Int32,
          streamed_content : String,
          streamed_reasoning : String,
        ) : Result
          handle_truncated(io, agent, resp, pre_ask_size, streamed_chars,
            streamed_content, streamed_reasoning)
        end

        # ── Terminal handlers ─────────────────────────────────────

        private def handle_success(io, agent, resp, streamed_chars) : Result
          turn_id = persist_turn(
            response_messages: response_messages_after_request(agent),
            usage: resp.metadata,
            status: "done",
            finish_reason: resp.finish_reason,
            error: nil,
          )
          # Billed like a cancel: the provider's report wins when it carries
          # counts; when it reports nothing — the common streaming case, a
          # provider that never receives `stream_options` — the anti-siphon
          # estimate keeps the turn on the ledger and the token budget
          # effective. See `write_billed_usage`.
          write_billed_usage(turn_id, agent, resp.metadata, streamed_chars)
          write_event(io, "done",
            {turn_id: turn_id, finish_reason: resp.finish_reason || "stop"}.to_json)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: resp.finish_reason, error: nil, cancelled: false)
        end

        # Terminal error outside the truncation class: API failures, idle
        # timeouts, the tool-loop cap, and connection drops that delivered
        # nothing and committed no history (drops that delivered output or
        # committed tool results route to `handle_truncated` — see the
        # dispatch). Reported-only counting: the anti-siphon estimate covers
        # the delivering paths; here the error classes stay distinct in the
        # audit trail and only reported counts bill.
        private def handle_error(io, resp) : Result
          msg = resp.error.try(&.message) || "unknown error"
          turn_id = persist_terminal(error: msg)
          write_reported_usage(turn_id, resp.metadata)
          write_event(io, "error", {message: msg}.to_json)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: nil, error: msg, cancelled: false)
        end

        # Cancel is a user-initiated abort, not a failure. agent-cr keeps the
        # partial context in `agent.history` (the user message, the streamed
        # assistant reply, and any tool results committed before the cancel) so
        # the next `#ask` can resume where this turn left off. Persist that
        # partial history as `response_messages` so `Resume` restores it on the
        # next turn; `request_messages` stays the single user message. The turn
        # still bills the ledger — see `write_billed_usage`.
        private def handle_cancelled(io, agent, resp, streamed_chars) : Result
          turn_id = persist_turn(
            response_messages: response_messages_after_request(agent),
            usage: Agent::Usage.new,
            status: "cancelled",
            finish_reason: nil,
            error: "cancelled",
          )
          write_billed_usage(turn_id, agent, resp.metadata, streamed_chars)
          write_event(io, "cancelled", EMPTY_JSON)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: nil, error: "cancelled", cancelled: true)
        end

        # The tool-loop cap stopped the turn: the model consumed its
        # `max_tool_iterations` provider calls without producing a final
        # answer. agent-cr does not roll the history back on this path —
        # every iteration completed, so `agent.history` ends on a complete
        # assistant + tool-results pair and is a valid provider prefix.
        # Persist it under the `capped` status so `Resume` restores the
        # work: the next user message continues the exchange instead of
        # starting over. The row keeps the raw cap message for the audit
        # trail, and the ledger bills through the anti-siphon path — the
        # turn delivered real output.
        private def handle_capped(io, agent, resp, streamed_chars) : Result
          msg = resp.error.try(&.message) || "tool call iteration limit exceeded"
          turn_id = persist_turn(
            response_messages: response_messages_after_request(agent),
            usage: Agent::Usage.new,
            status: "capped",
            finish_reason: nil,
            error: msg,
          )
          write_billed_usage(turn_id, agent, resp.metadata, streamed_chars)
          write_event(io, "error", {message: msg}.to_json)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: nil, error: msg, cancelled: false)
        end

        # Drops the turn's own leading user messages from a history slice.
        # agent-cr appends the request's user messages to the history at
        # `ask` start, and `Resume` already concatenates `request_messages`,
        # which holds the same messages. Keeping both would replay the user
        # message twice. The slice helpers below anchor on the turn's user
        # message, so this is the safety net that keeps the contract honest
        # for any slice that still starts inside the request messages.
        private def drop_request_messages(messages : Array(Agent::Message)) : Array(Agent::Message)
          messages.skip_while(&.role.user?)
        end

        # The turn's own assistant/tool messages, sliced from the agent's
        # *current* history. Serves the exit paths where agent-cr keeps the
        # request messages in history: done, cancelled, capped, and the
        # clean-close truncation.
        #
        # The anchor is the turn's own user message — the last user-role
        # message in the array. Nothing else appends user messages during
        # the turn, and agent-cr's `trim_history!` only ever removes a
        # prefix: when a finite `assistant.max_history` made the trim drop
        # that message, it dropped every older message with it, so the
        # surviving array is all this turn's. A numeric pre-ask index cannot
        # serve here — the trim fires once per turn right before the
        # response finishes and shifts every index, which is how the slice
        # lost the turn's leading messages or raised `IndexError`
        # (F08-A residual).
        private def response_messages_after_request(agent : Agent) : Array(Agent::Message)
          history = agent.history
          if user_index = history.rindex(&.role.user?)
            drop_request_messages(history[(user_index + 1)..])
          else
            drop_request_messages(history)
          end
        end

        # The same slice for the paths where agent-cr has already rolled the
        # request messages back (the hard provider drop, and the mid-turn
        # checkpoint that can race one). There the rollback removes the
        # turn's user message from the tail when the turn appended nothing,
        # so an older turn's user message becomes the last one in the array
        # — anchoring on it would persist that older turn's reply as this
        # turn's response. The pre-ask history size stays valid here: the
        # drop path never trims. The clamp keeps the slice inside the array
        # when the history shrank below it, and an empty slice makes the
        # caller rebuild from the streamed text (B-373) or skip the
        # checkpoint.
        private def turn_messages_from_boundary(agent : Agent, pre_ask_size : Int32) : Array(Agent::Message)
          history = agent.history
          start = pre_ask_size < history.size ? pre_ask_size : history.size
          drop_request_messages(history[start..])
        end

        # Persists the turn's committed exchange into the running row on a
        # cadence, so a client that reloads mid-turn (or another device)
        # renders the tool calls and text that already landed instead of a
        # bare `running` row. Runs on the drain fiber between chunks — the
        # terminal persists follow on the same fiber, so a checkpoint can
        # never race a `Turn.complete`. The slice drops the turn's own user
        # messages (`request_messages` carries them — see
        # `drop_request_messages`). Skips when nothing new committed since
        # the last write, or when the slice still ends on a dangling
        # assistant tool_calls message (its results are not appended yet —
        # a partial tool_calls array without results is not a valid
        # provider prefix). Checkpoints are best-effort: a failed write
        # logs and the turn carries on; the terminal persist is the source
        # of truth.
        private def maybe_checkpoint(agent : Agent, pre_ask_size : Int32) : Nil
          return unless turn_id = @turn_id

          snapshot = turn_messages_from_boundary(agent, pre_ask_size)
          return if snapshot.size <= @checkpoint_size
          return if (Time.instant - @checkpoint_at) < CHECKPOINT_INTERVAL

          last = snapshot.last
          return if last.role.assistant? && last.has_tool_calls?

          @checkpoint_at = Time.instant
          @checkpoint_size = snapshot.size

          json = JSON.build do |builder|
            builder.array { snapshot.each(&.to_json(builder)) }
          end
          Turn.checkpoint(@db, turn_id, json)
        end

        # Truncation: the provider closed the stream before any chunk
        # carried a finish reason. The client already saw partial output, so
        # this is a failure that delivered something — the mirror of cancel,
        # not of `handle_error`. Persist the partial history as
        # `response_messages` so `Resume` restores it on the next turn (same
        # as cancel), bill the ledger through the anti-siphon path, and emit
        # the `error` SSE event so the client shows the failure and
        # re-enables the composer.
        #
        # B-373: agent-cr's request loop rolls the history back when a
        # provider stream fails — it pops the request messages from the tail
        # and appends nothing — so after a hard mid-stream drop that rolled
        # back a turn with no committed exchange, the slice is empty even
        # though output already streamed to the client. Rebuild the
        # assistant partial from the drained chunks in that shape. A drop
        # that hit after earlier iterations committed keeps the partial in
        # history (minus the one message the rollback pops from the tail),
        # and a rebuild never duplicates messages: it only fires on the
        # empty slice. The rebuild carries streamed text and reasoning only — no
        # tool-call entries, because a partial `tool_calls` array without
        # following tool results is not a valid provider request and would
        # break the very resume this path exists for.
        private def handle_truncated(
          io : IO,
          agent : Agent,
          resp : Agent::Response,
          pre_ask_size : Int32,
          streamed_chars : Int32,
          streamed_content : String,
          streamed_reasoning : String,
        ) : Result
          # A hard provider drop (`ConnectionError`) is the path agent-cr
          # rolls the history back on — anchor on the pre-ask size. A clean
          # close with no finish reason took the done-style exit inside
          # agent-cr (partial message appended, trim fired) — anchor on the
          # turn's own messages, which survives the trim.
          response_messages = if resp.error.is_a?(Agent::ConnectionError)
                                turn_messages_from_boundary(agent, pre_ask_size)
                              else
                                response_messages_after_request(agent)
                              end
          if response_messages.empty? && (!streamed_content.empty? || !streamed_reasoning.empty?)
            response_messages = [Agent::Message.assistant(
              content: streamed_content.empty? ? nil : streamed_content,
              reasoning: streamed_reasoning.empty? ? nil : streamed_reasoning,
            )]
          end
          turn_id = persist_turn(
            response_messages: response_messages,
            usage: Agent::Usage.new,
            status: "error",
            finish_reason: nil,
            error: TRUNCATED_MESSAGE,
          )
          write_billed_usage(turn_id, agent, resp.metadata, streamed_chars)
          write_event(io, "error", {message: TRUNCATED_MESSAGE}.to_json)
          flush(io)
          Result.new(turn_id: turn_id, finish_reason: nil, error: TRUNCATED_MESSAGE, cancelled: false)
        end

        # ── Persistence ───────────────────────────────────────────────

        # Completes the turn row opened by the route with the turn's final
        # messages, status, and usage. A completion failure logs and keeps
        # the running row — `Cron::AssistantTurnSweep` turns it into an
        # `interrupted` error row later, which stays honest about the
        # unknown outcome.
        private def persist_turn(
          response_messages : Array(Agent::Message),
          usage : Agent::Usage,
          status : String,
          finish_reason : String?,
          error : String?,
        ) : String?
          turn_id = @turn_id
          return nil unless turn_id

          response_json = JSON.build do |json|
            json.array { response_messages.each(&.to_json(json)) }
          end

          usage_json = usage.to_json

          Facet::Database.with_transaction(@db) do |tx|
            complete = Turn.complete(
              tx,
              turn_id: turn_id,
              response_messages_json: response_json,
              usage_json: usage_json,
              status: status,
              finish_reason: finish_reason,
              error: error,
            )
            Log.error { "Failed to persist turn #{turn_id}: row already gone" } unless complete
            complete
          end

          turn_id
        end

        # Terminal-only persistence path for genuine failures (provider
        # error, unexpected exception, or a raw write error outside the
        # guarded paths). Updates the running row when it exists; inserts a
        # standalone error row through `Turn.create_terminal` otherwise so
        # the failed attempt is still observable.
        private def persist_terminal(error : String) : String?
          turn_id = @turn_id

          if turn_id
            Turn.complete(
              @db,
              turn_id: turn_id,
              response_messages_json: "[]",
              usage_json: empty_usage_json,
              status: "error",
              error: error,
            )
            turn_id
          else
            result = Facet::Database.with_transaction(@db) do |tx|
              Turn.create_terminal(
                tx,
                conversation_id: @conversation_id,
                request_messages_json: request_messages_json,
                usage_json: empty_usage_json,
                error: error,
              )
            end
            case result
            when Turn::Result::Created then result.record.id
            when Facet::ServiceError
              Log.error { "Failed to persist terminal turn: #{result.message}" }
              nil
            end
          end
        end

        # Builds the `request_messages` JSON for a user message — always the
        # single user message passed to `Agent#ask(content)`. Used BOTH by
        # the route (`Turn.open` before the stream starts) and by the
        # session's terminal-fallback insert, so both write the same shape.
        def self.request_messages_json(content : String) : String
          JSON.build do |json|
            json.array do
              json.object do
                json.field "role", "user"
                json.field "content", content
              end
            end
          end
        end

        private def request_messages_json : String
          self.class.request_messages_json(@content)
        end

        private def empty_usage_json : String
          JSON.build do |json|
            json.object do
              json.field "prompt_tokens", 0
              json.field "completion_tokens", 0
              json.field "total_tokens", 0
            end
          end
        end

        # Writes one `assistant_usage` row from the usage the response
        # reported. Zero-count turns insert nothing. Runs for the
        # reported-only paths — terminal errors and the in-flight rescue
        # (both delivered nothing to siphon, so they never estimate). The
        # delivering paths (success, cancel, truncation) go through
        # `write_billed_usage`, which estimates when no report arrives. A
        # ledger failure logs and keeps the turn: the turn row stays the
        # source of truth, and `agent_turns.usage` can re-derive the row
        # later.
        private def write_reported_usage(turn_id : String?, usage : Agent::Usage?) : Nil
          return unless turn_id

          input_tokens = (usage.try(&.prompt_tokens) || 0).to_i64
          output_tokens = (usage.try(&.completion_tokens) || 0).to_i64
          total_tokens = (usage.try(&.total_tokens) || 0).to_i64
          return unless input_tokens > 0 || output_tokens > 0 || total_tokens > 0

          insert_usage_row(turn_id, input_tokens, output_tokens, estimated: false)
        end

        # Anti-siphon: a turn must never ride for free. When the response
        # carries reported counts (a provider that reports usage on the
        # stream), those real numbers bill unestimated. When it reports
        # nothing — the OpenAI-style final-chunk report never survives an
        # abort, and a provider without `stream_options` never sends one at
        # all — the turn bills an estimate: the streamed content +
        # reasoning characters as output, the serialized prompt (full
        # history, user message included) as input. A report of zeros is
        # treated the same as no report: a real report always carries
        # positive counts. The row is marked `estimated` on the ledger; the
        # turn row keeps the reported zeros.
        #
        # Shared by every delivering exit path: cancelled, truncated, and
        # successful turns alike. Terminal errors that delivered nothing go
        # through `write_reported_usage` instead — there is no output to
        # siphon, and estimating would overcharge turns that failed before
        # the provider processed the prompt.
        private def write_billed_usage(
          turn_id : String?,
          agent : Agent,
          reported : Agent::Usage,
          streamed_chars : Int32,
        ) : Nil
          return unless turn_id

          input_tokens = (reported.prompt_tokens || 0).to_i64
          output_tokens = (reported.completion_tokens || 0).to_i64
          total_tokens = (reported.total_tokens || 0).to_i64
          if input_tokens > 0 || output_tokens > 0 || total_tokens > 0
            insert_usage_row(turn_id, input_tokens, output_tokens, estimated: false)
            return
          end

          prompt_chars = agent.history.sum(&.to_json.size)
          est_input = chars_to_tokens(prompt_chars)
          est_output = chars_to_tokens(streamed_chars)
          return unless est_input > 0 || est_output > 0

          insert_usage_row(turn_id, est_input, est_output, estimated: true)
        end

        # Writes the reported usage of the in-flight response, when one is
        # published and already finished (the rescue paths race the stream's
        # own terminal handlers). A response that never finished has no
        # reported usage — the ledger skips it; terminal failures never
        # estimate (nothing was delivered to siphon).
        private def write_inflight_usage(turn_id : String?) : Nil
          return unless turn_id

          resp = cancel_state.lock(&.response)
          return unless resp && resp.finished?

          write_reported_usage(turn_id, resp.metadata)
        end

        private def chars_to_tokens(chars : Int) : Int64
          (chars.to_f / CHARS_PER_TOKEN).ceil.to_i64
        end

        # One ledger insert, attributed to the session's account. A `nil`
        # account id (system bypass, anonymous caller) writes nothing.
        private def insert_usage_row(
          turn_id : String,
          input_tokens : Int64,
          output_tokens : Int64,
          estimated : Bool,
        ) : Nil
          account_id = @account_id
          return if account_id.nil?

          Usage.insert(
            @db,
            account_id,
            @conversation_id,
            turn_id,
            @model,
            input_tokens,
            output_tokens,
            estimated: estimated,
          )
        rescue ex : DB::Error
          Log.error { "Failed to write assistant usage row: #{ex.message}" }
        end

        # Flips the cancel flag on whatever response is currently published.
        # Used by the rescue paths (client disconnect / unexpected error).
        # Fiber-safe — `Response#cancel` is mutex-protected inside agent-cr.
        private def cancel_current_response : Nil
          cancel_state.lock { |state| state.response.try(&.cancel) }
        end

        # Spawns the heartbeat fiber. One-second sleep steps so the fiber
        # observes `@heartbeat_stop` within ~1s and exits on its own — the
        # main fiber never joins against a full heartbeat interval. The io
        # reference travels through a closure owned by this fiber only;
        # the guarded write path makes concurrent use safe.
        private def start_heartbeat(io : IO) : Nil
          @heartbeat_stop.replace { false }
          spawn do
            elapsed = 0
            loop do
              if @heartbeat_stop.lock { |s| s }
                break
              end
              sleep 1.second
              elapsed += 1
              next unless elapsed >= HEARTBEAT_INTERVAL.total_seconds
              elapsed = 0
              write_heartbeat(io)
            end
          end
        end

        # Signals the heartbeat fiber to exit. Does not block on it.
        private def stop_heartbeat : Nil
          @heartbeat_stop.replace { true }
        end

        # ── SSE IO ───────────────────────────────────────────────────────

        # Writes one SSE frame. Runs under `@io_lock` so concurrent writer
        # fibers cannot interleave frames; flips `@io_dead` on failure and
        # turns into a no-op for the rest of the turn. A dead sink is a
        # transport fact, not a turn failure — see "Client disconnect" on
        # the class.
        private def write_event(io : IO, event : String, data : String) : Nil
          guarded_write(io) do
            io << "event: " << event << '\n'
            io << "data: " << data << '\n'
            io << '\n'
          end
        end

        private def flush(io : IO) : Nil
          guarded_write(io) { io.flush }
        end

        # Emits the heartbeat comment. An SSE comment line is ignored by
        # every conforming event-source parser; the bytes keep the
        # connection from idling out.
        private def write_heartbeat(io : IO) : Nil
          guarded_write(io) do
            io << ": ping" << '\n' << '\n'
          end
        end

        private def guarded_write(io : IO, &) : Nil
          if @io_dead.lock { |d| d }
            return
          end
          @io_lock.synchronize do
            yield
          end
        rescue IO::Error | ::HTTP::Server::ClientError | OpenSSL::SSL::Error
          @io_dead.replace { true }
          # Logged once per turn: the sink died, the turn keeps running.
          # A TLS-terminated listener raises `OpenSSL::SSL::Error` from
          # `SSL_write` on a mid-stream disconnect — no `IO::Error`
          # subclass, so the guard names it explicitly.
          Log.debug { "Assistant SSE sink gone; writes disabled for the rest of the turn" }
        end

        # Raised when the conversation cannot be resumed (404 or DB error).
        class AgentError < Exception
        end
      end
    end
  end
end
