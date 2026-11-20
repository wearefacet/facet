# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "c/unistd"

# Reopens the `dup` binding missing from `c/unistd` so the original
# `STDOUT.fd` target can be saved before the redirect.
lib LibC
  fun dup(fd : Int) : Int
end

# Redirects STDOUT to `/dev/null` for the duration of the block, then
# restores it. Used around CLI subcommand calls (`Artifact::ReconcileCLI`,
# `Artifact::PruneCLI`, `Artifact::RevokeCLI`) whose `puts` progress output
# would otherwise pollute spec output.
#
# The redirect targets `STDOUT.fd` — not fd 1 — because the Crystal runtime
# duplicates fd 1 at startup when stdout is a TTY, so `STDOUT.fd` may differ
# from 1. All writes through `STDOUT` (and the bare `puts` helper) follow
# the redirected descriptor, including buffered ones, because `sync` or
# `flush_on_newline` is enabled on `STDOUT` in both TTY and piped modes.
def silence_stdout(&) : Nil
  STDOUT.flush
  saved_fd = LibC.dup(STDOUT.fd)
  raise IO::Error.new("dup(STDOUT.fd) failed") if saved_fd < 0

  null = File.open(File::NULL, "w")
  LibC.dup2(null.fd, STDOUT.fd)
  begin
    yield
  ensure
    LibC.dup2(saved_fd, STDOUT.fd)
    LibC.close(saved_fd)
    null.close
  end
end
