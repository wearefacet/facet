# preview_view (`kind: "document"`): the template argument never arrives

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0800DJ8P20PGRM67H8KXJHA` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | backend (assistant domain-builder tools) + agent tool-calling chain |
| Verdict | Phenomenon confirmed. Mechanism revised — no code in this repo drops the argument |

## Summary

`preview_view` calls with `kind: "document"` fail with
`Missing 'template' argument (received: kind, sample_data, title)` — even when
the caller intends to send the template, across three different encodings. The
investigation traced every hop in the repo: nothing filters or strips
arguments. The error message is an honest echo of the parsed keys. The call
arrives without `template` in its JSON — the loss happens upstream, most
probably in model emission (a mode this project has already documented).

## Evidence

- The tool declares `template` unconditionally:
  `src/assistant/domain_builder/tools/ui_tools.cr` L32-42
  (`"template" => {"type" => "object", ...}`; only `kind` is required). The
  kind condition lives in the callback (L46-48). Specs pass when the argument
  is present (`spec/assistant/domain_builder/tools_spec.cr` L1170-1183).
- Hop-by-hop trace found no filtering: the stream parser concatenates raw
  argument deltas (`lib/agent-cr/src/agent/provider/openai/stream_parser.cr`
  L393-398); `agent.cr` parses the JSON (L612-614) and validates errors-only,
  never strips (L672-704). A string-encoded template would fail with a type
  error — a different message than the one reported. The trace handler and the
  session only read (`src/assistant/stream/tool_trace_handler.cr` L56-74).
- The reported error is built from the actual parsed keys —
  `src/assistant/domain_builder/tools.cr` L244-252 (`req_any`):
  `"Missing '{{key}}' argument (received: ...)"`. So `template` was genuinely
  absent from the emitted JSON. Repeating the call with different "encodings"
  reproduces the same echo because the model omitted the key each time.
- `doc/backend/assistant.md` L127-136 documents this exact failure mode from a
  prior investigation: under payload volume, tool-calling models drop arguments
  — even required ones — while their own reasoning says they passed them.
- The frontend `parseViewPreview` (`frontend/src/lib/assistant/ui-tools.ts`
  L63-97) builds its object from the same raw string after the fact; it cannot
  cause the backend error.

## Verification step available

`agent_turns.response_messages` stores the assistant tool calls with the exact
arguments the backend received (`doc/backend/assistant.md` L138-141). Read the
failing turn there to separate "model emitted without template" from "provider
stripped it".

## Fix direction

- First verify with the stored turn (above).
- Improve the `req_any` missing-argument error to instruct a full re-emit
  ("the previous call reached the server without 'template'; re-emit the
  complete call").
- If weak models must be supported: split `preview_view` per kind
  (`preview_document_view` / `preview_collection_view`) so each schema can put
  its required argument in `required` — a flat tool schema cannot express
  "required only when kind='document'".
- Related cosmetic defect found during the trace:
  `frontend/src/lib/assistant/reconstruct-turns.ts` L102 detects failure only
  via the `"Error executing tool"` prefix, so a tool result
  `{"ok":false,...}` replays with `status: 'ok'` — wrong status label in turn
  replay.
