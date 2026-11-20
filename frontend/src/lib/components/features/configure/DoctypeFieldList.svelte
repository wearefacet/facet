<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { FieldDef } from '$lib/doctype/types.js';
	import * as m from '$lib/paraglide/messages';

	let {
		fields,
		selectedField,
		readonly = false,
		onselect,
		onadd
	}: {
		fields: FieldDef[];
		selectedField?: FieldDef;
		readonly?: boolean;
		onselect?: (field: FieldDef) => void;
		onadd?: () => void;
	} = $props();
</script>

<div class="flist">
	<div class="lh">
		{m.configure_doctypes_tab_fields()} <span class="sp"></span>
	</div>

	<div id="frows">
		{#each fields as field (field.key)}
			<button class="frow" class:sel={field === selectedField} onclick={() => onselect?.(field)}>
				<div class="mid">
					<div class="fk">
						{field.key}{#if field.required}<span class="rq">*</span>{/if}
					</div>
					{#if field.title}
						<div class="ft">{field.title}</div>
					{/if}
				</div>
				<span class="ty">
					{field.type}{#if field.compute}
						·fx{/if}
				</span>
			</button>
		{/each}
	</div>

	{#if !readonly}
		<button class="addbtn" onclick={onadd}>
			<svg
				width="15"
				height="15"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
				viewBox="0 0 24 24"
			>
				<path d="M12 5v14M5 12h14" />
			</svg>
			{m.configure_doctypes_add_field_button()}
		</button>
	{/if}
</div>

<style>
	.flist {
		border-right: 1px solid var(--border);
		overflow: auto;
		background: var(--surface-2);
		padding: 12px;
	}

	.lh {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 4px 6px 12px;
		color: var(--text-3);
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.05em;
		text-transform: uppercase;
	}
	.lh .sp {
		flex: 1;
	}

	.frow {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 9px 10px;
		border: 1px solid transparent;
		border-radius: var(--r);
		cursor: pointer;
		margin-bottom: 3px;
		width: 100%;
		text-align: left;
		font: inherit;
		color: inherit;
		background: none;
	}
	.frow:hover {
		background: var(--surface);
		border-color: var(--border);
	}
	.frow.sel {
		background: var(--surface);
		border-color: var(--accent);
		box-shadow: 0 0 0 2px var(--accent-weak);
	}

	.fk {
		font-family: var(--font-mono);
		font-size: 12.5px;
		font-weight: 500;
	}
	.ft {
		font-size: 11px;
		color: var(--text-3);
		margin-top: 1px;
	}
	.frow .mid {
		min-width: 0;
		flex: 1;
	}
	.ty {
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-2);
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: 5px;
		padding: 1px 6px;
		white-space: nowrap;
		flex-shrink: 0;
	}
	.rq {
		color: var(--danger);
		font-weight: 700;
		font-size: 12px;
	}
	.addbtn {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		width: 100%;
		padding: 10px;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r);
		color: var(--text-2);
		font-size: 12.5px;
		font-weight: 600;
		margin-top: 8px;
		background: transparent;
		font: inherit;
		cursor: pointer;
	}
	.addbtn:hover {
		border-color: var(--accent);
		color: var(--accent-ink);
	}
</style>
