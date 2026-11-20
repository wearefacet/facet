// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for the MCP endpoint directory.
//
// Backend: `src/mcp/routes.cr` —
//   GET /Api/_mcp/endpoints   the caller's held-role MCP endpoint URLs
//
// The URLs come from the backend (`MCP.resource_identifier`) — the exact
// string MCP dispatch compares the token `aud` against. The browser must
// not derive them from `window.location.origin`: a non-Caddy origin would
// mint links whose `aud` fails the exact-match check.

import { apiFetch } from '$lib/session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';

export interface McpEndpoint {
	/** Qualified role id (`iam.Roles.editor`). */
	role: string;
	/** Absolute MCP resource URL for the role (equals the token `aud`). */
	url: string;
}

type FetchFn = typeof fetch;

export async function listMcpEndpoints(fetchFn?: FetchFn): Promise<McpEndpoint[]> {
	const res = await apiFetch('/Api/_mcp/endpoints', {}, { fetch: fetchFn });
	if (!res.ok) throw await apiErrorMessage(res, m.errors_mcp_load());
	const body = (await res.json()) as { endpoints?: McpEndpoint[] };
	return body.endpoints ?? [];
}
