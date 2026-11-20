<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { ServerCrash } from '@lucide/svelte';
	import Button from '../actions/Button.svelte';

	let {
		error = null,
		level = 'page',
		onretry
	}: {
		/** The caught error. Its message renders as the detail line. */
		error?: unknown;
		/** `page` fills the route surface; `app` covers the whole viewport. */
		level?: 'page' | 'app';
		/** Pressed by Retry — the caller remounts the failed boundary. */
		onretry?: () => void;
	} = $props();

	const message = $derived.by(() => {
		if (error instanceof Error) return error.message;
		if (typeof error === 'string') return error;
		// Hydration-mismatch errors and DOMExceptions carry their detail on the
		// prototype, not in own enumerable props — stringify exposes it where
		// the previous `instanceof Error` check rendered a blank detail line.
		if (error !== null && typeof error === 'object') {
			const e = error as { name?: unknown; message?: unknown };
			const name = typeof e.name === 'string' ? e.name : '';
			const msg = typeof e.message === 'string' ? e.message : '';
			if (name || msg) return [name, msg].filter(Boolean).join(': ');
			try {
				const json = JSON.stringify(error);
				if (json && json !== '{}') return json;
			} catch {
				/* cyclic — fall through */
			}
		}
		return '';
	});
</script>

<div class="ef" class:ef-app={level === 'app'}>
	<div class="ef-illus" aria-hidden="true">
		<ServerCrash size={120} strokeWidth={1.5} />
	</div>
	<h1 class="ef-title">{m.errors_500_title()}</h1>
	{#if message}
		<p class="ef-message">{message}</p>
	{/if}
	<div class="ef-actions">
		<Button variant="primary" size="md" onclick={() => onretry?.()}>{m.common_retry()}</Button>
		<Button variant="secondary" size="md" href="/">{m.common_back_to_dashboard()}</Button>
	</div>
</div>

<style>
	.ef {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		text-align: center;
		gap: 10px;
		padding: 48px 24px;
		min-height: 100%;
		width: 100%;
		max-width: 560px;
		margin: 0 auto;
	}

	.ef-app {
		min-height: 100vh;
	}

	.ef-illus {
		color: var(--accent-ink);
		margin-bottom: 6px;
	}

	.ef-title {
		font-family: var(--font-sans);
		font-size: 18px;
		font-weight: 600;
		margin: 0;
		color: var(--text-2);
	}

	.ef-message {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text-3);
		word-break: break-word;
		max-width: 440px;
	}

	.ef-actions {
		margin-top: 14px;
		display: flex;
		gap: 10px;
	}
</style>
