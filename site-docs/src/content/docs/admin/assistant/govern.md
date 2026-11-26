---
type: how-to
title: Governing the assistant
description: Control who can open the assistant, cap its token use, and set its name, instructions, and tool behaviour.
audience: [admin]
features: [AI-08, AI-07]
sidebar:
  order: 1
verified_at: fd345fe3
---

The assistant works under the rights of the account that talks to it. It holds
no permissions of its own. An administrator decides who can open it, how much
each account may spend, and what it is called.

## When to use this

- You must switch the assistant on for some roles and off for others.
- You must cap what each account can spend on tokens.
- You want the assistant to follow house instructions.

## Before you start

- **Roles.** They carry the switch and the budget — see
  [Roles and permission lines](/admin/people/roles-and-permissions/).
- **Platform settings.** They live on one document that only administrators
  can edit by default.

## Steps

### 1. Open the assistant to a role

The role's `connectivity` list must carry the `assistant` channel:

```json
{
  "name": "analyst",
  "connectivity": ["assistant"],
  "assistant_token_budget": 500000
}
```

This role content opens the assistant to accounts that hold it, and caps them
at 500,000 tokens over a rolling 30-day window. The gate runs on every
request. Remove the channel from the role, and access dies on the next
request.

### 2. Set the token budget

`assistant_token_budget` is an integer on the role. Empty means unlimited. A
budget of `0` means no tokens: the account holds the channel, and every turn
is refused.

An account's effective budget is the largest budget over the roles it holds
that enable the assistant. If any of those roles is unlimited, the account is
unlimited.

| Role | `connectivity` | `assistant_token_budget` |
| --- | --- | --- |
| `analyst` | `["assistant"]` | `500000` |
| `editor` | `["assistant"]` | `null` |

An account that holds both roles is unlimited. An account that holds only
`analyst` gets 500,000 tokens. When the rolling total reaches the budget, the
next turn answers `429`.

:::tip
Each caller can read their own meter at `GET /Api/assistant/usage`. The answer
carries the rolling total, the effective budget, and the window start.
:::

### 3. Name the assistant and write the house instructions

Open **Configure → Platform → Settings** and set:

- `assistant.name` — the display name on every assistant surface. Default:
  `Assistant`.
- `assistant.system_prompt` — the custom instructions. Facet bakes them into
  every new conversation under a `## Custom instructions` heading.

  Or set both through the API:

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"name": "Atlas", "system_prompt": "Answer in short sentences. Name the document you base each answer on."}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

:::note[Instructions reach new conversations]
A conversation bakes its prompt at creation. A settings change does not
rewrite existing conversations. A model or endpoint change does: existing
conversations move at their next turn.
:::

### 4. Set the tool behaviour and the model connection

`assistant.auto_execute_tools` on the settings document controls tool
resolution. The default `true` auto-resolves registered tool calls. Set it to
`false` to turn automatic resolution off.

The same document carries the model connection — `assistant.api_endpoint`,
`assistant.api_key` (a secret), and `assistant.model`, plus the sampling knobs
`assistant.max_tokens`, `assistant.temperature`, and `assistant.max_history`.
A connection change reaches existing conversations at their next turn.

### 5. Govern the assistant inside an app

An app surface needs two switches on at once:

- the app's `assistant_enabled` field, off by default, and
- the active role's `assistant` channel.

Facet checks both on every message. A missing app row fails closed. The app
can also carry `assistant_prompt` with app-specific instructions.

## Explanation

### Availability

Two gates decide availability:

1. **The role gate.** The active role's `connectivity` list carries
  `assistant`. Facet reads the role content live, per request.
2. **The app gate,** for app conversations. The app row is live, the flag is
  on, and the token names that app. Facet re-reads the app on every message.

Credential-less requests are refused. The anonymous principal never opens the
assistant.

### The usage ledger

Every streamed turn of a billable account writes one ledger row: the model,
the input and output tokens, and whether the count is an estimate. The limit
check runs before each turn. It compares the rolling 30-day total against the
effective budget. An unlimited budget skips the check.

The ledger retention is the config key `assistant.usage_retention_days`. The
default `0` keeps every row. If you set a window, keep it at 30 days or more,
so pruning cannot delete rows that the budget check still reads. Budgets bound
each account; they do not pool across accounts, and they count tokens, not
money.

### The assistant holds no rights

Every tool call inherits the caller's identity: the elected role, row scopes,
field tags, and the app grant where one applies. A document the caller cannot
read is invisible to the assistant. See
[AI under the caller's rights](/discover/how-it-works/assistant/).

A document write that the assistant makes records the caller as the actor. The
cause metadata marks it as assistant work — see
[Auditing activity](/admin/history/audit/).

## Troubleshooting

### A member sees no assistant

The active role's channel list misses `assistant`. Check the elected role: one
role is active per request, and roles never merge.

### Every turn answers `429`

The account passed its rolling budget. Widen a role budget, or wait while old
usage ages out of the 30-day window.

### The new instructions do not apply

The conversation predates the change. Start a new conversation.

### An app chat answers `403`

The app flag, the token's app, or the role channel is missing.

### The name did not change

Check that the settings document saved. The default write right is admin-only.

## Related

- [The assistant](/use/assistant/) — the workspace surface.
- [AI under the caller's rights](/discover/how-it-works/assistant/) — the boundary model.
- [Roles and permission lines](/admin/people/roles-and-permissions/) — where `connectivity` lives.
- [Controlling app reach](/admin/apps-access/app-grants/) — the app-side switches.
- Internals on GitHub: [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
