<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor } from 'storybook/test';
	import type { WebhookTestResult } from '$lib/webhooks/webhooks.js';
	import WebhookTestDialog from './WebhookTestDialog.svelte';

	const { Story } = defineMeta({
		component: WebhookTestDialog,
		title: 'Components/Features/Settings/WebhookTestDialog',
		tags: ['autodocs']
	});

	// Component tests for the test dialog. Bits UI portals the dialog into
	// `document.body`, so the plays query `within(document.body)` and close
	// the dialog at the end so later stories see a clean portal.
	//
	// The status-as-data rule: the receiver's answer — success, 4xx, or a
	// transport error — renders as a result; only a Facet-side rejection
	// surfaces as a dialog error.

	function result(overrides: Partial<WebhookTestResult>): WebhookTestResult {
		return {
			http_status: 200,
			response_body: '{"ok":true}',
			response_headers: null,
			transport_error: null,
			duration_ms: 120,
			signed_body: '{"event":"test"}',
			...overrides
		};
	}

	async function closeDialog() {
		const body = within(document.body);
		const close = body.getAllByRole('button').find((b) => b.querySelector('svg.lucide-x'));
		if (close) {
			await userEvent.click(close);
			await waitFor(() => {
				expect(body.queryByText('Test webhook')).toBeNull();
			});
		}
	}
</script>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	// The play functions run in the instance script — `within` must be
	// imported there (the ApiKeyRevealDialog stories set the pattern).
	import { within } from 'storybook/test';
</script>

<Story
	name="SuccessShowsOutcome"
	args={{
		open: true,
		webhookId: 'core.Webhook.01WH1',
		testFn: async () => result({})
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Test webhook')).toBeVisible());
		await waitFor(() => expect(body.getByText('200')).toBeVisible());
		expect(body.getByText('{"ok":true}')).toBeInTheDocument();
		expect(body.getByText('Receiver response')).toBeInTheDocument();
		expect(body.getByText('Signed body')).toBeInTheDocument();
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookTestDialog open={args.open} webhookId={args.webhookId} testFn={args.testFn} />
		</div>
	{/snippet}
</Story>

<Story
	name="ReceiverErrorIsData"
	args={{
		open: true,
		webhookId: 'core.Webhook.01WH1',
		testFn: async () => result({ http_status: 401, response_body: 'unauthorized', duration_ms: 64 })
	}}
	play={async () => {
		const body = within(document.body);
		// A receiver 401 is a result, not a dialog error.
		await waitFor(() => expect(body.getByText('401')).toBeVisible());
		expect(body.getByText('unauthorized')).toBeInTheDocument();
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookTestDialog open={args.open} webhookId={args.webhookId} testFn={args.testFn} />
		</div>
	{/snippet}
</Story>

<Story
	name="TransportErrorShown"
	args={{
		open: true,
		webhookId: 'core.Webhook.01WH1',
		testFn: async () =>
			result({
				http_status: null,
				response_body: null,
				transport_error: 'Connection refused',
				duration_ms: 12
			})
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getAllByText('Transport error').length).toBeGreaterThan(0));
		expect(body.getByText('Connection refused')).toBeInTheDocument();
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookTestDialog open={args.open} webhookId={args.webhookId} testFn={args.testFn} />
		</div>
	{/snippet}
</Story>

<Story
	name="FacetRejectionIsError"
	args={{
		open: true,
		webhookId: 'core.Webhook.01WH1',
		testFn: async () => {
			throw new Error('Webhook is disabled');
		}
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Webhook is disabled')).toBeVisible());
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookTestDialog open={args.open} webhookId={args.webhookId} testFn={args.testFn} />
		</div>
	{/snippet}
</Story>

<Story
	name="SendAgainReruns"
	args={{
		open: true,
		webhookId: 'core.Webhook.01WH1',
		testFn: async () => result({})
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByRole('button', { name: 'Send again' })).toBeVisible());
		await userEvent.click(body.getByRole('button', { name: 'Send again' }));
		// The outcome stays rendered after a rerun.
		await waitFor(() => expect(body.getByText('200')).toBeVisible());
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookTestDialog open={args.open} webhookId={args.webhookId} testFn={args.testFn} />
		</div>
	{/snippet}
</Story>
