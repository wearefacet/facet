---
title: Configuring the assistant
description: Point the assistant at an OpenAI-compatible API and set its model, name, and tuning knobs.
audience: [operator]
features: [AI-08, AI-07, AI-09]
sidebar:
  order: 9
verified_at: 008dd880
---

The assistant talks to any OpenAI-compatible API. As the operator you point
it at an endpoint, pick a model, and tune the turn behaviour. The
connection keys are hot: a settings save moves every conversation to the new
connection at its next turn. Who may open the assistant, and how much each
account may spend, is role business — see
[Governing the assistant](/govern/governing-assistant/).

## When to use this

Configure the assistant when:

- You connect a provider for the first time.
- You switch the model or the endpoint.
- You bound the usage ledger and understand the stale-turn sweep.

## Before you start

- You hold a role that can update `core.SystemSettings`, or you can edit the
  config file and restart.
- You have an API key for the provider.
- Role budgets gate spending before any of these settings matter — set them
  first if you need caps.

## Steps

### 1. Set the connection

Pin the connection on the **Configure → Platform → Settings** page, or set
the `assistant:` section in the config file:

```yaml
assistant:
  name: Assistant
  api_endpoint: https://api.openai.com/v1
  api_key: !env FACET_AI_API_KEY
  model: gpt-4o
  system_prompt: "Answer in short sentences. Name the document you base each answer on."
  max_history: 40
  max_tokens: 2048
  temperature: 0.7
  auto_execute_tools: true
```

| Key | Default | Meaning |
| --- | --- | --- |
| `assistant.name` | `Assistant` | The display name on every assistant surface. |
| `assistant.api_endpoint` | `https://api.openai.com/v1` | The OpenAI-compatible endpoint. |
| `assistant.api_key` | none | The provider key. A secret field; stored sealed when pinned. |
| `assistant.model` | `gpt-4o` | The model identifier. |
| `assistant.system_prompt` | none | House instructions for every new conversation. |
| `assistant.max_tokens` | none | Completion token cap per turn. |
| `assistant.temperature` | none | Sampling temperature, 0.0 to 2.0. |
| `assistant.max_history` | none | Turns kept in context. Unlimited when unset. |
| `assistant.auto_execute_tools` | `true` | Resolve registered tool calls automatically. |

The write gate bounds the values: temperature between 0.0 and 2.0,
`max_tokens` above 0, `max_history` 0 or more.

### 2. Know when a change reaches conversations

The connection resolves at every turn start. A model or endpoint change
moves existing conversations at their next turn. The system prompt is
different: each conversation bakes its prompt at creation, so a prompt
change reaches only conversations created afterwards.

:::caution
A model switch within one provider is the supported path. A switch across
providers replays the stored history to the new provider, and no spec
covers that replay. Verify the behaviour on a fresh conversation before you
switch providers in production.
:::

### 3. Set the file-only knobs

These keys bind at boot and stay file-only:

```yaml
assistant:
  cancel_ttl_seconds: 15
  turn_timeout_seconds: 900
  turn_sweep_cron: "*/5 * * * *"
  usage_retention_days: 0
  usage_prune_cron: "30 4 * * *"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `cancel_ttl_seconds` | `15` | How long a cancel signal lives in Redis. |
| `turn_timeout_seconds` | `900` | How long a `running` turn may stay un-flipped before the sweep closes it. |
| `turn_sweep_cron` | `*/5 * * * *` | The stale-turn sweep schedule. |
| `usage_retention_days` | `0` | Ledger retention in days. `0` keeps every row. |
| `usage_prune_cron` | `30 4 * * *` | The ledger prune schedule. |

### 4. Bound the usage ledger

Every turn that delivered output writes one ledger row: the model, the
input and output tokens, and whether the count is an estimate. Role budgets
compare against a rolling 30-day window over this ledger.

If you set `usage_retention_days`, keep it at 31 or more. A window of 1 to
30 under-counts every live budget, and the daily prune logs a warning. The
default `0` keeps every row forever.

:::tip
Each caller can read their own meter at `GET /Api/assistant/usage`. The
answer carries the rolling total, the effective budget, and the window
start.
:::

### 5. Know the stale-turn sweep

A process that dies mid-turn leaves its turn row in the `running` state.
The sweep runs on `turn_sweep_cron`, finds `running` turns older than
`turn_timeout_seconds`, and closes them: status `error` with the message
`interrupted`. The client sees the terminal state at its next read. The
pass is idempotent: it never touches an already-terminal row.

## Example

A complete `assistant:` section for a self-hosted, OpenAI-compatible
gateway:

```yaml
assistant:
  name: Atlas
  api_endpoint: https://llm.internal.example.tld/v1
  api_key: !env FACET_AI_API_KEY
  model: gpt-4o
  system_prompt: "Answer in short sentences. Name the document you base each answer on."
  max_history: 40
  max_tokens: 2048
  temperature: 0.7
  auto_execute_tools: true
  cancel_ttl_seconds: 15
  turn_timeout_seconds: 900
  turn_sweep_cron: "*/5 * * * *"
  usage_retention_days: 90
  usage_prune_cron: "30 4 * * *"
```

## Troubleshooting

**Every turn answers `429`.**

The account passed its rolling role budget. Widen the budget on the role —
see [Governing the assistant](/govern/governing-assistant/).

**The new instructions do not apply.**

The conversation predates the change. Start a new conversation.

**A conversation is stuck on `running`.**

The process died mid-turn. The sweep closes the turn after
`turn_timeout_seconds` — status `error`, message `interrupted` — 15
minutes by default.

**The budget check under-counts.**

`usage_retention_days` is set below 31, so the prune deletes rows the
30-day budget window still reads. Raise it to 31 or more, or set `0`.

**The assistant answers `401` or `403` from the provider.**

The endpoint or the key is wrong. Check `assistant.api_endpoint` and
re-stage `assistant.api_key` on the settings page.

## Related

- [Governing the assistant](/govern/governing-assistant/) — who may open it, and the token budgets.
- [The assistant](/workspace/assistant/) — the workspace surface.
- [System settings](/operate/system-settings/) — the hot keys and the pin mechanics.
- [AI under the caller's rights](/concepts/ai-under-callers-rights/) — why the assistant holds no rights of its own.
- Internals on GitHub: [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
