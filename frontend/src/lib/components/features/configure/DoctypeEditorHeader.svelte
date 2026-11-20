<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DoctypeIcon from '../../primitives/data/DoctypeIcon.svelte';
	import { getDomainLabel } from '$lib/navState.svelte';
	import { resolve } from '$app/paths';
	import type { SaveFlashStatus } from '$lib/utils/saveFlash.svelte.js';
	import * as m from '$lib/paraglide/messages';

	let {
		domain,
		doctypeLabel,
		qualifiedName,
		icon,
		color,
		aggregateRoot = false,
		schemaVersion,
		recordsHref,
		readonly = false,
		metadataEdit = false,
		flash,
		draftCreating = false,
		onsave,
		oncreatedraft
	}: {
		/** Domain id the doctype belongs to (breadcrumb link + label). */
		domain: string;
		/** Doctype label shown in the breadcrumb and as the page title. */
		doctypeLabel: string;
		/** Qualified doctype name, e.g. "crm.Deal" — shown as the mono id. */
		qualifiedName: string;
		/** Stored Lucide icon name (parent coerces to ''). */
		icon?: string;
		/** Accent color for the doctype mark (parent coerces to ''). */
		color?: string;
		aggregateRoot?: boolean;
		schemaVersion?: number;
		/** Workspace surface of this doctype's records; hides the link when absent. */
		recordsHref?: string;
		/** Published doctype — shape changes need a draft. */
		readonly?: boolean;
		/** Published surface with metadata editing: shows the Save button next
		 *  to the published note, and renders the draft button as a secondary
		 *  action (the save is the primary affordance here). */
		metadataEdit?: boolean;
		/** Save-flash state from the parent's `createSaveFlash()` (status + message). */
		flash: { status: SaveFlashStatus; message?: string };
		/** Set while the create-draft request is in flight. */
		draftCreating?: boolean;
		onsave: () => void;
		oncreatedraft: () => void;
	} = $props();
</script>

<div class="crumb">
	<a href={resolve('/Builder')}>{m.nav_builder()}</a><span class="sep">/</span>
	<a href={resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: domain })}
		>{getDomainLabel(domain)}</a
	><span class="sep">/</span>
	<b>{doctypeLabel}</b>
</div>
<div class="idrow">
	<DoctypeIcon {icon} {color} />
	<h1>{doctypeLabel}</h1>
	<span class="dom">{qualifiedName}</span>
	{#if aggregateRoot}
		<span class="rootbadge">
			<span class="d"></span>{m.configure_doctypes_aggregate_root()}
		</span>
	{/if}
	{#if schemaVersion}
		<span class="ver">{m.configure_doctypes_schema_version({ version: schemaVersion })}</span>
	{/if}
	<span class="sp"></span>
	{#if recordsHref}
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- recordsHref arrives from the host page, which builds it with resolve(). -->
		<a class="records-btn" href={recordsHref}>{m.configure_doctypes_open_records()}</a>
	{/if}
	{#if !readonly || metadataEdit}
		<button
			class="save-btn"
			class:saved={flash.status === 'saved'}
			class:error={flash.status === 'error'}
			onclick={onsave}
			disabled={flash.status === 'saving'}
			title={flash.message ?? ''}
		>
			{#if flash.status === 'saving'}
				{m.common_saving()}
			{:else if flash.status === 'saved'}
				{m.common_saved()}
			{:else if flash.status === 'error'}
				{flash.message
					? m.configure_save_failed_reason({ message: flash.message })
					: m.configure_save_failed()}
			{:else}
				{m.common_save()}
			{/if}
		</button>
	{/if}
	{#if readonly}
		<div class="readonly-bar">
			<span class="readonly-text">{m.configure_doctypes_published_note()}</span>
			<button
				class="create-draft-btn"
				class:secondary={metadataEdit}
				onclick={oncreatedraft}
				disabled={draftCreating}
			>
				{draftCreating
					? m.configure_doctypes_creating_draft_button()
					: m.configure_doctypes_create_draft_button()}
			</button>
		</div>
	{/if}
</div>

<style>
	.crumb {
		font-size: 12px;
		color: var(--text-3);
		margin-bottom: 8px;
	}
	.crumb a {
		color: var(--text-3);
		text-decoration: none;
	}
	.crumb a:hover {
		color: var(--accent);
		text-decoration: underline;
	}
	.crumb .sep {
		margin: 0 6px;
		opacity: 0.5;
	}
	.crumb b {
		color: var(--text);
	}

	.idrow {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 12px;
	}
	.idrow h1 {
		font-family: var(--font-display);
		font-size: 20px;
		font-weight: 600;
		letter-spacing: -0.01em;
		margin: 0;
	}
	.idrow .dom {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}
	.idrow .rootbadge {
		font-size: 10.5px;
		font-weight: 600;
		color: var(--info);
		background: var(--info-weak);
		border: 1px solid var(--info);
		border-radius: var(--r-pill);
		padding: 1px 8px;
		display: inline-flex;
		align-items: center;
		gap: 4px;
		letter-spacing: 0.02em;
	}
	.rootbadge .d {
		width: 5px;
		height: 5px;
		border-radius: 1px;
		background: currentColor;
		transform: rotate(45deg);
	}
	.idrow .ver {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 2px 7px;
	}
	.idrow .sp {
		flex: 1;
	}

	.save-btn {
		padding: 6px 16px;
		border-radius: var(--r);
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` equals the accent fill in
		   dark theme and renders the label invisible (tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
		font: inherit;
		font-size: 13px;
		font-weight: 600;
		cursor: pointer;
		transition: opacity 0.12s;
		flex: none;
	}
	.save-btn:hover:not(:disabled) {
		opacity: 0.85;
	}
	.save-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}
	.save-btn.saved {
		border-color: var(--ok);
		background: var(--ok);
		color: var(--ok-ink);
	}
	.save-btn.error {
		border-color: var(--danger);
		background: var(--danger);
		color: var(--danger-ink);
	}

	.readonly-bar {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	/* Secondary action next to the save button / readonly bar — opens the
	   doctype's workspace surface (Configure shell passes it for published
	   doctypes whose records the sidebar does not list, e.g. core.Currency). */
	.records-btn {
		padding: 6px 16px;
		border-radius: var(--r);
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		font: inherit;
		font-size: 13px;
		font-weight: 500;
		text-decoration: none;
		flex: none;
		transition: border-color 0.12s;
	}
	.records-btn:hover {
		border-color: var(--accent);
	}

	.readonly-text {
		font-size: 13px;
		color: var(--text-3);
	}

	.create-draft-btn {
		padding: 6px 16px;
		border-radius: var(--r);
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` equals the accent fill in
		   dark theme and renders the label invisible (tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
		font: inherit;
		font-size: 13px;
		font-weight: 600;
		cursor: pointer;
		transition: opacity 0.12s;
		flex: none;
	}
	.create-draft-btn:hover {
		opacity: 0.85;
	}
	.create-draft-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* When metadata editing puts Save next to it, the draft button steps
	   down to a secondary action so the row carries one gold fill only. */
	.create-draft-btn.secondary {
		border-color: var(--border);
		background: var(--surface);
		color: var(--text);
		font-weight: 500;
	}
	.create-draft-btn.secondary:hover {
		opacity: 1;
		border-color: var(--accent);
	}
</style>
