<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { X } from '@lucide/svelte';
	import { getToasts, dismissToast } from '$lib/toast.svelte';

	/**
	 * ToastHost — the single global surface that backs `toast()` from
	 * `$lib/toast.svelte`. Mounted once in the root layout; renders a
	 * bottom-center stack of transient messages with optional link actions.
	 */
	const toasts = $derived(getToasts());
</script>

{#if toasts.length > 0}
	<div class="toast-stack" role="status" aria-live="polite">
		{#each toasts as t (t.id)}
			<div class="toast" class:toast-error={t.variant === 'error'}>
				<span class="toast-message">{t.message}</span>
				{#if t.action}
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- the action href is built by the toast producer (e.g. an export download URL on the backend); the rule cannot see the model. -->
					<a class="toast-action" href={t.action.href}>{t.action.label}</a>
				{/if}
				<button
					class="toast-close"
					type="button"
					aria-label={m.common_close()}
					onclick={() => dismissToast(t.id)}
				>
					<X size={13} stroke-width={2} aria-hidden="true" />
				</button>
			</div>
		{/each}
	</div>
{/if}

<style>
	.toast-stack {
		position: fixed;
		bottom: 20px;
		left: 50%;
		transform: translateX(-50%);
		display: flex;
		flex-direction: column;
		gap: 8px;
		z-index: 1200;
		max-width: min(380px, calc(100vw - 40px));
		/* Bottom-center clears the interactive control strips: the table
		   footer's rows-per-page and pagination sit bottom-right, the sidebar
		   footer sits bottom-left. Above the app's floating layer (dropdown
		   portals at 1100, editor panels at 1001) so a toast never hides
		   behind a surface; it auto-dismisses, so it stays transient. */
		/* The stack box itself never intercepts clicks — only each toast does. */
		pointer-events: none;
	}

	.toast {
		display: flex;
		align-items: center;
		gap: 10px;
		background: var(--surface);
		border: 1px solid var(--border-strong);
		border-left: 3px solid var(--accent);
		border-radius: var(--r);
		box-shadow: var(--sh-2);
		padding: 10px 12px;
		font-size: 13px;
		color: var(--text);
		/* Re-enable interaction on the toast box only. */
		pointer-events: auto;
	}

	.toast-error {
		border-left-color: var(--danger);
	}

	.toast-message {
		flex: 1;
		min-width: 0;
	}

	.toast-action {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 600;
		color: var(--accent-ink);
		text-decoration: none;
		white-space: nowrap;
	}

	.toast-action:hover {
		text-decoration: underline;
	}

	.toast-action:focus-visible,
	.toast-close:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.toast-close {
		display: grid;
		place-items: center;
		width: 22px;
		height: 22px;
		border: none;
		border-radius: var(--r-sm);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	.toast-close:hover {
		background: var(--sunken);
		color: var(--text);
	}
</style>
