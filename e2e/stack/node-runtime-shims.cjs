// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Stack-scoped Node runtime shims for the docker e2e stacks — loaded via
// `node --require` in the frontend and runner containers. Two fixes, both
// rooted in the pinned stack origin `https://facet.localhost:3443` (the dev
// vhost topology, harness §4):
//
// ── 1. TLS hostname verification for .localhost names ────────────────
//
// - Node ≥ 23 hardens hostname verification for RFC 6761 special-use
//   names: a wildcard cert is rejected for any `*.localhost` host
//   (checkServerIdentity fails with ERR_TLS_CERT_ALTNAME_INVALID), even
//   though the same match is accepted for normal domains. Browsers are
//   unaffected.
// - With the current Caddyfile the stock verifier already accepts every
//   stack origin — Caddy serves an exact certificate for facet.localhost,
//   and hosted apps ride the three-label `*.apps.localhost` wildcard,
//   which verifiers match normally. This preload stays as a no-op
//   backstop: it relaxes wildcard matching for `.localhost` names only,
//   so a future wildcard scheme does not silently break Node clients.
//
// The preload keeps full chain validation: the certificate must still be
// issued by the trusted Caddy root CA (NODE_EXTRA_CA_CERTS), and SANs
// must still match structurally.
//
// ── 2. SSR fetch scheme through vite preview ───────────────────────────
//
// `vite preview` builds the SSR request base from its own protocol, which
// is plain HTTP (`PROTOCOL_HEADER`/`HOST_HEADER` are adapter-node
// features — the preview middleware never reads them). SvelteKit therefore
// treats `http://facet.localhost:3443` as the origin, and its internal
// fetch fallback performs a native *plaintext* request to Caddy's TLS
// port, which answers `400 Client sent an HTTP request to an HTTPS
// server.` — every SSR `/Api/*` fetch failed with that 400. The fetch
// wrapper below upgrades exactly that origin to its https form before the
// request leaves the process, so SSR keeps riding Caddy over TLS.
//
// Both shims are loaded only inside the throwaway stack containers — never
// in dev or production.
'use strict';

// ── 1. TLS allowlist ─────────────────────────────────────────────────────

const tls = require('node:tls');

const originalCheckServerIdentity = tls.checkServerIdentity;

tls.checkServerIdentity = function patchedCheckServerIdentity(hostname, cert) {
	// Try the stock verifier first: everything it accepts stays accepted.
	const failure = originalCheckServerIdentity.call(tls, hostname, cert);
	if (!failure) return undefined;

	// Relax only the RFC 6761 case: `<label>.localhost` against a two-label
	// wildcard `*.localhost` SAN. Structural label shape still applies
	// (single leftmost label, no dots inside), and chain trust was already
	// enforced before this callback runs. The current Caddyfile never
	// presents such a SAN — this branch exists as the backstop for a
	// future two-label wildcard scheme.
	const host = String(hostname).replace(/\.$/, '').toLowerCase();
	const sans = (cert && cert.subjectaltname) || '';
	const dnsNames = sans
		.split(/,\s*/)
		.filter((entry) => entry.startsWith('DNS:'))
		.map((entry) => entry.slice(4).toLowerCase());
	const isLocalhostName = /^[a-z0-9-]+\.localhost$/.test(host);
	const hasLocalhostWildcard = dnsNames.some((san) => san === '*.localhost');
	const hasExactMatch = dnsNames.some((san) => san === host);

	if (isLocalhostName && hasLocalhostWildcard && !hasExactMatch) {
		return undefined;
	}

	return failure;
};

// ── 2. SSR fetch scheme upgrade ──────────────────────────────────────────

const SSR_KERNEL_ORIGIN = 'http://facet.localhost:3443';
const SSR_KERNEL_ORIGIN_HTTPS = 'https://facet.localhost:3443';

const rawFetch = globalThis.fetch;

globalThis.fetch = async function stackFetch(input, init) {
	const url =
		typeof input === 'string'
			? input
			: input instanceof URL
				? input.href
				: input instanceof Request
					? input.url
					: String(input);

	if (!url.startsWith(SSR_KERNEL_ORIGIN)) {
		return rawFetch.call(this, input, init);
	}

	if (input instanceof Request) {
		// Rebuild the request against the https origin. Streamed bodies need
		// buffering (the same trade-off the app's dev `rewriteToBackend`
		// makes: the SSR pipeline sends JSON bodies, never uploads).
		const method = input.method.toUpperCase();
		const body = method === 'GET' || method === 'HEAD' ? undefined : await input.arrayBuffer();
		const upgraded = new Request(
			url.replace(SSR_KERNEL_ORIGIN, SSR_KERNEL_ORIGIN_HTTPS),
			{
				method,
				headers: input.headers,
				body,
				redirect: input.redirect,
				signal: input.signal
			}
		);
		return rawFetch.call(this, upgraded);
	}

	return rawFetch.call(this, url.replace(SSR_KERNEL_ORIGIN, SSR_KERNEL_ORIGIN_HTTPS), init);
};
