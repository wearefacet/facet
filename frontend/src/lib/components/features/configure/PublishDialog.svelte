<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	/** One row of the publish dialog's documents block. */
	export interface PublishDoctypeOption {
		/** Bare doctype name, e.g. `Status` — the name the publish body carries. */
		name: string;
		/** Rows the draft holds for this doctype. */
		count: number;
		/** True when the live target already defines this doctype. Overwrite
		 *  publish refuses its documents, so the row is disabled. */
		exists: boolean;
	}
</script>

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import type {
		DomainCheckResult,
		PublishDocumentsSelection
	} from '$lib/datasource/domainCheck.js';
	import {
		ticketPullsUntagged,
		type GrantTicket,
		type PublishReport
	} from '$lib/components/features/configure/domainGrants.js';
	import type { PublishOutcome } from '$lib/builderDraft.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** Draft domain id (e.g. `_abc`) being published. */
		draftDomain = '',
		/** Suggested target name, seeded into the input each time the dialog
		 *  opens. Drafts branched from a live domain pass the author's intended
		 *  name, or the source domain the draft came from. Empty drafts pass ''. */
		initialName = '',
		/** Latest domain check result, for the inline warnings panel. `undefined`
		 *  while the check is still loading; the dialog renders a neutral hint
		 *  in that case rather than blocking submit. */
		check = undefined,
		/** The draft's doctypes, in draft order, with the row count each holds
		 *  and whether the live target already defines it. Drives the documents
		 *  block; an empty list hides the block. */
		doctypes = [],
		/**
		 * Called when the user confirms with a valid target name. `overwrite`
		 * is false on the first attempt and true only after the user confirmed
		 * the overwrite of an existing target. `documents` carries the selected
		 * draft doctypes (`undefined` when the user carried none). Resolves
		 * with a {@link PublishOutcome}: `published` with a grant-ticket report
		 * keeps the dialog open on the report, `published` without one closes
		 * it, `conflict` shows the explicit overwrite confirmation, `error`
		 * shows the message inline.
		 */
		onpublish = (
			_targetName: string,
			_overwrite: boolean,
			_documents?: PublishDocumentsSelection
		): Promise<PublishOutcome> => Promise.resolve({ status: 'published', report: null }),
		/**
		 * Called when the user leaves the ticket report. The publish has
		 * already landed and the draft is gone — the receiver navigates (the
		 * report never closes onto the dead builder URL on its own).
		 */
		oncontinue = (_domain: string) => {}
	}: {
		open?: boolean;
		draftDomain?: string;
		initialName?: string;
		check?: DomainCheckResult | undefined;
		doctypes?: PublishDoctypeOption[];
		onpublish?: (
			targetName: string,
			overwrite: boolean,
			documents?: PublishDocumentsSelection
		) => Promise<PublishOutcome>;
		oncontinue?: (domain: string) => void;
	} = $props();

	// `target_name` regex mirrors the backend `Domain::Publish.validate_target_name`:
	// lowercase alphanumeric + dashes, must start with a letter, must not start
	// with `_` (reserved for drafts).
	const TARGET_NAME_RE = /^[a-z][a-z0-9-]*$/;

	let name = $state('');
	let error = $state<string | undefined>(undefined);
	let submitting = $state(false);
	/** Publish report shown after a publish that filed or merged grant
	 *  tickets. `undefined` in form state; set on success-with-tickets. */
	let report = $state<PublishReport | undefined>(undefined);
	/** Set when the backend answered 409 for the typed name: the form gives
	 *  way to the explicit overwrite confirmation (B-353 — nothing is re-sent
	 *  without the user's confirmation). */
	let conflict = $state<{ name: string; message: string } | undefined>(undefined);

	// ── Documents block ────────────────────────────────────────────────────
	// Off by default: a publish carries structure only. Turning it on reveals
	// one row per draft doctype; the rows the live target already defines stay
	// disabled, because the backend refuses to merge draft rows into a
	// production doctype.
	let importDocuments = $state(false);
	/** Names the user ticked. */
	let selected = $state<string[]>([]);

	const importable = $derived(doctypes.filter((d) => !d.exists));
	const allSelected = $derived(
		importable.length > 0 && importable.every((d) => selected.includes(d.name))
	);
	const someSelected = $derived(importable.some((d) => selected.includes(d.name)));
	/** The selection sent with the publish, or `undefined` when the user
	 *  carries no documents. A ticked row the live target now defines (the
	 *  typed name became an existing domain) is dropped from the payload. */
	const documentsSelection = $derived<PublishDocumentsSelection | undefined>(
		importDocuments && someSelected
			? {
					import: true,
					doctypes: selected.filter((name) => importable.some((d) => d.name === name))
				}
			: undefined
	);

	function toggleDoctype(name: string, on: boolean): void {
		if (on) {
			if (!selected.includes(name)) selected = [...selected, name];
		} else {
			selected = selected.filter((n) => n !== name);
		}
	}

	function toggleAll(on: boolean): void {
		selected = on ? importable.map((d) => d.name) : [];
	}

	const trimmed = $derived(name.trim());
	const valid = $derived(TARGET_NAME_RE.test(trimmed));
	const startsWithUnderscore = $derived(trimmed.startsWith('_'));

	// Seeds the input on the closed→open transition and clears state on close.
	// Runs ONLY on the `open` flip: while the dialog is open the parent keeps
	// re-rendering it (each draft-check refresh pushes a new snapshot), and a
	// re-seed on every render wipes the user's in-progress name — the submit
	// then fires under the prefill (the e2e overwrite phase once published
	// over the live source domain this way). `open` can only turn true through
	// the mode bar, which requires the draft snapshot — so `initialName` is
	// already final when the transition runs.
	let seeded = false;
	$effect(() => {
		if (open) {
			if (seeded) return;
			name = initialName.trim();
			error = undefined;
			submitting = false;
			report = undefined;
			conflict = undefined;
			importDocuments = false;
			selected = [];
			seeded = true;
		} else {
			seeded = false;
			name = '';
			error = undefined;
			submitting = false;
			report = undefined;
			conflict = undefined;
			importDocuments = false;
			selected = [];
		}
	});

	async function handleSubmit(overwrite: boolean) {
		if (!valid || submitting) return;
		submitting = true;
		error = undefined;
		conflict = undefined;
		const outcome = await onpublish(trimmed, overwrite, documentsSelection);
		submitting = false;
		if (outcome.status === 'conflict') {
			conflict = { name: trimmed, message: outcome.message };
			return;
		}
		if (outcome.status === 'error') {
			error = outcome.message;
			return;
		}
		if (outcome.report) {
			// The report stays up: grant tickets need the publisher's attention
			// before they move on, and closing would land on the dead builder URL.
			report = outcome.report;
			return;
		}
		open = false;
	}

	/** Leaves the report state. The draft is gone — the receiver navigates. */
	function handleContinue() {
		const domain = report?.domain;
		open = false;
		if (domain) oncontinue(domain);
	}

	function ticketState(ticket: GrantTicket): string {
		return ticket.active ? m.configure_grants_state_active() : m.configure_grants_state_awaiting();
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="publish-overlay" />
		<!-- The ticket report must not close itself: its only exit is the
			continue button, which navigates. A bare close (Esc, outside click)
			would strand the user on the dead draft URL. -->
		<Dialog.Content
			class="publish-content"
			onEscapeKeydown={(e) => {
				if (report) e.preventDefault();
			}}
			onInteractOutside={(e) => {
				if (report) e.preventDefault();
			}}
		>
			{#if report}
				<!-- ── Post-publish ticket report ──────────────────────── -->
				<Dialog.Title class="publish-title">{m.configure_publish_report_title()}</Dialog.Title>
				<Dialog.Description class="publish-desc">
					{m.configure_publish_report_desc({ domain: report.domain })}
				</Dialog.Description>

				<ul class="ticket-list">
					{#each report.grant_tickets as ticket (ticket.producer)}
						<li class="ticket">
							<div class="ticket-head">
								<span class="ticket-producer mono"
									>{m.configure_grants_from({ producer: ticket.producer })}</span
								>
								<span class="sp"></span>
								<span class="ticket-state" class:ok={ticket.active}>{ticketState(ticket)}</span>
							</div>
							<p class="ticket-kind">
								{ticket.filed
									? m.configure_publish_ticket_filed()
									: m.configure_publish_ticket_merged()}
							</p>
							<ul class="edge-list">
								{#each ticket.edges as edge (edge.doctype)}
									<li class="edge mono">{edge.doctype}: {edge.tags.join(', ')}</li>
								{/each}
							</ul>
							{#if ticket.dropped}
								<p class="ticket-warn" role="status">{m.configure_publish_ticket_dropped()}</p>
							{/if}
							{#if ticketPullsUntagged(ticket)}
								<p class="ticket-warn" role="status">{m.configure_publish_ticket_untagged()}</p>
							{/if}
						</li>
					{/each}
				</ul>

				<div class="actions">
					<button class="publish-btn" type="button" onclick={handleContinue}>
						{m.configure_publish_report_continue({ domain: report.domain })}
					</button>
				</div>
			{:else}
				<!-- ── Publish form ───────────────────────────────────── -->
				<Dialog.Title class="publish-title">{m.configure_publish_title()}</Dialog.Title>
				<Dialog.Description class="publish-desc">
					{m.configure_publish_desc()}
				</Dialog.Description>

				{#if conflict}
					<!-- ── Overwrite confirmation (B-353): the typed name is a
						live domain. Nothing is re-sent without an explicit
						confirmation here. -->
					<div class="conflict-panel" role="alert">
						<p class="conflict-msg">
							{m.configure_publish_conflict_desc({ name: conflict.name })}
						</p>
						<div class="actions">
							<button class="cancel-btn" type="button" onclick={() => (conflict = undefined)}>
								{m.configure_publish_conflict_keep()}
							</button>
							<button
								class="publish-btn"
								type="button"
								disabled={submitting}
								onclick={() => handleSubmit(true)}
							>
								{submitting
									? m.configure_publishing_button()
									: m.configure_publish_overwrite_button({ name: conflict.name })}
							</button>
						</div>
					</div>
				{:else}
					<form
						onsubmit={(e) => {
							e.preventDefault();
							handleSubmit(false);
						}}
					>
						<label class="field-label" for="publish-name">{m.configure_publish_name_label()}</label>
						<input
							id="publish-name"
							class="name-input"
							class:invalid={trimmed.length > 0 && !valid}
							bind:value={name}
							placeholder={m.configure_publish_name_placeholder()}
							autocomplete="off"
						/>
						{#if trimmed.length > 0 && startsWithUnderscore}
							<p class="hint err" role="alert">{m.configure_publish_underscore_error()}</p>
						{:else if trimmed.length > 0 && !valid}
							<p class="hint err" role="alert">
								{m.configure_publish_invalid_error()}
							</p>
						{:else}
							<p class="hint">{m.configure_publish_name_helper()}</p>
						{/if}

						{#if check && check.issue_count > 0}
							<div class="warn-panel" role="status">
								<span class="warn-head">
									{check.issue_count === 1
										? m.configure_publish_warnings_singular({ count: check.issue_count })
										: m.configure_publish_warnings_plural({ count: check.issue_count })}
								</span>
								<ul class="warn-list">
									{#each check.domain_issues as issue, i (i)}
										<li class="warn-item">
											<span class="cat mono">{issue.category}</span>
											<span class="msg">{issue.message}</span>
										</li>
									{/each}
									{#each check.doctypes as dt (dt.doctype_id)}
										{#each dt.issues as issue, i (`${dt.doctype_id}-${i}`)}
											<li class="warn-item">
												<span class="cat mono">{issue.category}</span>
												<span class="msg">
													<span class="dt-id mono">{dt.doctype_id}</span>
													{issue.message}
												</span>
											</li>
										{/each}
									{/each}
								</ul>
								<p class="warn-note">
									{m.configure_publish_warnings_note()}
								</p>
							</div>
						{:else if check && check.issue_count === 0}
							<p class="ok-note">{m.configure_publish_ok_note()}</p>
						{:else if draftDomain}
							<p class="hint">{m.configure_publish_loading()}</p>
						{/if}

						{#if doctypes.length > 0}
							<!-- ── Documents: opt-in carry of draft rows ─────────── -->
							<div class="documents-block">
								<label class="documents-toggle">
									<input
										type="checkbox"
										bind:checked={importDocuments}
										data-testid="import-documents"
									/>
									<span>{m.configure_publish_import_documents()}</span>
								</label>
								{#if importDocuments}
									<p class="hint">{m.configure_publish_import_documents_desc()}</p>
									{#if importable.length > 0}
										<label class="documents-toggle select-all">
											<input
												type="checkbox"
												checked={allSelected}
												onchange={(e) => toggleAll(e.currentTarget.checked)}
												data-testid="import-documents-all"
											/>
											<span>{m.configure_publish_import_documents_all()}</span>
										</label>
									{/if}
									<ul class="documents-list">
										{#each doctypes as dt (dt.name)}
											<li class="document-row" class:disabled={dt.exists}>
												<label class="documents-toggle">
													<input
														type="checkbox"
														disabled={dt.exists}
														checked={!dt.exists && selected.includes(dt.name)}
														onchange={(e) => toggleDoctype(dt.name, e.currentTarget.checked)}
														data-testid="import-doctype-{dt.name}"
													/>
													<span class="mono">{dt.name}</span>
												</label>
												<span class="document-count">{dt.count}</span>
												{#if dt.exists}
													<span class="document-note">
														{m.configure_publish_import_documents_exists()}
													</span>
												{/if}
											</li>
										{/each}
									</ul>
								{/if}
							</div>
						{/if}

						<div class="actions">
							<button class="cancel-btn" type="button" onclick={() => (open = false)}>
								{m.common_cancel()}
							</button>
							<button class="publish-btn" type="submit" disabled={!valid || submitting}>
								{submitting
									? m.configure_publishing_button()
									: check && check.issue_count > 0
										? check.issue_count === 1
											? m.configure_publish_with_warning_singular({ count: check.issue_count })
											: m.configure_publish_with_warnings_plural({ count: check.issue_count })
										: m.configure_publish_button()}
							</button>
						</div>
					</form>
				{/if}

				{#if error}
					<p class="err" role="alert">{error}</p>
				{/if}

				<Dialog.Close class="close-btn" title={m.common_close()}>
					<X size={16} stroke-width={1.8} />
				</Dialog.Close>
			{/if}
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.publish-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.publish-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(520px, 90vw);
		max-height: 86vh;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 20px;
		gap: 12px;
	}

	:global(.publish-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.publish-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.field-label {
		font-size: 12px;
		color: var(--text-2, var(--text));
		font-weight: 600;
	}

	.name-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: inherit;
		margin-top: 4px;
	}

	.name-input.invalid {
		border-color: var(--danger);
	}

	.name-input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.hint {
		font-size: 12px;
		color: var(--text-3);
		margin: 4px 0 0;
		line-height: 1.4;
	}

	.hint.err {
		color: var(--danger);
	}

	.warn-panel {
		margin-top: 8px;
		padding: 12px;
		border: 1px solid var(--warn, var(--border-strong, var(--border)));
		border-radius: var(--r);
		background: var(--warn-weak, rgba(217, 119, 6, 0.08));
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.warn-head {
		font-size: 12px;
		font-weight: 600;
		color: var(--warn);
	}

	.warn-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-height: 160px;
		overflow-y: auto;
	}

	.warn-item {
		display: grid;
		grid-template-columns: 100px 1fr;
		gap: 8px;
		font-size: 12px;
		line-height: 1.4;
		align-items: start;
	}

	.warn-item .cat {
		color: var(--warn);
		text-transform: uppercase;
		font-size: 11px;
		letter-spacing: 0.04em;
		padding-top: 1px;
	}

	.warn-item .msg {
		color: var(--text-2, var(--text));
	}

	.warn-item .msg .dt-id {
		color: var(--text);
		margin-right: 4px;
	}

	.warn-note {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 4px 0 0;
		line-height: 1.4;
	}

	.ok-note {
		font-size: 12.5px;
		color: var(--ok);
		margin: 4px 0 0;
	}

	/* ── Documents block ─────────────────────────────────────────── */
	.documents-block {
		margin-top: 12px;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.documents-toggle {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 13px;
		color: var(--text);
		cursor: pointer;
	}

	.documents-toggle.select-all {
		font-size: 12px;
		color: var(--text-2, var(--text));
	}

	.documents-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-height: 180px;
		overflow-y: auto;
	}

	.document-row {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.document-row.disabled {
		opacity: 0.6;
	}

	.document-row .documents-toggle {
		flex: 1;
		font-size: 12.5px;
	}

	.document-count {
		font-size: 11.5px;
		color: var(--text-3);
		font-variant-numeric: tabular-nums;
	}

	.document-note {
		font-size: 11px;
		color: var(--text-3);
	}

	/* ── Overwrite confirmation (B-353) ───────────────────────── */
	.conflict-panel {
		margin-top: 8px;
		padding: 12px;
		border: 1px solid var(--warn, var(--border-strong, var(--border)));
		border-radius: var(--r);
		background: var(--warn-weak, rgba(217, 119, 6, 0.08));
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.conflict-msg {
		font-size: 12.5px;
		color: var(--text-2, var(--text));
		margin: 0;
		line-height: 1.45;
	}

	/* ── Post-publish ticket report ────────────────────────────────── */
	.ticket-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
	.ticket {
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 10px 12px;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.ticket-head {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.ticket-producer {
		font-size: 13px;
		font-weight: 600;
	}
	.ticket-head .sp {
		flex: 1;
	}
	.ticket-state {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--warn);
	}
	.ticket-state.ok {
		color: var(--ok);
	}
	.ticket-kind {
		font-size: 12px;
		color: var(--text-2);
		margin: 0;
	}
	.edge-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.edge {
		font-size: 11.5px;
		color: var(--text-2);
	}
	.ticket-warn {
		font-size: 11.5px;
		color: var(--warn);
		margin: 0;
		line-height: 1.4;
	}

	.mono {
		font-family: var(--font-mono);
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 10px;
	}

	.cancel-btn,
	.publish-btn {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.cancel-btn {
		border: 1px solid var(--border-strong, var(--border));
		background: var(--surface);
		color: var(--text);
	}

	.cancel-btn:hover {
		background: var(--sunken, var(--surface));
	}

	.publish-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		color: var(--on-accent, #1a1a1a);
	}

	.publish-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.err {
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak, rgba(220, 38, 38, 0.08));
		border-radius: var(--r);
	}

	:global(.close-btn) {
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

	:global(.close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
