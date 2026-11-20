<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { ContextSetRow } from './domainSecurity.js';
	import * as m from '$lib/paraglide/messages';

	let {
		row,
		doctypeNames,
		onremove,
		onaddwhere,
		onremovewhere
	}: {
		/** The context-set row — mutated in place (same deep-proxy writes as
		 *  before the split); the parent's working copy stays the owner. */
		row: ContextSetRow;
		/** Selectable source doctype names for the `from` picker. */
		doctypeNames: string[];
		onremove: () => void;
		/** Append a where entry; the parent owns the row list. */
		onaddwhere: () => void;
		/** Remove the where entry at `index`. */
		onremovewhere: (index: number) => void;
	} = $props();

	// Unique per-instance suffix so stacked context-set cards don't produce
	// duplicate DOM IDs (same approach as ReferencePicker).
	const uid = Math.random().toString(36).slice(2, 10);
</script>

<div class="card">
	<div class="ch">
		<span class="mono">${row.name || 'unnamed'}</span>
		<span class="sp"></span>
		<button
			class="icon-btn danger"
			aria-label={m.configure_domains_remove_context_set_aria()}
			onclick={onremove}
		>
			<svg
				width="14"
				height="14"
				viewBox="0 0 24 24"
				fill="none"
				stroke="currentColor"
				stroke-width="1.8"
			>
				<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
			</svg>
		</button>
	</div>
	<div class="grid2">
		<div class="f">
			<label for={`cs-name-${uid}`}>{m.common_name()}</label>
			<input
				id={`cs-name-${uid}`}
				class="inp mono"
				value={row.name}
				oninput={(e) => (row.name = (e.target as HTMLInputElement).value)}
			/>
		</div>
		<div class="f">
			<label for={`cs-from-${uid}`}>{m.configure_domains_from_label()}</label>
			<select
				id={`cs-from-${uid}`}
				class="inp"
				value={row.from}
				onchange={(e) => (row.from = (e.target as HTMLSelectElement).value)}
			>
				<option value="">{m.configure_select_placeholder()}</option>
				{#each doctypeNames as name (name)}
					<option value={name}>{name}</option>
				{/each}
			</select>
		</div>
		<div class="f wide">
			<label for={`cs-select-${uid}`}>{m.configure_domains_select_field_label()}</label>
			<input
				id={`cs-select-${uid}`}
				class="inp mono"
				placeholder={m.configure_domains_select_field_placeholder()}
				value={row.select}
				oninput={(e) => (row.select = (e.target as HTMLInputElement).value)}
			/>
		</div>
	</div>

	<div class="where-block">
		<div class="where-head">
			<span class="where-label">{m.configure_domains_where_label()}</span>
			<button class="addbtn sm" onclick={onaddwhere}>
				{m.configure_domains_add_where_button()}
			</button>
		</div>
		{#each row.where as entry, widx (widx)}
			<div class="where-row">
				<input
					class="inp mono where-key"
					aria-label={m.configure_domains_where_key_aria({ name: row.name || 'context set' })}
					value={entry.key}
					oninput={(e) => (entry.key = (e.target as HTMLInputElement).value)}
				/>
				<span class="where-eq">=</span>
				<input
					class="inp mono where-val"
					aria-label={m.configure_domains_where_value_aria({
						name: row.name || 'context set',
						key: entry.key
					})}
					value={entry.value}
					placeholder={m.configure_domains_where_value_placeholder()}
					oninput={(e) => (entry.value = (e.target as HTMLInputElement).value)}
				/>
				<button
					class="icon-btn danger"
					aria-label={m.configure_domains_remove_where_aria()}
					onclick={() => onremovewhere(widx)}
				>
					<svg
						width="12"
						height="12"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
					>
						<path d="M18 6 6 18M6 6l12 12" />
					</svg>
				</button>
			</div>
		{:else}
			<div class="where-empty">{m.configure_domains_where_empty()}</div>
		{/each}
	</div>
</div>

<style>
	/* ── Cards (context sets) ──────────────────────────────────────────── */
	.card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		padding: 14px 16px;
		margin-bottom: 12px;
	}
	.card .ch {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 12px;
	}
	.card .ch .sp {
		flex: 1;
	}
	.mono {
		font-family: var(--font-mono);
	}

	.grid2 {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 15px 18px;
	}
	.f {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.f.wide {
		grid-column: 1 / -1;
	}
	.f label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}
	.inp {
		padding: 8px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		font: inherit;
		font-size: 13px;
		color: var(--text);
		width: 100%;
	}
	.inp.mono {
		font-family: var(--font-mono);
	}
	.inp:focus {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.icon-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 26px;
		height: 26px;
		border: 1px solid transparent;
		border-radius: var(--r-sm);
		background: none;
		cursor: pointer;
		color: var(--text-3);
		transition:
			background 0.1s,
			color 0.1s;
	}
	.icon-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.icon-btn.danger:hover {
		color: var(--danger);
		background: var(--danger-weak);
	}

	.addbtn.sm {
		font: inherit;
		font-size: 11px;
		font-weight: 600;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border: 1px solid transparent;
		border-radius: var(--r);
		padding: 3px 8px;
		cursor: pointer;
		transition:
			background 0.12s,
			border-color 0.12s;
	}
	.addbtn.sm:hover {
		border-color: var(--accent);
	}

	/* ── Context set `where` editor ────────────────────────────────────── */
	.where-block {
		margin-top: 14px;
		padding-top: 12px;
		border-top: 1px solid var(--border);
	}
	.where-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		margin-bottom: 8px;
	}
	.where-label {
		font-size: 11px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--text-3);
	}
	.where-row {
		display: flex;
		align-items: center;
		gap: 7px;
		margin-bottom: 7px;
	}
	.where-key {
		flex: 0 0 40%;
	}
	.where-eq {
		color: var(--text-3);
		font-family: var(--font-mono);
		font-size: 12px;
	}
	.where-val {
		flex: 1;
	}

	.where-empty {
		font-size: 12px;
		color: var(--text-3);
		padding: 4px 0;
	}

	@media (max-width: 720px) {
		.grid2 {
			grid-template-columns: 1fr;
		}
	}
</style>
