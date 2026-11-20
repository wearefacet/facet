<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { setPermissions } from '$lib/permissions.svelte';
	import type { CallsPage } from '$lib/webhooks/webhooks.js';
	import WebhookManager from './WebhookManager.svelte';

	// Component tests for the webhook manager. The document surface runs on
	// MockDataDriver (same `{ data, meta }` shapes as the real backend); the
	// call-log and test surfaces are canned functions. The admin wildcard
	// hydrates the permission store so the create / edit / delete affordances
	// render (they are `can()`-gated — read-only rendering is the safe
	// default, covered by the NoManifest story).

	const WEBHOOK_SEED = [
		{
			id: 'core.Webhook.01WH1',
			label: 'Billing sync',
			url: 'https://billing.example.test/hooks',
			source_doctype: 'core.DocType.crm.Invoice',
			events: ['created', 'updated'],
			headers: { Authorization: 'Bearer tok' },
			secret: '01HXXXXXXXWHSECRET1',
			enabled: true,
			account_id: 'iam.Account.01ACC1',
			role_id: 'iam.Roles.admin'
		},
		{
			id: 'core.Webhook.01WH2',
			label: 'All-events mirror',
			url: 'http://mirror.local/hook',
			source_doctype: 'core.DocType.hr.Employee',
			secret: '01HXXXXXXXWHSECRET2',
			enabled: false,
			account_id: 'iam.Account.01ACC1',
			role_id: 'iam.Roles.admin'
		}
	];

	const DOCTYPE_SEED = [
		{ id: 'crm.Invoice', domain: 'crm', doctype: 'Invoice', color: '#566688' },
		{ id: 'hr.Employee', domain: 'hr', doctype: 'Employee', color: '#566688' }
	];

	function makeDriver(seed = WEBHOOK_SEED): DataDriver {
		const d = new MockDataDriver();
		d.domain('core').doctype(
			'Webhook',
			seed.map((s) => ({ ...s }))
		);
		d.domain('core').doctype(
			'DocType',
			DOCTYPE_SEED.map((s) => ({ ...s }))
		);
		return d;
	}

	const CALLS_PAGE: CallsPage = {
		data: [
			{
				id: '01CALL1',
				webhook_id: 'core.Webhook.01WH1',
				job_id: '01JOB1',
				event: 'updated',
				source_doc_id: 'crm.Invoice.01DOC1',
				mutation_id: '01MUT1',
				attempt: 2,
				status: 'failed',
				http_status: 500,
				error: null,
				response_body: 'Internal Server Error',
				duration_ms: 812,
				created_at: '2026-01-15T08:00:00Z',
				updated_at: '2026-01-15T08:01:00Z'
			},
			{
				id: '01CALL2',
				webhook_id: 'core.Webhook.01WH1',
				job_id: '01JOB2',
				event: 'created',
				source_doc_id: 'crm.Invoice.01DOC2',
				mutation_id: '01MUT2',
				attempt: 1,
				status: 'succeeded',
				http_status: 200,
				error: null,
				response_body: null,
				duration_ms: 121,
				created_at: '2026-01-15T07:30:00Z',
				updated_at: '2026-01-15T07:30:05Z'
			}
		],
		meta: { count: 2, more: false }
	};

	const noopCalls = async () => CALLS_PAGE;
	const noopReplay = async () => ({ call_id: '01CALL1', job_id: '01JOBNEW' });
	const noopTest = async () => ({
		http_status: 401,
		response_body: 'unauthorized',
		response_headers: null,
		transport_error: null,
		duration_ms: 88,
		signed_body: '{"event":"test"}'
	});

	// Admin wildcard so the create / edit / delete affordances render.
	setPermissions({ '*.*': ['*'] });

	/**
	 * The seeded-editor manifest shape (B-85): per-action wildcard carve-outs
	 * plus the ownership-scoped core.Webhook re-grants. `create` on
	 * `core.Webhook` resolves only through the wildcard fallback — the exact
	 * key lacks it and the update/delete/read lines except the doctype. The
	 * pre-B-85 single-union except key denied it and hid the button.
	 */
	const EDITOR_MANIFEST = {
		'*.*': ['create', 'update', 'delete', 'read'],
		'core.Webhook': ['read', 'update', 'delete'],
		'*.*.except.create': ['core.SystemSettings', 'iam.OIDCProvider'],
		'*.*.except.update': ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook'],
		'*.*.except.delete': ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook'],
		'*.*.except.read': ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
	};

	const { Story } = defineMeta({
		component: WebhookManager,
		title: 'Components/Features/Settings/WebhookManager',
		tags: ['autodocs']
	});
</script>

<script lang="ts">
	// The create dialog portals into `document.body` — dialog assertions
	// query there (the ApiKeyRevealDialog stories set the pattern).
	import { within as withinBody } from 'storybook/test';
</script>

<Story
	name="RendersWebhookList"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		expect(canvas.getByText('https://billing.example.test/hooks')).toBeInTheDocument();
		// Absent events = all events; the named subset renders as a list.
		expect(canvas.getByText('All events')).toBeInTheDocument();
		expect(canvas.getByText('created, updated')).toBeInTheDocument();
		// The enabled badge and the toggle label share the word — assert both
		// states render through the badge variant count.
		expect(canvas.getAllByText('Enabled').length).toBeGreaterThan(0);
		expect(canvas.getByText('Paused')).toBeInTheDocument();
		// The signing secret renders with a copy affordance.
		expect(canvas.getByText('01HXXXXXXXWHSECRET1')).toBeInTheDocument();
	}}
></Story>

<Story
	name="EmptyState"
	args={{
		accountId: '01ACC1',
		driver: makeDriver([]),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() =>
			expect(
				canvas.getByText('No webhooks yet. Create one to push events to an HTTPS receiver.')
			).toBeInTheDocument()
		);
	}}
></Story>

<Story
	name="CreateFlowOpensDialog"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		await userEvent.click(canvas.getByRole('button', { name: 'Create webhook' }));
		// The dialog portals into document.body — assert there, then close it
		// with Escape so the portal is clean for later stories.
		const body = withinBody(document.body);
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());
		expect(body.getByLabelText('Name')).toBeInTheDocument();
		expect(body.getByLabelText('Target URL')).toBeInTheDocument();
		expect(body.getByText('Fire on all events')).toBeInTheDocument();
		// Submit stays disabled until the required fields are filled.
		expect(body.getByRole('button', { name: 'Save' })).toBeDisabled();
		await waitFor(async () => {
			await userEvent.keyboard('{Escape}');
			expect(body.queryByText('New webhook')).toBeNull();
		});
	}}
></Story>

<Story
	name="TogglePausesWebhook"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		// Two rows — the first switch belongs to the enabled Billing sync.
		expect(canvas.getAllByRole('switch')[0]).toHaveAttribute('aria-checked', 'true');
		await userEvent.click(canvas.getAllByRole('switch')[0]);
		// The write rides the document API; the row flips after the refresh.
		await waitFor(() => {
			const switches = canvas.getAllByRole('switch');
			expect(switches[0]).toHaveAttribute('aria-checked', 'false');
		});
	}}
></Story>

<Story
	name="CallsPanelShowsAttempts"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		replayFn: noopReplay,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		await userEvent.click(canvas.getAllByRole('button', { name: 'Calls' })[0]);
		// The embedded call log renders the canned page: one failed attempt
		// with its HTTP status, one succeeded, newest first.
		await waitFor(() => expect(canvas.getByText('updated')).toBeInTheDocument());
		expect(canvas.getByText('500')).toBeInTheDocument();
		expect(canvas.getByText('200')).toBeInTheDocument();
	}}
></Story>

<Story
	name="NoManifestHidesWriteActions"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		// Drop the wildcard for this story, restore after the assertions.
		setPermissions(null);
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		expect(canvas.queryByRole('button', { name: 'Create webhook' })).not.toBeInTheDocument();
		expect(canvas.queryByRole('button', { name: 'Delete' })).not.toBeInTheDocument();
		setPermissions({ '*.*': ['*'] });
	}}
></Story>

<Story
	name="EditorManifestShowsCreateButton"
	args={{
		accountId: '01ACC1',
		driver: makeDriver(),
		listCallsFn: noopCalls,
		testFn: noopTest
	}}
	play={async ({ canvasElement }) => {
		// Swap in the editor manifest, restore after the assertions.
		setPermissions(EDITOR_MANIFEST);
		const canvas = within(canvasElement);
		await waitFor(() => expect(canvas.getByText('Billing sync')).toBeInTheDocument());
		// B-85 regression: the create grant rides the wildcard fallback (the
		// create line does not except core.Webhook) — the button must render.
		expect(canvas.getByRole('button', { name: 'Create webhook' })).toBeInTheDocument();
		// Management actions ride the exact $mine key (one Delete per row).
		expect(canvas.getAllByRole('button', { name: 'Delete' }).length).toBeGreaterThan(0);
		setPermissions({ '*.*': ['*'] });
	}}
></Story>
