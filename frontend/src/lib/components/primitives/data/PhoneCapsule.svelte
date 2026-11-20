<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import CopyCapsule from './CopyCapsule.svelte';

	/**
	 * PhoneCapsule — copy-on-click capsule for a phone number.
	 * A named alias of the shared `CopyCapsule`; kept so existing call
	 * sites and stories keep working unchanged.
	 */

	let {
		phone,
		label,
		...rest
	}: {
		/** Phone number to display (also copied to clipboard). */
		phone: string;
		/** Optional display label. Falls back to `phone` when omitted. */
		label?: string;
	} = $props();
</script>

<CopyCapsule value={phone} {label} {...rest} />
