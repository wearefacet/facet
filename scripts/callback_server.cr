#!/usr/bin/env crystal
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Minimal HTTP callback server for ./scripts/test-mcp-flow.sh.
#
# Replaces the bare `nc -l` listener: that variant never sends an HTTP
# response, so the browser tab hangs on "keep loading" after the OAuth
# redirect lands. This server stays up until the OAuth redirect (a request
# carrying `code`) arrives, prints that request line (so the test script can
# grep code/state out of it), returns a 200 HTML page so the browser tab
# closes, then exits. Non-redirect requests (favicon.ico, preconnect probes)
# are answered and ignored — the old single-request design ate those and
# exited before the real redirect landed.
#
# Run:  ./scripts/callback_server.cr [port]
# Default port matches test-mcp-flow.sh's CB_PORT (9999).

require "http/server"

port = (ARGV[0]? || "9999").to_i

captured = Channel(Nil).new

server = HTTP::Server.new do |context|
  req = context.request
  code = req.query_params["code"]?
  state = req.query_params["state"]?

  context.response.content_type = "text/html; charset=utf-8"

  if code
    # The OAuth redirect. Print the raw request line so the test script's
    # grep can parse code/state, then close the loop with a real response.
    puts "#{req.method} #{req.resource}"
    STDOUT.flush

    body = [
      "<!doctype html>",
      "<meta charset='utf-8'>",
      "<title>Authorization complete</title>",
      "<body style='font-family:system-ui;padding:40px'>",
      "<h2>Authorization code captured</h2>",
      "<p>The test script will continue. You can close this tab.</p>",
      "<pre>code=#{code}\nstate=#{state}</pre>",
      "</body>",
    ].join('\n')
    context.response.status = HTTP::Status::OK
    context.response.print(body)

    captured.send(nil)
  else
    # Browser bookkeeping (favicon.ico, preconnect probes, etc). Answer
    # so the tab does not sit pending, but keep listening for the redirect.
    context.response.status = HTTP::Status::NOT_FOUND
    context.response.print("")
  end
end

address = server.bind_tcp("127.0.0.1", port)
STDERR.puts "callback listener on http://#{address}"

# Shut down once the OAuth redirect (the request carrying `code`) arrives.
spawn do
  captured.receive
  server.close
end

server.listen
