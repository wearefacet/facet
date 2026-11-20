<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	LoginAttemptsWarning — the inline "N attempts remaining" warning of the
	password login form (B-139, parity with the MFA challenge path). Rendered
	by the login page under the credential fields when the backend's 401
	carries the brute-force counter.
-->
<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	let { attempts }: { attempts: number } = $props();
</script>

<div class="warn-msg" role="alert">
	{m.auth_login_attempts_remaining({ attempts })}
</div>

<style>
	.warn-msg {
		/* Own surface background — the warning also sits on the auth shell's
		 * tinted ground when shown outside the white card (stories, reuse),
		 * and --warn on a bare ground tint misses AA contrast by a hair. */
		background: var(--surface);
		font-size: 12.5px;
		color: var(--warn);
		border: 1px solid var(--warn);
		border-radius: var(--r-sm);
		padding: 8px 10px;
	}
</style>
