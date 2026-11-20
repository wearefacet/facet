# WP 06 — Tutorials, advanced (T3, T5, T6)

Phase 1 · Depends on: WP 05 (T3 reuses T2's Inventory domain; T5 and T6 assume a running instance from T1) · Write scope: `site-docs/src/content/docs/tutorials/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.2. Use the tutorial skeleton from WP 05.

## Tutorials

### T3 — `tutorials/t3-assistant-domain.md` — "Build it with the assistant"

- `audience: [author]`, `features: [AI-02, AI-06, FE-10]`
- Outcome (whole-doc): the same Inventory domain as T2, authored through the domain-builder chat.
- Sources: `doc/backend/assistant.md`, `doc/backend/domain-builder-skills.md`, `doc/backend/domain-editors.md`, `doc/backend/draft-domains.md`, `doc/frontend/chat.md`.
- Structure: part 1 repeats the T2 goal; part 2 does it in the chat, with the actual prompts to type and the actual replies to expect. Compare the two paths at the end.

### T5 — `tutorials/t5-ship-app.md` — "Ship an AI-built app on Facet"

- `audience: [developer]`, `features: [APP-01, APP-02, APP-09, APP-06, APP-10, FE-12]`
- Outcome (whole-doc): scaffold, connect with the SDK, OAuth login, deploy, roll back.
- Sources: `doc/backend/app-system.md`, `doc/backend/oauth.md`, `doc/packages/sdk.md`, `doc/packages/cli.md`, `doc/backend/rbac.md` (grants).
- The app is a small frontend over the T2 Inventory domain. Code blocks are complete and runnable (WP 00).

### T6 — `tutorials/t6-mcp-agent.md` — "Connect an AI agent over MCP"

- `audience: [developer, admin]`, `features: [AI-05, AI-04, APP-04, APP-05]`
- Outcome (whole-doc): Claude or another MCP client reads and writes under a delegated role.
- Sources: `doc/backend/mcp.md`, `doc/backend/agent-tools.md`, `doc/backend/rbac.md`, `doc/backend/app-system.md`.
- Include the exact MCP client config (JSON) and the delegated role setup. Show one read and one write, and the audit entries they produce — that is the governance story.

## Testing requirement

Same as WP 05: run every step, capture real output, fix or report. T3 needs an instance with the assistant configured (LLM endpoint — `doc/backend/assistant.md`, operator setup). If the assistant is not configured in your environment, stop and report.

## Definition of done

- [ ] Three tutorials, WP 05 skeleton, front-matter per WP 00.
- [ ] Every step executed; outputs match the page.
- [ ] `cd site-docs && npm run build` passes.
- [ ] `tutorials/index.md` now lists all six tutorials with outcomes.
