// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import * as m from '$lib/paraglide/messages';
import { apiFetch } from '$lib/session.svelte';
import type {
	ConsentError,
	ConsentScreen,
	MCPScreen
} from '$lib/components/features/auth/oauthTypes';

/**
 * OAuth consent page load.
 *
 * The backend redirects a browser navigation to `/OAuthConsent?<authorize
 * params>`. This load re-fetches `GET /OAuth/authorize` with the same
 * query, asking for JSON (not HTML), so the backend returns the consent
 * payload instead of bouncing us back here. The response is either an app
 * consent screen, an MCP consent screen (when the request carries an RFC 8707
 * `resource`), or a structural error.
 */
export const load: PageLoad = async ({ url, fetch }) => {
	const query = url.searchParams.toString();
	const target = query ? `/OAuth/authorize?${query}` : '/OAuth/authorize';

	const res = await apiFetch(
		target,
		{ headers: { Accept: 'application/json' } },
		{ fetch, redirectOnFailure: false }
	);

	if (!res.ok) {
		let error: ConsentError = {
			error: 'invalid_request',
			error_description: m.apps_request_failed_status({ status: res.status })
		};
		try {
			const body = await res.json();
			if (body?.error) error = body as ConsentError;
		} catch {
			/* non-JSON error body — keep the fallback */
		}
		return { consent: null, mcp: null, error, state: null };
	}

	const body = await res.json();
	if (body?.mcp === true) {
		return { consent: null, mcp: body as MCPScreen, error: null, state: body.state ?? null };
	}
	return { consent: body as ConsentScreen, mcp: null, error: null, state: body.state ?? null };
};
