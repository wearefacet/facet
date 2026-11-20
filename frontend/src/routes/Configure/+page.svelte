<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	// The configure landing redirects to the domain list. Keeping the
	// route explicit (rather than relying on SvelteKit's index fallthrough)
	// so a future landing page can replace the redirect without disturbing
	// the `/domains` subtree.
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import * as m from '$lib/paraglide/messages';

	onMount(() => {
		goto(resolve('/Configure/domains'), { replaceState: true });
	});
</script>

<svelte:head>
	<title>{m.configure_page_title()}</title>
</svelte:head>
