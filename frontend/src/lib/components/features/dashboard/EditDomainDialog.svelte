<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { flattenNavDoctypes, type NavDomain } from '$lib/navTypes';
	import { can } from '$lib/permissions.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/** Live domains the user can pick to draft-from. */
		liveDomains = [],
		/** Called when the user picks a live domain to edit as a draft. */
		onselect = (_domainId: string) => {},
		/** Optional error message to surface (e.g. a 409 "draft already exists"). */
		error = undefined
	}: {
		open?: boolean;
		liveDomains?: NavDomain[];
		onselect?: (domainId: string) => void;
		error?: string | undefined;
	} = $props();

	function handlePick(domainId: string) {
		onselect(domainId);
	}

	// The backend gates `POST /Api/core/Domain/:id/draft` with the same
	// `create` permission on `core.Domain` for every source domain, so one
	// store check covers the whole list. Fail-closed: no manifest → disabled.
	const canDraft = $derived(can('core.Domain', 'create'));
	const editDisabledTitle = $derived(canDraft ? undefined : m.builder_edit_domain_forbidden());
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="edit-domain-overlay" />
		<Dialog.Content class="edit-domain-content">
			<Dialog.Title class="edit-domain-title">{m.dashboard_edit_domain_title()}</Dialog.Title>
			<Dialog.Description class="edit-domain-desc">
				{m.dashboard_edit_domain_helper()}
			</Dialog.Description>

			{#if liveDomains.length === 0}
				<p class="empty">{m.dashboard_edit_domain_empty()}</p>
			{:else}
				<ul class="domain-list">
					{#each liveDomains as d (d.id)}
						<li>
							<span class="dot" style={`background:${d.color}`}></span>
							<span class="label">{d.label}</span>
							<span class="count"
								>{m.configure_domains_doctypes_short({
									count: flattenNavDoctypes(d.doctypes).length
								})}</span
							>
							<button
								class="edit-btn"
								type="button"
								disabled={!canDraft}
								title={editDisabledTitle}
								onclick={() => handlePick(d.id)}
							>
								{m.common_edit()}
							</button>
						</li>
					{/each}
				</ul>
			{/if}

			{#if error}
				<p class="err" role="alert">{error}</p>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.edit-domain-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.edit-domain-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(520px, 90vw);
		max-height: 70vh;
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

	:global(.edit-domain-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.edit-domain-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	.domain-list {
		list-style: none;
		margin: 0;
		padding: 0;
		overflow-y: auto;
		flex: 1;
		min-height: 0;
	}

	.domain-list li {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 8px 0;
		border-bottom: 1px solid var(--border);
	}

	.domain-list li:last-child {
		border-bottom: none;
	}

	.dot {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	.label {
		font-weight: 600;
		font-size: 13px;
		color: var(--text);
	}

	.count {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.edit-btn {
		margin-left: auto;
		padding: 5px 12px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		flex: none;
	}

	.edit-btn:hover:not(:disabled) {
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` equals the accent fill in
		   dark theme (tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
		border-color: var(--accent);
	}

	.edit-btn:disabled {
		opacity: 0.45;
		cursor: not-allowed;
	}

	.edit-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.empty {
		font-size: 13px;
		color: var(--text-3);
		padding: 16px 0;
		text-align: center;
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
