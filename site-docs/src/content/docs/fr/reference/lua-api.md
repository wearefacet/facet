---
title: API Lua
description: "La surface Lua d’un script : globales, namespaces et signatures."
audience: [developer]
type: reference
features: [AUT-08, DOM-08]
verified_at: f1409cdc
---

> Généré depuis `src/lua` par `make gen-docs-lua`. Ne modifiez pas ce fichier à la main.

Les scripts Lua s’exécutent dans un bac à sable avec un ensemble fixe de globales. Les hooks de cycle de vie, les actions nommées et les hooks de domaine reçoivent la surface complète : `document`, `notification`, `util`, `date` et `math.clamp`. Les champs calculés reçoivent `util` et `date`, plus une table `document` en lecture seule. Ils n’ont ni `notification` ni les fonctions `util` adossées à une requête. Les scripts reçoivent aussi l’objet `ctx` et un collecteur `error(msg)` ; voir les scripts de cycle de vie et les garde-fous.

## document

Les lectures acceptent un `domain.Doctype` qualifié en premier argument. Une lecture hors domaine demande une attribution de domaine active ; le contenu renvoyé se réduit aux champs couverts.

| Fonction | Signature | Rôle |
| --- | --- | --- |
| `document.create` | `doc_type, content_json` | Creates a new document of the given doctype in the same domain. |
| `document.get` | `doc_type, doc_id` | Fetches a document by doctype and ID. |
| `document.update` | `doc_type, doc_id, content_json` | Partially updates a document. |
| `document.delete` | `doc_type, doc_id` | Soft-deletes a document. |
| `document.list` | `doc_type, [filters], [sort], [page], [per_page]` | Lists documents of the given doctype. |

:::note
Chaque fonction `document.*` lève une erreur Lua rattrapable en cas d’échec. Traitez-la avec `pcall`.
:::

## notification

| Fonction | Signature | Rôle |
| --- | --- | --- |
| `notification.send` | `account_id, doc_ref, kind, title, [options]` | Produces one notification for an account. |

## util

| Fonction | Signature | Rôle |
| --- | --- | --- |
| `util.clamp` | `x, min, max` | Clamp a number between min and max. |
| `util.coalesce` | `...` | Returns the first non-nil, non-empty value, or nil if none. |
| `util.facet_hosts` | `()` | The host set Facet itself answers at — what the `app.App` `host` field must never claim. |
| `util.insecure_urls_allowed` | `()` | `allow_insecure_urls` — when false (default), the dispatcher rejects non-`https` target URLs. |
| `util.is_empty` | `v` | Returns true for nil, empty string, empty array, empty hash. |
| `util.json_decode` | `json_str` | Parses a JSON string and returns a Lua table/array/value. Not available in transient contexts. |
| `util.json_encode` | `value` | Serialises any Lua value (table, string, number, boolean, nil) to a JSON string. Not available in transient contexts. |
| `util.oidc_name_tombstoned` | `s` | True when a tombstoned `iam.OIDCProvider` still holds `name`. Lifecycle contexts only. |
| `util.role_has_channel` | `role_id, channel` | True when the named role's `connectivity` array carries the channel. Lifecycle contexts only. |
| `util.safe_webhook_url` | `s` | The host half of the webhook target rule: true when the URL's host resolves and every resolved address is public or on `webhook.allowed_hosts`; a host that does not resolve answers false. |
| `util.sha256` | `s` | SHA-256 hex digest. |
| `util.ulid` | `()` | Generates a ULID (26-char, Crockford Base32, time-sortable). |
| `util.valid_hostname` | `s` | True for a bare lowercase hostname — no scheme, port, path, or wildcard — at most 253 characters; the `app.App` `host` shape rule. |
| `util.valid_https_url` | `s` | Shape rule for the `iam.OIDCProvider` `issuer` field: an absolute https URL with a host. |
| `util.valid_issuer_url` | `s` | Shape rule for the `iam.OIDCProvider` `issuer` field (B-329): an absolute https URL, or plain `http` on a loopback host — the same scheme-follows-host carve-out as the redirect-URI rule (B-154). |
| `util.valid_origin` | `s` | Shape rule for one entry of the `app.App` `allowed_origins` field: a bare origin — `scheme://host[:port]` — with no path, userinfo, query, fragment, or wildcard. |
| `util.valid_redirect_uri` | `s` | Shape rule for one entry of the `app.App` `redirect_uris` field — the shared `Util::RedirectUri` rule (the single source of truth; `OAuth::RedirectUri` and the register endpoint use it too): absolute `https` on any host, or absolute `http` on a loopback host (`localhost`, any `*.localhost` subdomain, `127.0.0.1`, `::1`); no fragment, no userinfo, no query, host required. |
| `util.webhook_event_names` | `()` | The closed event-name vocabulary for the `core.Webhook` `events` field. |

## date

| Fonction | Signature | Rôle |
| --- | --- | --- |
| `date.add` | `iso, n, unit` | Adds `n` units; negative `n` subtracts. |
| `date.dateperiod_contains` | `p, x` | True when `x` falls inside a calendar-date range, inclusive on both ends. |
| `date.dateperiod_overlaps` | `a, b` | True when two calendar-date ranges — the `dateperiod` field shape, inclusive on both ends — share a day. |
| `date.diff` | `a, b, unit` | Signed distance from `a` to `b`. |
| `date.end_of` | `iso, unit` | Last day of the unit (dates) or last whole second (datetimes). |
| `date.now` | `()` | Returns the current UTC time as ISO 8601. |
| `date.parts` | `iso` | `{year, month, day, hour, minute, second, weekday}` in UTC; `weekday` is ISO-8601 (Monday = 1 … Sunday = 7); the time fields are zero for a calendar date. |
| `date.period_contains` | `p, x` | True when `x` falls inside a `[)` datetime range: start included, end excluded. |
| `date.period_overlaps` | `a, b` | True when two `[)` datetime ranges — the `period` field shape — share an instant. |
| `date.start_of` | `iso, unit` | First day or instant of the `unit` containing the value: `day`, `week` (Monday, ISO-8601), `month`, `quarter`, `year`. |
| `date.today` | `()` | Returns the current UTC calendar date, `YYYY-MM-DD`. |

## math

| Fonction | Signature | Rôle |
| --- | --- | --- |
| `math.clamp` | `x, min, max` | Clamp a number between min and max. |

## Voir aussi

- [Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/) — où s’exécutent create, update, delete et les actions.
- [Hooks d’événements](/fr/build/event-hooks/) — les hooks de domaine qui partagent cette surface.
- [Sidecars](/fr/build/sidecars/) — doctypes de pièces jointes gérés par le système, avec leurs propres hooks.
