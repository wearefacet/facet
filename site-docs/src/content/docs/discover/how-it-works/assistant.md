---
type: explanation
title: "AI under the caller's rights"
description: The assistant and external agents act with the caller's own rights and leave the same audit rows.
audience: [admin, developer]
features: [AI-01, AI-04]
sidebar:
  order: 5
verified_at: 7a6cb462
---

The workspace assistant has no permissions of its own. It acts inside the
auth context of the account that opened the conversation. The assistant sees
and changes only what that account may see and change. External agents connect
through MCP (Model Context Protocol) and follow the same rule.

## Explanation

<!-- d2
message: "Account sends a chat message" {class: external}
tool: "Assistant picks a tool"
check: "Enforcers check the caller's role" {class: decision}
denied: "Tool returns a denial" {class: danger}
write: "Write service runs the change"
audit: "Mutation row lands in the audit log" {class: store}

message -> tool
check -> denied: denied
check -> write: allowed
write -> audit
tool -> check
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/e7f20cd9-light.svg" alt="Account sends a chat message" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/e7f20cd9-dark.svg" alt="Account sends a chat message" loading="lazy" />
</div>

### One enforcement path

The workspace assistant is the chat surface of the main application. It reads
and writes live documents, runs named actions, computes aggregates, and opens
pages for the signed-in user. Every tool call runs with the caller's own auth
context. Row scopes, field visibility, and denials behave exactly as on a
direct request by that account. The assistant cannot see a document the
account cannot see. A denial is final, and the system prompt tells the model
so.

**The role gates availability.** A role must list `assistant` in its
connectivity array before an account can open the chat. The backend re-checks
the gate on every streamed message, so a role change applies on the next
message.

### One tool catalogue

Artificial intelligence (AI) surfaces share one catalogue of document tools.
The workspace assistant mounts it, and every MCP client sees the same entries.
The listing an agent sees is filtered to the rights of the role pinned in the
MCP URL. Filtering is a convenience, not a boundary. Enforcement runs again at
call time, in the same enforcers as any direct request.

The catalogue carries document tools only. An agent can create, read, update,
and delete documents, run actions, and search. It cannot register doctypes,
publish domains, or edit grants.

### Same audit trail

Every write a tool makes goes through the ordinary write services. It lands as
a mutation row in the audit log, attributed to the caller's account. Writes
made by the workspace assistant carry an `assistant` cause, so the log marks
them as model-driven. Writes over MCP carry the same `request` cause as a
direct request. Nothing an agent does is invisible to the audit.

**Why not a separate AI service account?** Such an account would need broad
rights to serve every caller. Its permissions would drift from the role
model. Its audit rows would name the service, not the person who
asked. Under the caller's rights, revoking a role also cuts the assistant.
Every action traces to the account that caused it. The same model serves
apps: the per-app assistant runs under the calling app's auth context,
capped by the app's grant.

:::note
The domain-builder assistant is the exception. It edits doctype definitions
inside a draft domain under a system-tier principal, with each write tool
scoped to that draft. Its reads reach further; its writes stay in the draft.
:::

**The cost is symmetry.** The same prompt returns different results for
different accounts, because each answer is scoped to the caller's rights. The
assistant cannot help with what the caller cannot see. It cannot act for an
account with broader rights, and it cannot raise its own access.

## Related

- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — the identity and role model behind every channel.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — the enforcers each tool call passes.
- [Apps](/build/apps/) — apps embed the assistant under their own grant.
- [Security & governance overview](/discover/security/) — roles, grants and audit in one picture.
- Internals on GitHub: [agent-tools.md](https://github.com/wearefacet/facet/blob/main/doc/backend/agent-tools.md), [workspace-assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/workspace-assistant.md).
