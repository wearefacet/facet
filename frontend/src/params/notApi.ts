// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * SvelteKit param matcher that admits only valid Facet domain segments.
 *
 * ## Why this exists
 *
 * The dynamic routes under `src/routes/[domain=notApi]/...` live at the root
 * of the URL space. They must not shadow the static application routes
 * (`/Configure`, `/Builder`, `/Login`, ...).
 *
 * ## The casing invariant
 *
 * A lowercase first segment is a domain id; an uppercase first segment is an
 * application or infrastructure route. Facet domain names are system-defined
 * and always lowercase. The backend enforces this at the model layer
 * (`Facet::Document::DocURI::DOMAIN_RE = /^_?[a-z0-9][a-z0-9\-]*$/`): a
 * registered domain may start with `_` (drafts) or a lowercase letter, then
 * continues with lowercase letters, digits, or dashes. Capitalized segments —
 * `Configure`, `Builder`, `Login`, `Api`, `OAuth` — can never be real
 * domains, so they cannot match this route.
 *
 * Encoding the rule at the routing layer means static application routes
 * (which by convention use Capitalized first segments) are guaranteed to
 * win the route resolution, even when their `+page.svelte` is missing. A
 * bare `/Configure/access` with no index falls through to no dynamic route
 * — SvelteKit returns its own 404 instead of misreading the path as a
 * `{domain}.{doctype}` lookup and surfacing a confusing 500.
 *
 * The backend namespaces follow the same invariant: `/Api` (REST + MCP),
 * `/OAuth` (authorization), `/A` (artifact streaming), `/Ws` (WebSocket),
 * `/Healthcheck`, `/Edge` — no reserved-domain-id list exists. `.well-known`
 * paths are the one exception (a dot cannot start a domain).
 *
 * See https://svelte.dev/docs/kit/advanced-routing#Matching.
 *
 * @param param The URL segment to test.
 * @returns `true` if the segment is a valid Facet domain name.
 */
export const match = (param: string): boolean => DOMAIN_RE.test(param);

const DOMAIN_RE = /^_?[a-z0-9][a-z0-9-]*$/;
