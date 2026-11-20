<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	// The access landing redirects to the roles list. Keeping the route
	// explicit (rather than relying on SvelteKit's index fallthrough) prevents
	// a bare `/Configure/access` from falling through to the catch-all
	// `[domain=notApi]/[doctype]` route — which would otherwise misread
	// `Configure` as a domain and `access` as a doctype and surface a 500
	// from the throw `Doctype Configure.access not found`.
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import * as m from '$lib/paraglide/messages';

	onMount(() => {
		goto(resolve('/Configure/access/roles'), { replaceState: true });
	});
</script>

<svelte:head>
	<title>{m.configure_access_page_title()}</title>
</svelte:head>
