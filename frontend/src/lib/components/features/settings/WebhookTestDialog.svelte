<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { testWebhook, type WebhookTestResult } from '$lib/webhooks/webhooks.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * WebhookTestDialog — runs the test action (`POST .../test`) when the
	 * dialog opens and renders the receiver's response as data. The backend
	 * answers 200 regardless of the receiver's status — a receiver 401 is a
	 * result, not an error — so the outcome block always shows what came
	 * back: HTTP status (or the transport error), duration, and the response
	 * body snippet. Only a Facet-side rejection (422: disabled, missing
	 * transport, insecure URL) surfaces as a dialog error.
	 *
	 * The fetch surface is injectable so stories drive the outcome.
	 */

	let {
		/** Two-way bindable open state — opening runs the test. */
		open = $bindable(false),
		webhookId,
		/** Called after the dialog closes, so a host can drop its selection. */
		onclose = () => {},
		testFn = testWebhook
	}: {
		open?: boolean;
		webhookId: string;
		onclose?: () => void;
		testFn?: typeof testWebhook;
	} = $props();

	let result = $state<WebhookTestResult | null>(null);
	let running = $state(false);
	let runError = $state<string | undefined>(undefined);

	// Run once per open transition. The effect reads `open` only, so a
	// result write cannot re-trigger it.
	$effect(() => {
		if (!open) return;
		void run();
	});

	async function run() {
		running = true;
		runError = undefined;
		result = null;
		try {
			result = await testFn(webhookId);
		} catch (e) {
			runError = errorMessage(e, m.webhooks_test_error());
		} finally {
			running = false;
		}
	}

	function statusLabel(r: WebhookTestResult): string {
		if (r.transport_error) return m.webhooks_test_transport_label();
		return String(r.http_status ?? '—');
	}

	function durationLabel(r: WebhookTestResult): string {
		if (r.duration_ms === null) return '—';
		if (r.duration_ms < 1000) return `${r.duration_ms} ms`;
		return `${(r.duration_ms / 1000).toFixed(1)} s`;
	}
</script>

<Dialog.Root
	bind:open
	onOpenChange={(v) => {
		if (!v) onclose();
	}}
>
	<Dialog.Portal>
		<Dialog.Overlay class="test-dlg-overlay" />
		<Dialog.Content class="test-dlg-content">
			<Dialog.Title class="test-dlg-title">{m.webhooks_test_title()}</Dialog.Title>
			<Dialog.Description class="test-dlg-desc">{m.webhooks_test_helper()}</Dialog.Description>

			{#if running}
				<p class="muted" role="status">{m.webhooks_test_running()}</p>
			{:else if runError}
				<p class="alert" role="alert">{runError}</p>
			{:else if result}
				<div
					class="outcome"
					class:failed={result.transport_error !== null ||
						(result.http_status !== null && result.http_status >= 400)}
				>
					<span class="outcome-status">{statusLabel(result)}</span>
					<span class="outcome-duration">{durationLabel(result)}</span>
				</div>
				{#if result.transport_error}
					<div class="block">
						<span class="block-label">{m.webhooks_test_transport_label()}</span>
						<pre class="response">{result.transport_error}</pre>
					</div>
				{/if}
				{#if result.response_body}
					<div class="block">
						<span class="block-label">{m.webhooks_test_response_label()}</span>
						<pre class="response">{result.response_body}</pre>
					</div>
				{/if}
				<div class="block">
					<span class="block-label">{m.webhooks_test_signed_label()}</span>
					<pre class="response signed">{result.signed_body}</pre>
				</div>
				<button class="rerun-btn" type="button" onclick={run}>{m.webhooks_test_rerun()}</button>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.test-dlg-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.test-dlg-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(560px, 92vw);
		max-height: 86vh;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
	}

	:global(.test-dlg-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
		display: flex;
		align-items: center;
		gap: 8px;
	}

	:global(.test-dlg-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.outcome {
		display: flex;
		align-items: baseline;
		gap: 12px;
		padding: 10px 14px;
		border-radius: var(--r);
		background: var(--ok-weak);
	}

	.outcome.failed {
		background: var(--danger-weak);
	}

	.outcome-status {
		font-family: var(--font-mono);
		font-size: 16px;
		font-weight: 700;
		color: var(--text);
	}

	.outcome-duration {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}

	.block {
		display: flex;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}

	.block-label {
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.response {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 11.5px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 8px 10px;
		white-space: pre-wrap;
		word-break: break-word;
		max-height: 160px;
		overflow-y: auto;
	}

	.response.signed {
		max-height: 220px;
	}

	.rerun-btn {
		align-self: flex-start;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 6px 12px;
		border-radius: var(--r);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text-2);
	}

	.rerun-btn:hover {
		border-color: var(--accent);
		color: var(--accent-ink);
	}

	.rerun-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.muted,
	.alert {
		font-size: 13px;
		margin: 0;
	}

	.muted {
		color: var(--text-3);
	}

	.alert {
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 10px 12px;
	}

	:global(.test-dlg-content .close-btn) {
		position: absolute;
		top: 14px;
		right: 14px;
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: none;
		border-radius: var(--r);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.test-dlg-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.test-dlg-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
