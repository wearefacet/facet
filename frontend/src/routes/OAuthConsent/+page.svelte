<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { untrack } from 'svelte';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import ConsentScreen from '$lib/components/features/auth/ConsentScreen.svelte';
	import { apiFetch } from '$lib/session.svelte';
	import type { ConsentError, IssuedCode } from '$lib/components/features/auth/oauthTypes';

	let { data } = $props();

	let loading = $state(false);
	let submitError = $state<ConsentError | null>(null);

	// The backend's authorize POST returns the redirect target + code. Follow
	// it so the OAuth client receives the code (and the browser leaves the
	// consent surface). The `state` param round-trips through the redirect.
	// `iss` (RFC 9207) travels with it — clients like opencode reject the
	// response when the parameter is missing.
	function followIssued(issued: IssuedCode) {
		const url = new URL(issued.redirect_uri);
		url.searchParams.set('code', issued.code);
		if (issued.state) url.searchParams.set('state', issued.state);
		url.searchParams.set('iss', issued.iss);
		window.location.assign(url.toString());
	}

	async function handleConsent(choice: { role_id: string }) {
		loading = true;
		submitError = null;
		try {
			const query = page.url.searchParams.toString();
			const target = query ? `/OAuth/authorize?${query}` : '/OAuth/authorize';
			// untrack: a tracked set on the params would couple the submit handler's
			// effect context to this scratch object.
			const params = untrack(() => new SvelteURLSearchParams(query));
			untrack(() => params.set('role', choice.role_id));

			const res = await apiFetch(target, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/x-www-form-urlencoded',
					Accept: 'application/json'
				},
				body: params.toString()
			});

			const body = await res.json();
			if (!res.ok) {
				submitError = body as ConsentError;
				return;
			}
			if (body?.error === 'access_denied') {
				submitError = body as ConsentError;
				return;
			}
			followIssued(body as IssuedCode);
		} catch (err) {
			submitError = {
				error: 'invalid_request',
				error_description: (err as Error).message || m.apps_request_failed()
			};
		} finally {
			loading = false;
		}
	}

	// Cancel / back-to-sign-in: return the user to the app home. There is no
	// safe redirect target for a denied consent — the OAuth client only learns
	// of a denial through a redirect carrying `error=access_denied`, which the
	// backend does not emit on the GET path.
	function handleCancel() {
		goto(resolve('/'));
	}
</script>

<svelte:head>
	<title>{m.apps_page_title()}</title>
</svelte:head>

<ConsentScreen
	consent={data.consent}
	mcp={data.mcp}
	error={submitError ?? data.error}
	{loading}
	redirectUri={data.mcp?.redirect_origin ??
		// The presented `redirect_uri` — the backend preserved the authorize
		// query in its bounce, and it validated this value against the
		// registered list before rendering consent. Show what will actually
		// receive the code, not the first registered entry.
		page.url.searchParams.get('redirect_uri') ??
		data.consent?.app.redirect_uris[0]}
	preselectedRoleId={data.mcp?.pinned_role ?? undefined}
	onconsent={handleConsent}
	oncancel={handleCancel}
	onretry={() =>
		goto(resolve(`/OAuthConsent?${page.url.searchParams.toString()}`), { invalidateAll: true })}
/>
