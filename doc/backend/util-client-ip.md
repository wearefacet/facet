# Util::ClientIp

**Files covered:** `src/util/client_ip.cr`

`Util::ClientIp` resolves the client IP of one HTTP request. It is the single input for the per-client counters and the telemetry attribute: the login throttle (`IAM::Routes` → `IAM::Login.call` `ip:`), the OAuth register/token rate limiters (`OAuth::Routes` → `OAuth::RateLimiter`), and the telemetry `http.client_ip` span attribute.

The resolver is pure — it reads the request headers and the socket remote address, plus the `trusted_proxies` list from config (see [`config.md`](config.md) → Trusted proxies and the client IP). It holds no state.

## The rule

The socket address is the only trusted fact. Everything else — the port and the `X-Forwarded-For` header — is untrusted input:

1. **The result is a bare host, never a port.** `Socket::IPAddress#to_s` renders `ip:port`, and the port changes per connection. A counter keyed on it can never grow — this was defect B-351. The resolver returns `Socket::IPAddress#address` (or a forwarded hop), so one address always maps to one counter key.
2. **`X-Forwarded-For` counts only behind a trusted proxy.** When the immediate peer is not on `trusted_proxies` — or the list is empty — the peer host is the result and the header is ignored. Any client can set the header to any value; the socket peer decides whether the server listens to it.
3. **A trusted peer walks the header right to left.** Trusted hops are skipped, and the first untrusted hop wins — the client address the nearest trusted proxy saw. Forged entries deeper in the chain never win, because a trusted proxy appends the true peer address at the right end.
4. **Sensible fallbacks.** No header, a blank header, or a chain with no untrusted hop (proxy-to-proxy traffic) falls back to the peer host — an all-trusted chain names no client, and naming no client beats naming an unverified one.

Comparison is case-insensitive and bracket-free: the peer host and every hop are lowercased, and a hop wrapped in brackets (a bracketed IPv6 literal) loses them. Repeated `X-Forwarded-For` headers comma-join into one chain. A hop that carries a port never matches an entry and passes through as the result.

## Public API

| Method | Returns | Description |
|---|---|---|
| `.resolve(headers, remote_address, trusted_proxies)` | `String?` | The client IP for one request. `headers` is the request's `HTTP::Headers`, `remote_address` the socket address (`HTTP::Request#remote_address`), `trusted_proxies` the config list. Returns `nil` when the request has no IP peer — no socket behind the request (in-process harness, HTTP/1.0), or a non-IP socket such as a Unix socket. Callers already treat `nil` as "no IP": the limiter fails open, the login throttle skips the per-IP counter, telemetry leaves the attribute unset. |

```crystal
ip = Util::ClientIp.resolve(
  env.request.headers,
  env.request.remote_address,
  Config.instance.trusted_proxies,
)
```

## Notes

- A nil result is a normal outcome, not an error. See the caller table above.
- The resolver reads only the correctly spelled `X-Forwarded-For` header. The misspelled `x-forward-for` form the telemetry middleware once read is gone — the shared resolver removed it.

Spec: `spec/util/client_ip_spec.cr`.
