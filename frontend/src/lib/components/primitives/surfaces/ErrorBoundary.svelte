<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack, type Snippet } from 'svelte';
	import { page } from '$app/state';
	import ErrorFallback from './ErrorFallback.svelte';

	let {
		children,
		level = 'page'
	}: {
		children?: Snippet;
		/** `page` guards one route surface; `app` is the last-resort wrapper for the shell. */
		level?: 'page' | 'app';
	} = $props();

	let failed = $state(false);
	let lastError: unknown = $state(null);

	let currentUrl = '';

	/**
	 * Svelte's internal hydration-failure sentinel (`HYDRATION_ERROR`) is a
	 * bare `{}` — no message, no name, no own properties. It cannot be
	 * imported (it is module-private), so it is recognised structurally. A
	 * password-manager extension that decorates a credential form while
	 * hydration is still walking the SSR HTML produces exactly this error:
	 * the extension injects a node into an input wrapper, Svelte logs
	 * `hydration_mismatch` and throws the sentinel, and without the recovery
	 * below the page renders the fallback card even though the failure is
	 * recoverable — Svelte itself auto-recovers the same way when no
	 * boundary exists: it drops the server DOM and re-mounts client-side.
	 */
	function isHydrationSentinel(error: unknown): boolean {
		return (
			error !== null &&
			typeof error === 'object' &&
			Object.getPrototypeOf(error) === Object.prototype &&
			Object.keys(error).length === 0
		);
	}

	// The sentinel recovery is one-shot per boundary instance. A client
	// render cannot trip hydration again, so a second sentinel here means a
	// real bug throwing a bare object — show the fallback instead of
	// spinning through reset cycles.
	let hydrationRecovered = false;

	// A failed boundary never re-renders its content on its own — not even
	// after a navigation. This effect tracks the URL only; the `failed` read
	// stays untracked, else the effect would clear the fallback the moment it
	// appears. A URL change means the user moved on: drop the fallback and
	// mount a fresh boundary around the new page. The shell outside this
	// boundary is alive, so one click on a sidebar link recovers.
	$effect(() => {
		const href = page.url.href;
		const navigated = currentUrl !== '' && href !== currentUrl;
		currentUrl = href;
		untrack(() => {
			if (navigated && failed) {
				failed = false;
				lastError = null;
			}
		});
	});
</script>

{#if failed}
	<ErrorFallback error={lastError} {level} onretry={() => (failed = false)} />
{:else}
	<!-- No `failed` snippet on purpose: the server boundary then re-throws, so
		SSR errors still reach SvelteKit and render the usual error page. Only
		client render/effect errors land in the fallback. -->
	<svelte:boundary
		onerror={(error, reset) => {
			if (isHydrationSentinel(error) && !hydrationRecovered) {
				hydrationRecovered = true;
				// Hydration walked into DOM an extension injected after the
				// SSR HTML painted. Recover the way Svelte does without a
				// boundary: drop the server-rendered subtree and re-render
				// the content client-side. `reset` must not run inside
				// `onerror` (svelte_boundary_reset_onerror), and deferring
				// also lets the root hydration unwind first, so the
				// re-render is a plain client render, not another claim
				// pass over the (already removed) server nodes.
				console.warn(
					`[ui-hydration:${level}] hydration mismatch (browser extension DOM injection?) — recovering with a client render`
				);
				setTimeout(reset, 0);
				return;
			}
			console.error(`[ui-crash:${level}]`, error);
			lastError = error;
			failed = true;
		}}
	>
		{@render children?.()}
	</svelte:boundary>
{/if}
