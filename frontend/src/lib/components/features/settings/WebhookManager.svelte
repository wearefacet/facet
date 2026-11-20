<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Pencil, Plus, Trash2, Webhook as WebhookIcon, ClipboardList } from '@lucide/svelte';
	import Panel from '$lib/components/primitives/surfaces/Panel.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { confirm } from '$lib/confirm.svelte';
	import { can } from '$lib/permissions.svelte';
	import WebhookDialog from './WebhookDialog.svelte';
	import WebhookCalls from './WebhookCalls.svelte';
	import WebhookTestDialog from './WebhookTestDialog.svelte';
	import { listCalls, replayCall, testWebhook, type WebhookInput } from '$lib/webhooks/webhooks.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * WebhookManager — the self-service surface for the caller's
	 * `core.Webhook` documents, under Settings next to API keys.
	 *
	 * Webhook CRUD rides the standard document API through the DataSource
	 * layer; the call log, replay, and test ride the bespoke routes through
	 * `src/lib/webhooks/webhooks.ts`. When `accountId` is set the list is
	 * narrowed to the caller's own webhooks — the stored `account_id` is a
	 * qualified reference token (`iam.Account.<id>`), so the filter value
	 * gets the same qualification.
	 *
	 * Every action is gated client-side on the caller's RBAC manifest; the
	 * backend re-checks (a denial on the call-log routes is a
	 * non-disclosing 404). The driver and the action callbacks are
	 * injectable so stories run against the mock driver.
	 */

	let {
		/** Own-account filter — qualified to the stored reference-token form. */
		accountId = undefined as string | undefined,
		driver = new DocumentDataDriver('') as DataDriver,
		createFn,
		updateFn,
		deleteFn,
		/** Call-log surface — injectable so stories drive canned pages. */
		listCallsFn = listCalls,
		replayFn = replayCall,
		testFn = testWebhook
	}: {
		accountId?: string;
		driver?: DataDriver;
		createFn?: (input: WebhookInput) => Promise<unknown>;
		updateFn?: (id: string, input: WebhookInput, current: WebhookContent) => Promise<unknown>;
		deleteFn?: (id: string) => Promise<unknown>;
		listCallsFn?: typeof listCalls;
		replayFn?: typeof replayCall;
		testFn?: typeof testWebhook;
	} = $props();

	/** The editable content of a `core.Webhook` projection. */
	interface WebhookContent extends WebhookInput {
		enabled?: boolean;
		secret?: string;
	}

	interface WebhookRow {
		id: string;
		content: WebhookContent;
	}

	let hooks = $state<WebhookRow[] | null>(null);
	let loadError = $state<string | undefined>(undefined);
	let actionError = $state<string | undefined>(undefined);
	let busyId = $state<string | null>(null);
	let dialogOpen = $state(false);
	let editing = $state<WebhookRow | null>(null);
	let callsId = $state<string | null>(null);
	let testId = $state<string | null>(null);

	const canCreate = $derived(can('core.Webhook', 'create'));
	const canUpdate = $derived(can('core.Webhook', 'update'));
	const canDelete = $derived(can('core.Webhook', 'delete'));

	function ds(): DataSource<WebhookContent> {
		return driver.domain('core').doctype<WebhookContent>('Webhook');
	}

	async function defaultCreate(input: WebhookInput) {
		return ds().create(input as WebhookContent);
	}

	async function defaultUpdate(id: string, input: WebhookInput, current: WebhookContent) {
		const patch: Record<string, unknown> = {};
		if (input.label !== current.label) patch.label = input.label;
		if (input.url !== current.url) patch.url = input.url;
		if (input.source_doctype !== current.source_doctype)
			patch.source_doctype = input.source_doctype;
		if (JSON.stringify(input.events) !== JSON.stringify(current.events)) {
			// Absent on "all events" — a PATCH carries the explicit choice.
			patch.events = input.events ?? [];
		}
		if (JSON.stringify(input.headers) !== JSON.stringify(current.headers)) {
			patch.headers = input.headers ?? {};
		}
		if (Object.keys(patch).length === 0) return null;
		return ds()
			.doc(id)
			.update({ set: [{ op: 'replace', path: '/', value: patch }] });
	}

	async function defaultDelete(id: string) {
		return ds().doc(id).delete();
	}

	const doCreate = $derived(createFn ?? defaultCreate);
	const doUpdate = $derived(updateFn ?? defaultUpdate);
	const doDelete = $derived(deleteFn ?? defaultDelete);

	// Initial load — the effect reads no written state, so it cannot loop.
	$effect(() => {
		void accountId;
		void refresh();
	});

	async function refresh() {
		loadError = undefined;
		try {
			const filters =
				accountId && accountId !== '' ? { account_id__eq: `iam.Account.${accountId}` } : {};
			const res = await ds().list({ filters, items: 100 });
			hooks = res.data.map((item) => ({ id: item.meta.id, content: item.data as WebhookContent }));
		} catch (e) {
			loadError = errorMessage(e, m.webhooks_load_error());
			hooks = null;
		}
	}

	function eventsLabel(content: WebhookContent): string {
		if (content.events === undefined) return m.webhooks_events_all();
		if (content.events.length === 0) return m.webhooks_events_none();
		return content.events.join(', ');
	}

	async function handleCreate(input: WebhookInput): Promise<string | null> {
		try {
			await doCreate(input);
			await refresh();
			return null;
		} catch (e) {
			return errorMessage(e, m.webhooks_create_error());
		}
	}

	async function handleUpdate(input: WebhookInput): Promise<string | null> {
		if (!editing) return null;
		try {
			await doUpdate(editing.id, input, editing.content);
			await refresh();
			return null;
		} catch (e) {
			return errorMessage(e, m.webhooks_update_error());
		}
	}

	async function handleSave(input: WebhookInput): Promise<string | null> {
		return editing ? handleUpdate(input) : handleCreate(input);
	}

	async function handleToggle(row: WebhookRow, checked: boolean) {
		if (busyId) return;
		busyId = row.id;
		actionError = undefined;
		try {
			await ds()
				.doc(row.id)
				.update({ set: [{ op: 'replace', path: '/enabled', value: checked }] });
			await refresh();
		} catch (e) {
			actionError = errorMessage(e, m.webhooks_update_error());
		} finally {
			busyId = null;
		}
	}

	async function handleDelete(row: WebhookRow) {
		if (busyId) return;
		const ok = await confirm({
			title: m.webhooks_delete_confirm_title({ name: row.content.label }),
			message: m.webhooks_delete_confirm_body(),
			confirmLabel: m.webhooks_delete_button(),
			variant: 'danger'
		});
		if (!ok) return;
		busyId = row.id;
		actionError = undefined;
		try {
			await doDelete(row.id);
			if (callsId === row.id) callsId = null;
			await refresh();
		} catch (e) {
			actionError = errorMessage(e, m.webhooks_delete_error());
		} finally {
			busyId = null;
		}
	}

	function openCreate() {
		editing = null;
		dialogOpen = true;
	}

	function openEdit(row: WebhookRow) {
		editing = row;
		dialogOpen = true;
	}

	function toggleCalls(row: WebhookRow) {
		callsId = callsId === row.id ? null : row.id;
	}
</script>

<div class="hooks-wrap">
	<Panel>
		<div class="head">
			<div class="head-tx">
				<h2 class="title">{m.webhooks_manager_title()}</h2>
				<p class="sub">{m.webhooks_manager_helper()}</p>
			</div>
			{#if canCreate}
				<button class="create-btn" onclick={openCreate}>
					<Plus size={15} stroke-width={2} />
					<span>{m.webhooks_create_button()}</span>
				</button>
			{/if}
		</div>

		{#if loadError}
			<p class="alert" role="alert">{loadError}</p>
		{:else if hooks === null}
			<p class="muted">{m.webhooks_loading()}</p>
		{:else if hooks.length === 0}
			<div class="empty">
				<WebhookIcon size={20} stroke-width={1.8} />
				<p>{m.webhooks_empty()}</p>
			</div>
		{:else}
			<ul class="hook-list">
				{#each hooks as row (row.id)}
					{@const content = row.content}
					{@const isCallsOpen = callsId === row.id}
					<li class="hook-row">
						<div class="row-main">
							<div class="id-block">
								<span class="hook-name">{content.label}</span>
								<code class="hook-url">{content.url}</code>
							</div>
							<span class="chip">{content.source_doctype}</span>
							<span class="chip events-chip" title={eventsLabel(content)}>
								{eventsLabel(content)}
							</span>
							<div class="secret-block">
								<span class="time-label">{m.webhooks_secret_label()}</span>
								<div class="secret-line">
									<code class="secret">{content.secret ?? ''}</code>
									<CopyButton
										value={content.secret ?? ''}
										title={m.webhooks_secret_copy_aria()}
										iconOnly
									/>
								</div>
							</div>
							<div class="times">
								{#if content.enabled === false}
									<span class="status-badge badge-disabled">{m.webhooks_status_disabled()}</span>
								{:else}
									<span class="status-badge badge-enabled">{m.webhooks_status_enabled()}</span>
								{/if}
							</div>
							<div class="actions">
								{#if canUpdate}
									<Toggle
										label={m.webhooks_enabled_label()}
										checked={content.enabled !== false}
										disabled={busyId === row.id}
										onchange={(checked) => handleToggle(row, checked)}
									/>
									<button
										class="action-btn"
										title={m.webhooks_edit_button()}
										onclick={() => openEdit(row)}
									>
										<Pencil size={14} stroke-width={1.8} />
										<span>{m.webhooks_edit_button()}</span>
									</button>
									<button
										class="action-btn"
										title={m.webhooks_test_button()}
										onclick={() => (testId = row.id)}
									>
										<WebhookIcon size={14} stroke-width={1.8} />
										<span>{m.webhooks_test_button()}</span>
									</button>
								{/if}
								<button
									class="action-btn"
									class:active={isCallsOpen}
									title={m.webhooks_calls_button()}
									onclick={() => toggleCalls(row)}
								>
									<ClipboardList size={14} stroke-width={1.8} />
									<span>{m.webhooks_calls_button()}</span>
								</button>
								{#if canDelete}
									<button
										class="action-btn danger"
										disabled={busyId === row.id}
										title={m.webhooks_delete_button()}
										onclick={() => handleDelete(row)}
									>
										<Trash2 size={14} stroke-width={1.8} />
										<span>{m.webhooks_delete_button()}</span>
									</button>
								{/if}
							</div>
						</div>
						{#if isCallsOpen}
							<div class="calls-panel">
								<WebhookCalls webhookId={row.id} listFn={listCallsFn} {replayFn} />
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		{#if actionError}
			<p class="alert" role="alert">{actionError}</p>
		{/if}
	</Panel>
</div>

<WebhookDialog
	bind:open={dialogOpen}
	webhook={editing?.content ?? null}
	{driver}
	onsave={handleSave}
/>
<WebhookTestDialog
	open={testId !== null}
	webhookId={testId ?? ''}
	onclose={() => (testId = null)}
	{testFn}
/>

<style>
	.hooks-wrap {
		padding: 0 32px 32px;
	}

	.head {
		display: flex;
		align-items: flex-start;
		gap: 16px;
		margin-bottom: 18px;
	}

	.head-tx {
		flex: 1;
		min-width: 0;
	}

	.title {
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		margin: 0;
	}

	.sub {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 4px 0 0;
		line-height: 1.5;
	}

	.create-btn {
		flex: none;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 7px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.create-btn:hover {
		background: var(--accent-press);
	}

	.create-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.hook-list {
		list-style: none;
		margin: 0;
		padding: 0;
		border-top: 1px solid var(--border);
	}

	.hook-row {
		border-bottom: 1px solid var(--border);
		padding: 12px 0;
	}

	.row-main {
		display: flex;
		align-items: center;
		gap: 14px;
		flex-wrap: wrap;
	}

	.id-block {
		flex: 1;
		min-width: 180px;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.hook-name {
		font-size: 13px;
		font-weight: 600;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.hook-url {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.chip {
		flex: none;
		max-width: 220px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 2px 10px;
	}

	.secret-block {
		flex: none;
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 140px;
	}

	.time-label {
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.secret-line {
		display: flex;
		align-items: center;
		gap: 6px;
	}

	.secret {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
		max-width: 180px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.times {
		flex: none;
	}

	.status-badge {
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		border-radius: var(--r-pill);
		padding: 2px 9px;
	}

	.badge-enabled {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.badge-disabled {
		color: var(--warn);
		background: var(--warn-weak);
	}

	.actions {
		flex: none;
		display: flex;
		align-items: center;
		gap: 8px;
		margin-left: auto;
	}

	.action-btn {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 5px 10px;
		border-radius: var(--r);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text-2);
	}

	.action-btn:hover:not(:disabled) {
		border-color: var(--accent);
		color: var(--accent-ink);
	}

	.action-btn.active {
		border-color: var(--accent);
		color: var(--accent-ink);
		background: var(--surface-2);
	}

	.action-btn.danger:hover:not(:disabled) {
		border-color: var(--danger);
		color: var(--danger);
		background: var(--danger-weak);
	}

	.action-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.action-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.calls-panel {
		margin-top: 12px;
		padding: 14px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface-2);
	}

	.empty {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 18px 0 6px;
		color: var(--text-3);
		font-size: 13px;
	}

	.empty p {
		margin: 0;
	}

	.muted,
	.alert {
		font-size: 13px;
		margin: 14px 0 0;
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
</style>
