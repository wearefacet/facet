// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for the webhook call-log, replay, and test routes.
//
// Backend: `src/webhook/routes.cr` —
//   GET|QUERY /Api/core/Webhook/:id/calls              paginated call log
//   GET       /Api/core/Webhook/:id/calls/:call_id     one call row
//   POST      /Api/core/Webhook/:id/calls/:call_id/replay   re-enqueue (202)
//   POST      /Api/core/Webhook/:id/test               inline test POST
//
// The webhook documents themselves ride the standard document API
// (`/Api/core/Webhook`), consumed through the DataSource layer — see
// `WebhookManager.svelte`. Replay re-runs the enqueue-time RBAC gate and
// answers 202 with a fresh job id; the new attempt shows up in the call
// log later, so there is no inline result. The test action answers 200
// regardless of the receiver's status — the receiver's response is data,
// not a client-side error.

import { apiFetch } from '$lib/session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';

/** One outbound HTTP attempt — a `webhook_calls` row. */
export interface WebhookCallRecord {
	id: string;
	webhook_id: string;
	/** Null for a test probe — a probe has no parent job to replay. */
	job_id: string | null;
	event: string;
	source_doc_id: string;
	mutation_id: string | null;
	attempt: number;
	status: CallStatus;
	http_status: number | null;
	error: string | null;
	/** Receiver response snippet (capped at 4 KB server-side); null on transport errors. */
	response_body: string | null;
	duration_ms: number | null;
	created_at: string;
	updated_at: string;
}

export const CALL_STATUSES = ['pending', 'succeeded', 'failed'] as const;
export type CallStatus = (typeof CALL_STATUSES)[number];

export interface CallsPage {
	data: WebhookCallRecord[];
	meta: { count: number; more: boolean };
}

export interface ReplayResult {
	call_id: string;
	job_id: string;
}

/** The test action's answer — the receiver's response as data. */
export interface WebhookTestResult {
	http_status: number | null;
	response_body: string | null;
	response_headers: Record<string, string> | null;
	transport_error: string | null;
	duration_ms: number | null;
	signed_body: string;
}

export interface ListCallsParams {
	page?: number;
	items?: number;
	status?: CallStatus;
}

/**
 * The editable subset of a `core.Webhook` content, and the create / update
 * payload shape. `events` absent means "all events" (the backend's absent
 * field); a present array — even empty — is the named subset.
 */
export interface WebhookInput {
	label: string;
	url: string;
	source_doctype: string;
	events?: string[];
	headers?: Record<string, string>;
}

type FetchFn = typeof fetch;

export async function listCalls(
	webhookId: string,
	params: ListCallsParams = {},
	fetchFn?: FetchFn
): Promise<CallsPage> {
	const qs = new URLSearchParams();
	if (params.page !== undefined) qs.set('page', String(params.page));
	if (params.items !== undefined) qs.set('items', String(params.items));
	if (params.status) qs.set('status', params.status);
	const query = qs.toString();
	const res = await apiFetch(
		`/Api/core/Webhook/${encodeURIComponent(webhookId)}/calls${query ? `?${query}` : ''}`,
		{},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_webhooks_calls_load());
	return (await res.json()) as CallsPage;
}

export async function findCall(
	webhookId: string,
	callId: string,
	fetchFn?: FetchFn
): Promise<WebhookCallRecord> {
	const res = await apiFetch(
		`/Api/core/Webhook/${encodeURIComponent(webhookId)}/calls/${encodeURIComponent(callId)}`,
		{},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_webhooks_calls_load());
	return (await res.json()) as WebhookCallRecord;
}

export async function replayCall(
	webhookId: string,
	callId: string,
	fetchFn?: FetchFn
): Promise<ReplayResult> {
	const res = await apiFetch(
		`/Api/core/Webhook/${encodeURIComponent(webhookId)}/calls/${encodeURIComponent(callId)}/replay`,
		{ method: 'POST' },
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_webhooks_replay());
	return (await res.json()) as ReplayResult;
}

export async function testWebhook(
	webhookId: string,
	fetchFn?: FetchFn
): Promise<WebhookTestResult> {
	const res = await apiFetch(
		`/Api/core/Webhook/${encodeURIComponent(webhookId)}/test`,
		{ method: 'POST' },
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_webhooks_test());
	return (await res.json()) as WebhookTestResult;
}
