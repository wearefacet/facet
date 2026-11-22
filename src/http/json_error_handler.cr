# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "pg"
require "./helpers"

module Facet
  module HTTP
    # Kemal handler that owns error rendering for the API surface.
    #
    # The app is API-first: every error is JSON, consumed by the frontend.
    # Routes render their own error bodies (via `Helpers.error_response` /
    # `Helpers.write_result` / `Helpers.write_json_error`) and set the status.
    #
    # Kemal, however, uses exceptions as control flow for HTTP errors:
    #
    # - `Kemal::Exceptions::CustomException` — a route set a status that has a
    #   registered error handler (the JSON `error 404` registered in
    #   `HTTP::Server.routes`, which blocks Kemal's HTML default). The route
    #   has already rendered its body, so this handler must NOT re-render —
    #   otherwise the body is doubled (`{"error":...}{"error":...}`) and the
    #   status is preserved. Swallowing it keeps the route's own response.
    #
    # - `Kemal::Exceptions::RouteNotFound` — no route matched. Nothing was
    #   written, so this handler renders a clean JSON 404.
    #
    # - `Kemal::Exceptions::MethodNotAllowed` — the path routes for other
    #   methods → JSON 405 with the `Allow` header (RFC 9110 §15.5.6).
    #
    # - `Kemal::Exceptions::InvalidQueryRequest` — a QUERY body without a
    #   `Content-Type` header → JSON 400 (RFC 10008).
    #
    # - `PQ::PQError` — an unexpected database failure. Two cases are
    #   expected and actionable:
    #
    #   - the concurrent-write race on the mutation log (SQLSTATE 23505 on
    #     `idx_mutations_doc_id_idx`, detected by
    #     `Helpers.mutation_write_conflict?`) → 409 with a retry hint;
    #   - a `unique: true` field constraint enforced by a managed unique
    #     index (`idx_env_*`, detected by
    #     `Helpers.projection_unique_conflict?`) → 422 with the conflicting
    #     key named in `details`. The Crystal pre-check
    #     (`Document::UniqueConstraint`) answers the common case; this maps
    #     the race window where a competing write committed between the
    #     check and the insert.
    #
    #   Every other database error keeps the generic JSON 500.
    #
    # - A connection-level failure of a backing service (Redis,
    #   PostgreSQL) — `Helpers.dependency_unavailable?` classifies it — → 503
    #   with the dependency named in the body
    #   (`{"error": "Service unavailable", "dependency": "redis"}`). Every
    #   dependency-backed path benefits, so a Redis outage on `/Api/iam/login`
    #   no longer reads as an opaque 500 (F09-01). Only connection-level
    #   exception classes match; a programming error keeps the 500.
    #
    # Anything else is a genuine unexpected exception → JSON 500.
    class JsonErrorHandler < Kemal::Handler
      # Body rendered for the mutation write-conflict 409. The contract is
      # documented in `doc/backend/http-layer.md` → Concurrent write
      # conflict: the losing write never landed, so the caller may re-issue
      # the same request unchanged.
      MUTATION_CONFLICT_MESSAGE = "Concurrent write on this document — retry the request"

      # Body rendered for the dependency-unavailable 503. The `dependency`
      # key names the failing service, so an operator can tell a dead
      # dependency from a bad credential without reading the server log.
      SERVICE_UNAVAILABLE_MESSAGE = "Service unavailable"

      def call(env)
        call_next(env)
        correct_default_content_type(env)
      rescue Kemal::Exceptions::CustomException
        # Route already rendered its body and set the status. Do nothing.
        nil
      rescue Kemal::Exceptions::RouteNotFound
        env.response.status_code = 404
        env.response.content_type = "application/json"
        Helpers.no_store(env)
        env.response.print({error: "Not found"}.to_json)
      rescue ex : Kemal::Exceptions::MethodNotAllowed
        # RFC 9110 §15.5.6: the path routes for other methods. Kemal raises
        # this from the router, but this handler sits between the router and
        # Kemal's own ExceptionHandler — without an explicit rescue the 405
        # would surface as a generic JSON 500. `Allow` is required on a 405,
        # and the body names the same set so API consumers that read only
        # the JSON error learn the fix (B-175: a PUT on a document route
        # sees PATCH among the allowed methods).
        env.response.headers["Allow"] = ex.allowed_methods.join(", ") unless ex.allowed_methods.empty?
        message = ex.allowed_methods.empty? ? "Method not allowed" : "Method not allowed. Allowed: #{ex.allowed_methods.join(", ")}"
        write_error(env, 405, message)
      rescue Kemal::Exceptions::InvalidQueryRequest
        # RFC 10008: a QUERY request whose body carries no media type fails
        # with 400. Same chain position as the 405 above — Kemal's intended
        # status would otherwise arrive as a 500.
        write_error(env, 400, "A QUERY request with a body must declare a Content-Type header")
      rescue ex : PQ::PQError
        if Helpers.mutation_write_conflict?(ex)
          # Rare by construction (row locks serialize update/delete; the
          # create path is the only exposure), so a single WARN line per hit
          # is the operator signal the error-log contract promises.
          Helpers::HTTP_LOG.warn { "#{env.request.method} #{env.request.path} → 409 #{MUTATION_CONFLICT_MESSAGE}" }
          write_error(env, 409, MUTATION_CONFLICT_MESSAGE)
        elsif Helpers.projection_unique_conflict?(ex)
          # A `unique: true` field constraint enforced by a managed unique
          # index rejected the write — the race window the Crystal
          # pre-check cannot close (a competing write committed between
          # the check and the insert). Answers the same 422 shape the
          # pre-check answers, with the conflicting key named in `details`.
          Helpers::HTTP_LOG.warn { "#{env.request.method} #{env.request.path} → 422 unique field constraint" }
          write_unique_conflict(env, ex)
        elsif dependency = Helpers.dependency_unavailable?(ex)
          # The PostgreSQL pool cannot reach its server — a dependency
          # outage, not a request error. `DB::ConnectionRefused` is not a
          # `PQ::PQError`, but this branch keeps the classification in one
          # place; the generic branch below also reaches it.
          write_dependency_unavailable(env, dependency)
        else
          # An unexpected database failure never names its SQL or constraint
          # in the response body — the class/message/backtrace stay in the
          # server log (`log_unexpected`), the caller gets the generic 500.
          handle_unexpected(env, ex)
        end
      rescue ex
        # Several exception types carry no message (crystal-db's pool errors,
        # `Exception.new` without arguments). Rendering the raw `message` then
        # ships `{"error":""}` — no route, no cause, nothing. The body stays
        # generic regardless: an unexpected 500 never carries the exception
        # text (it can name SQL, constraints, or internals); the class name
        # and backtrace go to the server log instead.
        handle_unexpected(env, ex)
      end

      # The catch-all outcome: a connection-level failure of a backing
      # service answers 503 with the dependency named (an ops signal, not an
      # unexpected bug); anything else logs the unexpected exception and
      # answers the generic 500.
      private def handle_unexpected(env, ex : ::Exception) : Nil
        if dependency = Helpers.dependency_unavailable?(ex)
          write_dependency_unavailable(env, dependency)
        else
          log_unexpected(env, ex)
          write_error(env, 500, "Internal server error")
        end
      end

      # One ERROR line per unexpected 500 on `facet.http`: the request, the
      # exception class and message, and the first backtrace frames — the
      # same shape the `error 500` block in `HTTP::Server.routes` logs. The
      # exception object rides on the entry, so log consumers (the spec
      # suite's `SpecLogCapture` included) can root-cause without the
      # response body.
      private def log_unexpected(env, ex : ::Exception) : Nil
        frames = ex.backtrace?.try(&.first(15))
        Helpers::HTTP_LOG.error(exception: ex) do
          line = "#{env.request.method} #{env.request.path} → 500 #{ex.class.name}: #{ex.message || ex.class.name}"
          frames ? "#{line}\n#{frames.join("\n")}" : line
        end
      end

      private def write_error(env, status : Int32, message : String?) : Nil
        env.response.status_code = status
        env.response.content_type = "application/json"
        Helpers.no_store(env)
        env.response.print({error: message}.to_json)
      end

      # Renders the dependency-unavailable 503: the generic error envelope
      # plus the failing dependency's name. Logged at ERROR like every other
      # 5xx so the outage is visible on `facet.http`.
      private def write_dependency_unavailable(env, dependency : String) : Nil
        Helpers::HTTP_LOG.error do
          "#{env.request.method} #{env.request.path} → 503 #{SERVICE_UNAVAILABLE_MESSAGE} (dependency: #{dependency})"
        end
        env.response.status_code = 503
        env.response.content_type = "application/json"
        Helpers.no_store(env)
        env.response.print({error: SERVICE_UNAVAILABLE_MESSAGE, dependency: dependency}.to_json)
      end

      # Renders the 422 for a lost unique-index race: the standard error
      # envelope plus the structured `details` array the document
      # validation errors use, so clients branch on the same shape.
      private def write_unique_conflict(env, ex : PQ::PQError) : Nil
        env.response.status_code = 422
        env.response.content_type = "application/json"
        Helpers.no_store(env)
        error = Helpers.projection_unique_conflict_error(ex)
        env.response.print({error: "Document validation failed", details: [error]}.to_json)
      end

      # Kemal's `InitHandler` stamps `text/html` on every response before
      # dispatch, so a route that prints a JSON body and forgets to set the
      # media type would ship it as HTML. Every route on this API answers
      # JSON; the few that do not (app hosting, artifact downloads, SSE) set
      # their own `Content-Type` before printing, so the stamp here is the
      # untouched default. Correct it to `application/json` on a 2xx JSON
      # body; a 204 keeps no body and keeps no claim.
      private def correct_default_content_type(env) : Nil
        response = env.response
        return if response.headers_sent? || response.closed?
        status = response.status_code
        return unless 200 <= status < 300 && status != 204
        return unless response.headers["Content-Type"]?.try(&.starts_with?("text/html"))
        response.headers["Content-Type"] = "application/json"
      end
    end
  end
end
