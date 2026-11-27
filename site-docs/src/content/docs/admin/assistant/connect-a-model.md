---
title: Connect a language model
description: Point the assistant at an OpenAI-compatible API, test the connection, and tune the turn behaviour.
type: how-to
audience: [admin, operator]
features: [AI-08, AI-07, AI-09]
verified_at: 11202ad
sidebar:
  order: 0
---

The assistant is switched on for a role, but every turn ends in an error:
no model is connected. Facet ships the assistant disabled — no provider, no
crash at boot. You connect it to any OpenAI-compatible API: set an endpoint,
a key, and a model. The connection is hot: a settings save moves every
conversation to the new connection at its next turn. Who may open the
assistant, and how much each account may spend, is role business — see
[Govern the assistant](/admin/assistant/govern/).

## When to use this

- You connect a provider for the first time.
- You switch the model or the endpoint.
- You bound the usage ledger and understand the stale-turn sweep.

## Before you start

- You hold a role that can update `core.SystemSettings` — the seeded
  `iam.Roles.admin` does — or you can edit the config file and restart.
- You have an API key for the provider.
- [Role budgets](/admin/assistant/govern/) gate spending before any of these settings matter — set them
  first if you need caps.

## Steps

### 1. Set the connection

Open **Configure → Platform → Settings** and find the Assistant group. The
connection fields are:

| Field | Default | Meaning |
| --- | --- | --- |
| `assistant.api_endpoint` | `https://api.openai.com/v1` | The OpenAI-compatible endpoint. |
| `assistant.api_key` | not set | The provider key. A secret: the page shows *set* or *not set*, never the value. |
| `assistant.model` | `gpt-4o` | The model identifier. |

Any model the endpoint serves works. The choice is a trade-off between
cost, speed, and quality.

:::note
Lost in the model zoo? We recommend [OpenRouter](https://openrouter.ai)
with the model `glm-5.3-flash`: one key and one endpoint
(`https://openrouter.ai/api/v1`) reach many models, and GLM 5.3 Flash
balances performance, speed, and cost. Amplitude (the creator of Facet !) also use DeepSeek v4.1 Flash;
it works well, as long as you keep the conversation in English. A frontier model
such as Claude Opus 5.5 costs more and performs best overall.
:::

Copy the model identifier exactly as the provider's model page shows it
into `assistant.model`.

The same page carries the house persona — see
[Govern the assistant](/admin/assistant/govern/) for `assistant.name`,
`assistant.system_prompt`, and the tuning knobs.

### 2. Test the connection

Select **Send test request**. The button sends one minimal completion through
the saved settings — the same path a chat turn takes. Save any pending change
first; the test uses the saved settings.

The answers:

| Answer | Meaning |
| --- | --- |
| `200` `{model, endpoint, reply}` | The provider answered. |
| `422` | No API key resolves. The message names the fix: *Set assistant.api_key (or the FACET_AI_API_KEY environment variable) and save before testing*. |
| `502` | The provider or the transport failed. The message carries the transport's own words — `401 invalid_api_key` or `connection refused` is the diagnostic. |

The probe never runs agent tools, never touches a conversation, and never
writes a turn row. It dials the provider once, so it costs one tiny request.

### 3. Know how the three tiers resolve

Facet reads the connection at every turn start, in one fixed order:

1. **The settings pin.** What an administrator saved on the settings page.
   The API key sits in a sealed slot; the page shows only set or not set.
2. **The config file.** The `assistant:` section of `config.{env}.yml`.
   The shipped files read their values from the environment:

   ```yaml
   assistant:
     api_endpoint: !env? FACET_AI_API_ENDPOINT
     api_key: !env? FACET_AI_API_KEY
     model: !env? FACET_AI_MODEL
   ```

   `!env?` is the optional tier: a missing variable collapses the key to
   null, and the assistant stays disabled — no crash at boot.
3. **The built-in default.** Endpoint `https://api.openai.com/v1`, model
   `gpt-4o`, name `Assistant`.

A key resolving through tier 1 or 2 is what "configured" means everywhere.
The sign-in payload serves it as `assistant.configured`. When it is `false`,
the dock stays visible but conversation creation is disabled. The message
names system settings as the fix.

### 4. Know when a change reaches conversations

The endpoint, key, model, and sampling knobs resolve at every turn start. A
change reaches existing conversations at their next turn. The system prompt
is different: each conversation bakes its prompt at creation, so a prompt
change reaches only conversations created afterwards.

:::caution
A model switch within one provider is the supported path. A switch across
providers replays the stored history to the new provider, and no spec covers
that replay. Verify the behaviour on a fresh conversation before you switch
providers in production.
:::

### 5. Set the file-only knobs

These keys bind at boot and stay file-only — the settings page does not carry
them:

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

### 6. Bound the usage ledger

Every turn that delivered output writes one ledger row: the model, the input
and output tokens, and whether the count is an estimate. Role budgets compare
against a rolling 30-day window over this ledger.

If you set `usage_retention_days`, keep it at 31 or more. A window of 1 to 30
under-counts every live budget, and the daily prune logs a warning. The
default `0` keeps every row forever.

:::tip
Each caller can read their own meter at `GET /Api/assistant/usage`. From the
running instance:

```json
{
  "total": 43290,
  "estimated_total": 0,
  "budget": null,
  "window_start": "2026-10-27T14:53:01Z",
  "window_days": 30
}
```
:::

### 7. Know the stale-turn sweep

A process that dies mid-turn leaves its turn row in the `running` state. The
sweep runs on `turn_sweep_cron`, finds `running` turns older than
`turn_timeout_seconds`, and closes them: status `error` with the message
`interrupted`. The client sees the terminal state at its next read. The pass
is idempotent: it never touches an already-terminal row.

## Example

A complete `assistant:` section for a self-hosted, OpenAI-compatible gateway,
with the file-only knobs:

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

`!env` (without the `?`) fails the boot when the variable is missing. Use it
when the deployment must not start without a key.

## Troubleshooting

**Every turn answers `429`.**

The account passed its rolling role budget. Widen the budget on the role —
see [Govern the assistant](/admin/assistant/govern/).

**The new instructions do not apply.**

The conversation predates the change. Start a new conversation.

**A conversation is stuck on `running`.**

The process died mid-turn. The sweep closes the turn after
`turn_timeout_seconds` — status `error`, message `interrupted` — 15 minutes
by default.

**The budget check under-counts.**

`usage_retention_days` is set below 31, so the prune deletes rows the 30-day
budget window still reads. Raise it to 31 or more, or set `0`.

**The assistant answers `401` or `403` from the provider.**

The endpoint or the key is wrong. Check `assistant.api_endpoint` and
re-stage `assistant.api_key` on the settings page.

## Related

- [Govern the assistant](/admin/assistant/govern/) — who may open it, and the token budgets.
- [Using the assistant](/use/assistant/) — the workspace surface.
- [System settings](/admin/configure/system-settings/) — the hot keys and the pin mechanics.
- [The assistant: AI with your rights](/discover/how-it-works/assistant/) — why the assistant holds no rights of its own.
- Internals on GitHub: [assistant.md](https://github.com/wearefacet/facet/blob/main/doc/backend/assistant.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
- [AI and permissions, in detail](/admin/under-the-hood/ai-and-permissions/)
