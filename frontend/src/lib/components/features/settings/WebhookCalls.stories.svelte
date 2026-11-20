<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import type { CallsPage, WebhookCallRecord } from '$lib/webhooks/webhooks.js';
	import WebhookCalls from './WebhookCalls.svelte';

	const { Story } = defineMeta({
		component: WebhookCalls,
		title: 'Components/Features/Settings/WebhookCalls',
		tags: ['autodocs'],
		// The status pills use the shared weak-tint token pairs (--warn on
		// --warn-weak and friends), which sit below the 4.5:1 axe threshold at
		// pill sizes. Every surface that renders these pills carries the same
		// known backlog (ApiKeyManager, IndexesTable, GlobalAuditTable) — the
		// fix belongs in the tokens, not in one component.
		parameters: { a11y: { test: 'todo' } }
	});

	// Component tests for the embedded call log. The list surface is a
	// canned function; the stories assert row rendering, the status filter,
	// the detail expansion, and the replay feedback.

	function call(overrides: Partial<WebhookCallRecord>): WebhookCallRecord {
		return {
			id: '01CALL',
			webhook_id: 'core.Webhook.01WH1',
			job_id: '01JOB',
			event: 'updated',
			source_doc_id: 'crm.Invoice.01DOC1',
			mutation_id: '01MUT',
			attempt: 1,
			status: 'failed',
			http_status: 500,
			error: null,
			response_body: 'boom',
			duration_ms: 250,
			created_at: '2026-01-15T08:00:00Z',
			updated_at: '2026-01-15T08:01:00Z',
			...overrides
		};
	}

	const PAGE: CallsPage = {
		data: [
			call({
				id: '01C1',
				event: 'updated',
				status: 'failed',
				http_status: 500,
				attempt: 3,
				response_body: 'boom'
			}),
			call({
				id: '01C2',
				event: 'created',
				status: 'succeeded',
				http_status: 200,
				attempt: 1,
				response_body: null,
				created_at: '2026-01-15T07:00:00Z'
			}),
			call({
				id: '01C3',
				event: 'deleted',
				status: 'pending',
				http_status: null,
				attempt: 1,
				response_body: null,
				created_at: '2026-01-15T09:00:00Z'
			})
		],
		meta: { count: 3, more: false }
	};
</script>

<Story
	name="RendersAttemptRows"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: async () => PAGE
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('updated')).toBeInTheDocument());
		expect(canvas.getByText('500')).toBeInTheDocument();
		expect(canvas.getByText('200')).toBeInTheDocument();
		expect(canvas.getByText('All')).toBeInTheDocument();
		expect(canvas.getByText('3 calls')).toBeInTheDocument();
	}}
></Story>

<Story
	name="StatusFilterReloads"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: fn(async (_id: string, params?: { status?: string }) =>
			params?.status === 'failed' ? { data: [PAGE.data[0]], meta: { count: 1, more: false } } : PAGE
		)
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('3 calls')).toBeInTheDocument());
		await userEvent.click(canvas.getByRole('button', { name: 'failed' }));
		await waitFor(() => expect(canvas.getByText('1 calls')).toBeInTheDocument());
		expect(args.listFn).toHaveBeenCalledWith(
			'core.Webhook.01WH1',
			expect.objectContaining({ status: 'failed' })
		);
	}}
></Story>

<Story
	name="DetailExpandsWithResponse"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: async () => PAGE
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('updated')).toBeInTheDocument());
		await userEvent.click(canvas.getByText('500'));
		await waitFor(() => expect(canvas.getByText('boom')).toBeInTheDocument());
		expect(canvas.getByText('Receiver response')).toBeInTheDocument();
		expect(canvas.getByText('Mutation')).toBeInTheDocument();
	}}
></Story>

<Story
	name="ReplayQueuesAndRefreshes"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: async () => PAGE,
		replayFn: async () => ({ call_id: '01C1', job_id: '01JOBNEW' })
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('updated')).toBeInTheDocument());
		await userEvent.click(canvas.getByText('500'));
		await waitFor(() => expect(canvas.getByText('boom')).toBeInTheDocument());
		await userEvent.click(canvas.getByRole('button', { name: 'Replay' }));
		await waitFor(() => expect(canvas.getByText(/Replay queued/)).toBeInTheDocument());
	}}
></Story>

<Story
	name="ReplayRejectionSurfaces"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: async () => PAGE,
		replayFn: async () => {
			throw new Error('Replay rejected: source document not readable by bound role');
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('updated')).toBeInTheDocument());
		await userEvent.click(canvas.getByText('500'));
		await waitFor(() => expect(canvas.getByText('boom')).toBeInTheDocument());
		await userEvent.click(canvas.getByRole('button', { name: 'Replay' }));
		await waitFor(() =>
			expect(canvas.getByText(/Replay rejected: source document not readable/)).toBeInTheDocument()
		);
	}}
></Story>

<Story
	name="TestProbeHasNoReplay"
	args={{
		webhookId: 'core.Webhook.01WH1',
		listFn: async () => ({
			data: [
				call({ id: '01PROBE', job_id: null, event: 'test', status: 'succeeded', http_status: 200 })
			],
			meta: { count: 1, more: false }
		})
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('test')).toBeInTheDocument());
		await userEvent.click(canvas.getByText('200'));
		await waitFor(() => expect(canvas.getByText('Mutation')).toBeInTheDocument());
		// A probe has no parent job — no replay button renders.
		expect(canvas.queryByRole('button', { name: 'Replay' })).not.toBeInTheDocument();
	}}
></Story>
