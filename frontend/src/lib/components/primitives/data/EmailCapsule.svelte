<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import CopyCapsule from './CopyCapsule.svelte';

	/**
	 * EmailCapsule — copy-on-click capsule for an email address.
	 * A named alias of the shared `CopyCapsule`; kept so existing call
	 * sites and stories keep working unchanged.
	 */

	let {
		email,
		label,
		...rest
	}: {
		/** Email address to display (also copied to clipboard). */
		email: string;
		/** Optional display label. Falls back to `email` when omitted. */
		label?: string;
	} = $props();
</script>

<CopyCapsule value={email} {label} {...rest} />
