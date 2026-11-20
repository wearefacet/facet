#!/bin/sh
# Run the e2e suite (`e2e/README.md`).
#
# One scenario file = one worker = one Docker stack = one database
# lifetime. With no arguments, every scenario listed in scenarios.txt runs
# in order. Positional arguments filter the list — `./run-suite.sh smoke`
# boots and drives only the smoke stack.
#
# The list must stay honest: every listed scenario must have a file under
# tests/. A listed scenario without a file fails the run — a silently
# skipped entry would make the release gate's manifest lie about coverage.
#
# Per scenario this script boots its own compose project, runs the
# scenario's Playwright project inside the runner container, and tears the
# stack down (`compose down -v` removes the project — the suite leaves the
# network clean). Artifacts land in artifacts/<scenario>/ (traces, videos,
# HTML report).
#
# The stacks carry no per-run secrets: the config's key literals ship in
# stack/config.e2e.yml.tmpl (throwaway data — see its comments).

set -eu

e2e_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$e2e_dir"

compose_file="compose.yml"
rc=0

# Every phase runs under a hard `timeout` (a failed step aborts the file —
# it must not block the shell forever). A hung image
# build, a stack that never gets healthy, or a wedged Playwright process
# ends its phase, the scenario fails, and the loop goes on. Seconds;
# override per invocation.
E2E_BOOT_TIMEOUT="${E2E_BOOT_TIMEOUT:-1800}" # stack boot + image builds
E2E_BUILD_TIMEOUT="${E2E_BUILD_TIMEOUT:-900}" # runner image build
E2E_TEST_TIMEOUT="${E2E_TEST_TIMEOUT:-1200}" # one scenario's Playwright run
E2E_DOWN_TIMEOUT="${E2E_DOWN_TIMEOUT:-120}" # stack teardown

if ! command -v timeout >/dev/null 2>&1; then
  echo "run-suite.sh needs GNU coreutils 'timeout' to bound every phase" >&2
  exit 1
fi

# Runs one phase under its budget. Exits 124/137 when the budget ran out
# (GNU timeout's codes for TERM/SIGKILL); every other status passes through.
# The status read must sit right after the run: inside an `if` condition a
# failed command leaves $? at the IF statement's status, which is 0.
run_bounded() {
  phase="$1"
  budget="$2"
  shift 2
  guard_status=0
  # --foreground is required. In its default mode, timeout moves the wrapped
  # command to a new background process group. The `compose run` phase is
  # interactive: it reads the terminal, the kernel answers SIGTTIN, and the
  # kernel stops the docker client. The phase then hangs at "Created" with
  # no output, Ctrl+C never reaches it, and the stack never tears down.
  # --foreground keeps the command in the shell's foreground group, so TTY
  # signals reach the whole tree. It also keeps compose's progress console
  # working; plain progress prints every event line twice on compose 5.x.
  timeout --foreground --kill-after=10 "$budget" "$@" || guard_status=$?
  # 124/137 are timeout's own codes for its TERM/SIGKILL. 130/131 mean the
  # user aborted (Ctrl+C / SIGQUIT) — not a budget overrun.
  if [ "$guard_status" -eq 124 ] || [ "$guard_status" -eq 137 ]; then
    echo "==> ${phase} exceeded its ${budget}s budget (timeout) — killed" >&2
  fi
  return "$guard_status"
}

scenarios=""
missing=""
while IFS= read -r line; do
  line="$(printf '%s' "$line" | cut -d'#' -f1 | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  if [ -f "tests/${line}.e2e.ts" ]; then
    scenarios="$scenarios $line"
  else
    missing="$missing $line"
  fi
done < scenarios.txt

# A listed scenario with no file means the manifest promises coverage the
# suite does not carry. Fail loud instead of skipping silently —
# write the test file or drop the line.
if [ -n "$missing" ]; then
  echo "scenarios.txt lists scenarios with no test file:${missing}" >&2
  echo "write tests/<name>.e2e.ts or remove the line — the gate list must stay honest" >&2
  exit 1
fi

if [ -z "$scenarios" ]; then
  echo "no scenario files found in tests/ (scenarios.txt lists the projects)" >&2
  exit 1
fi

# Optional positional args select a subset of the discovered scenarios.
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    case " $scenarios " in
      *" $arg "*) ;;
      *) echo "unknown or file-less scenario: ${arg} (known scenarios with files:${scenarios})" >&2; exit 1 ;;
    esac
  done
  selected=""
  for arg in "$@"; do
    selected="$selected $arg"
  done
  scenarios="$selected"
fi

for scenario in $scenarios; do
  stack="facet-e2e-${scenario}"
  echo
  echo "=================================================================="
  echo "==> scenario ${scenario} (stack ${stack})"
  echo "=================================================================="

  COMPOSE_PROJECT_NAME="$stack"
  E2E_SCENARIO="$scenario"
  export COMPOSE_PROJECT_NAME E2E_SCENARIO

  cleanup() {
    run_bounded "teardown (${stack})" "$E2E_DOWN_TIMEOUT" \
      docker compose -f "$compose_file" down -v --remove-orphans || \
      echo "==> teardown of ${stack} failed — containers or volumes may remain" >&2
  }
  trap 'cleanup' EXIT

  # Every failure path below tears the scenario's OWN stack down at the
  # point of failure, then clears the trap: the EXIT trap references only
  # the loop's last stack, so leaving it armed past a `continue` would
  # tear down the wrong stack at script exit (and leak the failed one).
  # POSIX sh has no `continue` across a function boundary, so the helper
  # stops at rc and each call site issues the continue itself.
  fail_scenario() {
    trap - EXIT
    cleanup
    rc=1
  }

  # A left-behind stack (an interrupted run, a crashed machine) would be
  # reused silently: `up` attaches to it, the entrypoint chain never re-runs,
  # and the database carries another attempt's data. Start every scenario
  # from zero.
  if ! run_bounded "pre-clean (${stack})" "$E2E_DOWN_TIMEOUT" \
    docker compose -f "$compose_file" down -v --remove-orphans; then
    echo "==> pre-clean of ${stack} failed — a stale stack may still run" >&2
    fail_scenario
    continue
  fi

  if ! run_bounded "stack boot (${stack})" "$E2E_BOOT_TIMEOUT" \
    docker compose -f "$compose_file" up -d --build --wait; then
    echo "==> stack ${stack} did not become healthy — dumping backend logs"
    docker compose -f "$compose_file" logs --no-color backend 2>/dev/null | tail -80 || true
    echo "==> scenario ${scenario} BOOT-FAILED"
    fail_scenario
    continue
  fi

  # The runner sits behind the `run` profile, so `up --build` passes it by;
  # `compose run` only builds when the image is missing. Rebuild it every
  # time — the test files are baked into the image, and a stale one runs the
  # previous version of the suite (a false green is indistinguishable from
  # a pass). Layer-cached: source-only edits stay cheap.
  # The build log goes to a temp file and is dumped on failure — a silent
  # redirected failure hides its cause (a flaky registry fetch, a full
  # disk, a lockfile mismatch). It cannot live under artifacts/: the
  # runner container owns that tree as root.
  #
  # One retry: the build's only network-dependent step is the FROM-tag
  # resolution (`mcr.microsoft.com/playwright:…` is pinned by tag, not
  # digest, so BuildKit re-resolves it remotely on every uncached build) and
  # that fetch has failed with connection resets. Layer cache makes the
  # retry cheap when the base is warm; a second reset is a real failure and
  # is reported as BUILD-FAILED — a build problem is not a test failure.
  build_ok=0
  attempt=0
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    build_log="$(mktemp "${TMPDIR:-/tmp}/facet-runner-build.XXXXXX")"
    if run_bounded "runner image build (${scenario}, attempt ${attempt})" "$E2E_BUILD_TIMEOUT" \
      docker compose -f "$compose_file" build runner --progress=plain \
      >"$build_log" 2>&1; then
      build_ok=1
      rm -f "$build_log"
      break
    fi
    echo "==> runner image build attempt ${attempt} failed — log: ${build_log}" >&2
    tail -40 "$build_log" >&2 || true
    rm -f "$build_log"
  done
  if [ "$build_ok" -ne 1 ]; then
    echo "==> scenario ${scenario} BUILD-FAILED"
    fail_scenario
    continue
  fi

  if run_bounded "playwright run (${scenario})" "$E2E_TEST_TIMEOUT" \
    docker compose -f "$compose_file" run --rm \
    runner pnpm exec playwright test --project="$scenario"; then
    echo "==> scenario ${scenario} PASSED"
  else
    echo "==> scenario ${scenario} FAILED"
    rc=1
  fi

  trap - EXIT
  cleanup
done

exit "$rc"
