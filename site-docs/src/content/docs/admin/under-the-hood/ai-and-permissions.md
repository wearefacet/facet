---
type: explanation
title: AI and permissions, in detail
description: How the assistant's tool calls pass the same authorization checks as a REST call, and how assistant work is audited.
audience: [admin, developer]
features: [AI-07, AI-08, RBC-10]
verified_at: eee55a2
sidebar:
  order: 5
---

An assistant turn sounds like a delegation of power: "find my overdue
bookings and move the returned ones back in". The model decides which tools
to call, but it decides nothing about rights. Every tool call runs under the
rights of the person who asked. The checks, the scopes, and the audit trail
are the same as if they had clicked the button themselves. This page walks
one tool call through those checks.

## Explanation

*The model picks the tool; the caller's rights pick the answer.*

<!-- d2
direction: down
caller: Caller asks in chat {class: external}
session: Assistant turn on the caller's auth context
model: Model picks a tool call
tools: Tool registry dispatch
enforcers: Read and write enforcers {class: decision}
result: Answer within the caller's rights {class: ok}
denied: Refusal the model must accept {class: danger}

caller -> session
session -> model
model -> tools
tools -> enforcers
enforcers -> result
enforcers -> denied
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9246da84-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9246da84-dark.svg" alt="Diagram" loading="lazy" />
</div>

### One auth context, carried through

The streaming route builds the request's auth context like every other route
does. It reads the caller's own credential: their session, their API key, or
the app's token. The assistant never mints a context of its own. The whole
turn, and every tool call inside it, carries that one context: one identity,
one elected role.

### Tool calls re-run the enforcement

The tool registry lists tools to the model in classes — read, write, and
action — filtered by the active role's permission lines. A role without any
read line never sees the read tools. But visibility is a convenience for the
model, never a boundary. Every executed call re-runs the full per-doctype
enforcement, exactly as on REST. The read enforcer and the write enforcer
check the role's permission lines, the row scopes, and the field tags again
on every call.

The consequence is the boundary guarantee: a document the caller cannot read
is invisible to the assistant. A field their role does not see never enters
a tool result. A row outside their scope answers a non-disclosing refusal,
the same answer a REST call would get.

### Refusals are part of the conversation

A refused call is not an error page; it is a tool result the model must
accept. The registry returns the same non-disclosing messages REST returns,
plus the
per-field diagnostics of validation failures. A class-level denial surfaces
as a bare refusal. An invisible document answers not-found. The model can
retry with better arguments, and does.

Repeated identical refusals get a guard. The first two identical refusals in
one turn return the normal error envelope. The third returns a terminal
envelope whose text tells the model the refusal is final. A second terminal
envelope for the same call cancels the turn: the partial history stays, and
the turn ends through the standard cancelled path. The guard exists so a
looping model cannot burn tokens hammering a door that will not open.

### Writes are auditable as assistant work

When a tool call writes, the mutation records two things at once:

- **The actor is the caller.** The mutation's actioner is the account that
  asked, under their elected role.
- **The cause is assistant work.** The write carries a root cause of kind
  `assistant`, so the audit surfaces can show what the assistant drove,
  separate from the account's own clicks.

A live row from the running instance shows the shape:

```text
cause_kind:  assistant
cause_name:  domain-builder
channel:     internal
actioner_id: 06H1FKW9RRQX860BKXRBY3YT8V   ← the account that asked
```

Find these rows with the audit filters — see
[See who did what](/admin/history/audit/).

### The three surfaces differ in one detail

Three assistant surfaces share the mechanism above, with one difference:

| Surface | Auth context of the tool calls |
| --- | --- |
| Workspace assistant | The caller's own auth context, as above. |
| App assistant | The calling app's token — the gate refuses a token that names no app or another app, and every tool call inherits the app's grant ceiling on top of the caller's role. |
| Domain-builder assistant | A system-tier principal with draft-domain tools; writes are attributed to the conversation owner, so the audit still names the human. |

The app ceiling is the strictest of the three. An app chat cannot reach past
the app's grants, even when the user's own role could.

## What this means for you

- **Give the role, not the assistant, the rights you regret.** Narrowing a
  role narrows the assistant with it, on the next turn.
- **Audit assistant changes like any change.** They land in the same log,
  with the caller as actor and `assistant` as cause.
- **An app chat is capped twice** — by the user's role and by the app's
  grants. Neither alone is the limit; the intersection is.

## Related

- [Govern the assistant](/admin/assistant/govern/) — who may open it, and the token budgets — one layer up.
- [The assistant: AI with your rights](/discover/how-it-works/assistant/) — the plain-words boundary model.
- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — the enforcers every call re-runs.
- [Why you act as one role at a time](/admin/under-the-hood/one-role-at-a-time/) — the auth context the turn carries.
- [Agent tools](/reference/agent-tools/) — the registry this page dispatches through.
- Internals on GitHub: [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md).
