# Util::Crypto — Constant-Time Comparison

**Files:** `src/util/crypto.cr`

`Facet::Util::Crypto` provides a constant-time string comparison for secret tokens: PKCE verifiers, bearer tokens, webhook signatures. It prevents timing oracles on the byte comparison.

## Public API

| Method | Returns | Description |
|---|---|---|
| `.constant_time_eq?(a, b)` | `Bool` | Compares both strings in constant time. Returns `false` early only when the lengths differ (unavoidable for an equality check). |

## Usage

```crystal
unless Util::Crypto.constant_time_eq?(expected, presented)
  return error_response(env, 401, "Invalid token")
end
```

One shared implementation replaces per-module private copies (`OAuth::Token`, `OAuth::Refresh`, `Artifact::Grants`, `MCP::Dispatch`, `HTTP::AuthHandler`).
