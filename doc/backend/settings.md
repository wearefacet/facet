# Account Settings

Account Settings store per-account, per-application preference state (timezone,
language, future notification preferences) in the `account_settings` table.
Settings are **not** event-sourced: a preference change is not an auditable
business event. This mirrors the `secrets` / `auth_state` storage split in
the IAM subsystem — non-event-sourced per-account PostgreSQL tables that live
outside the doctype system.

**Not to be confused with system settings** (`core.SystemSettings`) — the
instance-level platform configuration (assistant connection, mail connector).
Those are event-sourced system documents: an admin change is an auditable
business event, hot-reloaded across processes. The split is by scope, not by
mechanism preference — per-user churn never touches the document pipeline,
while instance-level admin changes deliberately do. See
[`system-settings.md`](system-settings.md).

## Source Files

| File | Role |
|---|---|
| `src/settings.cr` | Namespace root — declares `Facet::Settings` and the `CORE_APP` sentinel (`"core"`) |
| `src/settings/keys.cr` | `Keys` registry + per-key validation (`Kind` enum, `Descriptor` record) |
| `src/settings/service.cr` | `Service.get` / `get_value` / `update` — read and upsert preference rows |
| `src/settings/routes.cr` | `Routes.register` — HTTP routes under `/Api/settings` |
| `db/migrations/0007_account_settings.sql` | `account_settings` table + DOWN |
| `src/iam/helpers.cr` | JWT-claim extraction (`extract_account_id`, `extract_role`, `extract_expires_at`, `decode_jwt_claim`) shared with IAM routes |
| `src/iam/routes.cr` | `/Api/iam/me` includes a `settings` block (core app values) in its response |

## Storage

```sql
CREATE TABLE account_settings (
  account_id      text    NOT NULL,
  app          text    NOT NULL,
  key          text    NOT NULL,
  value        jsonb   NOT NULL,
  updated_at   timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, app, key)
);
```

Rows are keyed by `(account_id, app, key)`:

- `account_id` is the account id (matches the `iam.Account` projection id).
- `app` is the application scope. `core` is the default/general scope. Applications are a future concept; `app` is a free string now and gains a foreign key when applications become first-class.
- `key` is the preference name (`timezone`, `language`, …).
- `value` is a typed JSON value — `kind` is enforced in Crystal by `Keys`.

`account_id` carries no foreign key: account deletion does not cascade here — orphaned preference rows are cleaned up by the callers that remove accounts (the dev-seed reset path deletes them explicitly).

## Key registry

The allowed `(app, key)` pairs and their value kinds are declared in
`Settings::Keys::REGISTRY`. Adding a preference is a one-line change:

```crystal
REGISTRY = {
  {"core", "timezone"}                => Descriptor.new("core", "timezone", Kind::String, JSON::Any.new("auto")),
  {"core", "language"}                => Descriptor.new("core", "language", Kind::String, JSON::Any.new("en")),
  {"core", "pinned_doctypes"}         => Descriptor.new("core", "pinned_doctypes", Kind::Array, JSON::Any.new([] of JSON::Any)),
  {"core", "pinned_collection_views"} => Descriptor.new("core", "pinned_collection_views", Kind::Array, JSON::Any.new([] of JSON::Any)),
  {"core", "show_welcome"}            => Descriptor.new("core", "show_welcome", Kind::Bool, JSON::Any.new(true)),
  {"notifications", "in_app"}         => Descriptor.new("notifications", "in_app", Kind::Bool, JSON::Any.new(true)),
} of {String, String} => Descriptor
```

`Service.update` rejects unregistered pairs with HTTP 422 — the table cannot
become an unvalidated dumping ground. Per-key value validation is in
`Keys.validate`:

| (app, key) | Kind | Validation |
|---|---|---|
| `core.timezone` | String | `auto` (follow the browser — `Keys::AUTO_TIMEZONE`) stored verbatim, or a loadable IANA timezone via `Time::Location.load`. `UTC` is always valid. |
| `core.language` | String | Must be in `Keys::ALLOWED_LANGUAGES`. Today: `{"en", "fr"}`. |
| `core.pinned_doctypes` | Array | JSON array of qualified doctype names (`domain.Doctype`). Each element must be a string in `domain.Doctype` form. |
| `core.pinned_collection_views` | Array | JSON array of pinned CollectionView projection ids (ULIDs). Each element must be a non-empty string. |
| `core.show_welcome` | Bool | Kind check only — the value must be a boolean. |
| `notifications.in_app` | Bool | Kind check only — the value must be a boolean. |

The `notifications` scope holds the in-app notification preference
(`notifications.in_app`, default `true`). The frontend gates the bell, the
badge poll, and the WebSocket subscription on it — see
[`frontend/notifications.md`](../frontend/notifications.md) → Preference gate.
The gate is presentation-only: `Notification::Send` inserts unconditionally,
so re-enabling shows the notifications accrued while muted. The other channel
keys (`notifications.email`, a digest) stay unregistered until their delivery
subsystems exist — a key with no consumer would be a control that lies.

The `core.show_welcome` flag (default `true`) gates the first-run welcome
tour: the tour's dismiss checkbox and final CTAs write `false`, and the
Settings page writes `true` to replay it. It is per account — one admin's
dismissal never silences another admin's tour. See
[`frontend/settings.md`](../frontend/settings.md) → Welcome tour.

## Public API

```crystal
# Read all registered settings for one application scope.
# Missing keys resolve through the default chain: the server default
# (the effective core.SystemSettings value at the mapped path) when the
# key has one, else the registered default.
Service.get(db, account_id, app = "core") : Hash(String, JSON::Any)

# The server-effective default per registered key (no account rows read).
# The settings page renders these as the "Server default ({value})" label.
Service.defaults(db, app = "core") : Hash(String, JSON::Any)

# Read a single key. Returns {value, updated_at?}; a missing row resolves
# through the same default chain. nil for an unregistered key.
Service.get_value(db, account_id, app, key) : {JSON::Any, Time?}?

# Upsert a single key. Validates against the registry first.
# Returns the persisted {value, updated_at} or a ServiceError (422).
Service.update(db, account_id, app, key, value : JSON::Any) : {JSON::Any, Time} | Facet::ServiceError

# Remove the account's row so the server default applies again.
# Idempotent. Returns the number of rows deleted.
Service.clear(db, account_id, app, key) : Int64
```

**The default chain.** `Keys::SERVER_DEFAULTS` maps an account key to the
`core.SystemSettings` path whose effective value is the server tier:
`core.timezone` → `localization.default_timezone`, `core.language` →
`localization.default_language`. The chain per key is: the account's row →
the server default (document pin → config file → built-in default, the
system-settings resolution) → the static registry default. Keys with no
mapping (the pinned lists, the notification preference) keep their
registry default. `/Api/iam/me` inherits the chain — its `settings` block
resolves through `Service.get`.

The built-in timezone default at every tier is `auto`
(`Keys::AUTO_TIMEZONE`): an account with no row on a stock install follows
its browser zone. The frontend resolves the sentinel at render time — the
server never knows the caller's zone and never converts with it. An admin
who wants "everyone on one zone unless they choose" pins
`localization.default_timezone` to a concrete IANA name (Configure →
Platform → Settings); the write gate accepts `auto` or a loadable name.

## HTTP Routes

All routes are under `/Api/settings`. They are self-service: the
authenticated user manages their own settings only, keyed off the `sub`
claim of the access token (no RBAC enforcer — the account only ever touches
rows where `account_id` matches, enforced in the SQL `WHERE account_id = $1`).

| Method | Path | Handler | Auth |
|---|---|---|---|
| `GET` | `/Api/settings` | inline → `Service.get(db, account_id, "core")` | `AuthHandler` (401 if no valid token) |
| `GET` | `/Api/settings/:app` | inline → `Service.get` + `Service.defaults` | same |
| `GET` | `/Api/settings/:app/:key` | inline → `Service.get_value` | same; 404 for unregistered key |
| `PUT` | `/Api/settings/:app/:key` | inline → `Service.update` | same + `X-Requested-With` header for a cookie session (CSRF defense, mirroring IAM); a `Bearer`/`DPoP` credential without the session cookie is exempt |
| `DELETE` | `/Api/settings/:app/:key` | inline → `Service.clear` | same + CSRF header; `204`, idempotent; 404 for an unregistered key |

### Response shapes

`GET /Api/settings/core`:
```json
{
  "app": "core",
  "values": { "timezone": "Europe/Paris", "language": "en" },
  "defaults": { "timezone": "auto", "language": "en" }
}
```

The `defaults` block carries each registered key's server-effective
default — what an account with no row resolves to. The personal settings
page renders it as the first "Server default ({value})" option; selecting
it calls the DELETE route and reloads.

`GET /Api/settings/core/timezone` (persisted):
```json
{ "app": "core", "key": "timezone", "value": "Europe/Paris", "updated_at": "2026-08-01T12:00:00Z" }
```

`GET /Api/settings/core/timezone` (default, never written):
```json
{ "app": "core", "key": "timezone", "value": "auto" }
```

`PUT /Api/settings/core/timezone` body:
```json
{ "value": "Europe/Paris" }
```

`updated_at` is serialized as UTC RFC-3339 (the storage contract —
`timestamp` columns are tz-naive UTC; the PG session `TimeZone` is pinned
to `UTC` in `Database.init`).

## `/Api/iam/me` integration

The `/me` response carries a `settings` block holding the **`core`**
application values so the frontend gets timezone and language in the single
initial load it already performs:

```json
{
  "account": { "id", "email", "display_name" },
  "active_role", "expires_at", "permissions", "scopes",
  "settings": { "timezone": "Europe/Paris", "language": "en" }
}
```

This is an additive change; existing consumers ignore the new key.

## Authentication

Routes use `Facet::IAM::Helpers.extract_account_id(env)`, which reads the
`auth_token` cookie (or the `Authorization: Bearer …` header) and decodes
the JWT `sub` claim. In test mode (`AuthHandler.enabled? == false`), specs
inject a signed test JWT cookie — see `spec/settings/routes_spec.cr`.

Every `/Api/settings` route resolves the caller from this JWT `sub` claim —
the session/JWT channel only. A static `fct_` API key carries no JWT, so
`require_account` finds no `sub` claim and answers `401` on these routes
(`src/http/gates.cr` → `require_account`). The contrast is deliberate:
`/Api/iam/me` answers on both channels by design — a session caller and a
key caller both get a profile (`src/iam/routes.cr`, `handle_me`).

## Design decisions

- **Dedicated table, not `iam.Account` fields.** Settings churn would
  pollute the mutation log and audit trail, and would couple preference
  writes to RBAC `update` on `iam.Account`. Preferences are not auditable
  business events.
- **`app` is a free string, not a foreign key.** Applications do not exist
  yet. The registry enforces that only registered `(app, key)` pairs are
  writable, so the column cannot be abused today. When applications become
  first-class, a migration adds the FK if needed.
- **`core` is the default/general scope, not `null`.** A concrete sentinel
  is queryable and indexable, and avoids NULL-in-composite-key surprises.
- **`value` is JSONB.** Preferences are heterogeneous: `timezone` is a
  string, future `notifications.email` would be a boolean, future calendar
  preferences might be objects. A single typed column cannot serve this;
  per-key validation in Crystal is the right layering.
- **No batch multi-key writes.** One key per PUT. If the settings UI needs
  atomic multi-key save, a `PUT /Api/settings/:app` batch endpoint can be
  added later within a single transaction.
- **Settings are self-service, not RBAC-gated.** An account only ever touches
  their own rows. The SQL `WHERE account_id = $1` is the isolation boundary —
  the RBAC enforcers exist for the document subsystem and are not invoked
  here.
