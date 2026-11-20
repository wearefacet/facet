# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "kemal"
require "./websocket/manager"

module Facet
  # Graceful-shutdown coordination for the server process.
  #
  # `install` replaces the default termination disposition with a handler
  # that starts the shutdown sequence on SIGTERM, SIGINT, and SIGHUP (the
  # same set `Process.on_terminate` — Kemal's built-in trap — covered):
  #
  # 1. `Kemal.stop` — the listeners close and `Kemal.run` begins waiting for
  #    the in-flight requests to finish.
  # 2. Every tracked WebSocket connection is closed with a close frame. An
  #    open socket holds Kemal's in-flight count up for as long as it lives,
  #    so without this the drain would hang until `Kemal::Config`
  #    `shutdown_timeout` (30 s) — past the container-orchestration grace
  #    period — and the process would be SIGKILL'd before the ordered
  #    teardown in `main.cr`'s `at_exit` block ever runs.
  # 3. `main` falls through, `at_exit` stops the subsystems (consumers, then
  #    schedulers, then the DB pool), and the process exits 0.
  #
  # A signal received when the HTTP server is not running (during boot, or a
  # second signal while the drain is already in flight) escalates: the
  # process exits immediately, running the registered `at_exit` handlers but
  # skipping the drain wait.
  module Shutdown
    Log = ::Log.for("facet.shutdown")

    # Installs the termination-signal traps. Called once from `run_server`
    # before anything else starts, so a termination request during boot also
    # exits cleanly instead of dying on the default disposition.
    def self.install : Nil
      Signal::TERM.trap { |signal| handle(signal) }
      Signal::INT.trap { |signal| handle(signal) }
      Signal::HUP.trap { |signal| handle(signal) }
    end

    # Runs one ordered teardown step, logging instead of raising. An
    # exception inside the `at_exit` block would abort it and skip the
    # remaining subsystems.
    def self.stop_quietly(label : String, & : -> Nil) : Nil
      yield
    rescue e : Exception
      Log.error { "error stopping #{label}: #{e.class}: #{e.message}" }
    end

    # The trap handler body. Signal handlers run on a dedicated event-loop
    # fiber (not the sigaltstack), so logging, `Kemal.stop`, and the socket
    # writes behind the close frames are all safe here.
    private def self.handle(signal : Signal) : Nil
      unless Kemal.config.running
        # During boot (before `Kemal.run`), or a further signal while the
        # drain is already in flight: nothing to wait for. `exit` runs the
        # registered `at_exit` handlers, then terminates.
        Log.info { "#{signal} received with no running HTTP server — exiting" }
        exit
      end

      Log.info { "#{signal} received — draining HTTP server and closing WebSocket connections" }
      Kemal.stop
      Websocket::Manager.instance?.try(&.close_all)
    end
  end
end
