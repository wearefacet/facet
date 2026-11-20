<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Copy, Check } from '@lucide/svelte';
	import { copyText } from '$lib/clipboard.js';
	import { humanizeRoleName, roleDocIdToName } from '$lib/authorization/roleMembership.js';
	import { listMcpEndpoints, type McpEndpoint } from '$lib/mcp/endpoints.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * McpEndpoints — the MCP endpoint directory for the caller's roles.
	 *
	 * Renders the body only: the host surface (the personal settings page)
	 * owns the section chrome. Rows list one endpoint per held role with a
	 * copy action; the API surface is injectable for stories.
	 */

	let {
		/** Injectable endpoint list — stories and tests pass mocks here. */
		endpoints = undefined as McpEndpoint[] | undefined,
		/** Injectable API surface — stories pass a mock resolver here. */
		loadEndpoints = listMcpEndpoints
	}: {
		endpoints?: McpEndpoint[];
		loadEndpoints?: typeof listMcpEndpoints;
	} = $props();

	let rows = $state<McpEndpoint[] | null>(null);
	let loadError = $state<string | undefined>(undefined);
	let copiedRole = $state<string | null>(null);

	// Initial load — the effect reads only the `endpoints` prop, so it cannot
	// loop on the state it writes.
	$effect(() => {
		if (endpoints) {
			rows = endpoints;
			return;
		}
		loadEndpoints()
			.then((list) => (rows = list))
			.catch((e: unknown) => {
				loadError = errorMessage(e, m.mcp_load_error());
			});
	});

	// Clear the "Copied" marker shortly after a copy.
	$effect(() => {
		if (!copiedRole) return;
		const t = setTimeout(() => (copiedRole = null), 2000);
		return () => clearTimeout(t);
	});

	/** Role label for a row (`iam.Roles.editor` → `Editor`). */
	function roleLabel(roleId: string): string {
		return humanizeRoleName(roleDocIdToName(roleId));
	}

	async function copyUrl(ep: McpEndpoint) {
		if (await copyText(ep.url)) copiedRole = ep.role;
	}
</script>

{#if rows === null && !loadError}
	<p class="status">{m.common_loading()}</p>
{:else if loadError}
	<p class="load-error" role="alert">{loadError}</p>
{:else if rows !== null && rows.length === 0}
	<p class="empty">{m.mcp_empty()}</p>
{:else if rows !== null}
	<div class="rows">
		{#each rows as ep (ep.role)}
			<div class="row">
				<span class="role">{roleLabel(ep.role)}</span>
				<code class="url">{ep.url}</code>
				<button
					class="copy-btn"
					class:copied={copiedRole === ep.role}
					type="button"
					onclick={() => copyUrl(ep)}
					title={m.mcp_copy_aria()}
				>
					{#if copiedRole === ep.role}
						<Check size={14} stroke-width={2} />
						<span>{m.common_copied()}</span>
					{:else}
						<Copy size={14} stroke-width={1.8} />
						<span>{m.common_copy()}</span>
					{/if}
				</button>
			</div>
		{/each}
	</div>
{/if}

<style>
	.rows {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.row {
		display: flex;
		align-items: stretch;
		gap: 8px;
	}

	.role {
		flex: none;
		display: inline-flex;
		align-items: center;
		min-width: 110px;
		max-width: 180px;
		padding: 0 10px;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.url {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 10px 12px;
		overflow-x: auto;
		white-space: nowrap;
		user-select: all;
	}

	.copy-btn {
		flex: none;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 0 14px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface-2);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.copy-btn:hover {
		background: var(--sunken);
	}

	.copy-btn.copied {
		border-color: var(--ok);
		background: var(--ok-weak);
		color: var(--ok);
	}

	.copy-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.status,
	.empty {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 0;
	}

	.load-error {
		font-size: 12.5px;
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 10px 12px;
		margin: 0;
	}
</style>
