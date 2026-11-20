<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import CodeEditor from '../../primitives/forms/CodeEditor.svelte';
	import type { ExportedFn } from '$lib/doctype/lua-symbols.js';
	import * as m from '$lib/paraglide/messages';

	let {
		script = $bindable(''),
		symbols,
		doctypeLabel,
		readonly = false
	}: {
		/** Lua module source, two-way bound to the parent's working copy. */
		script?: string;
		/** Symbols the current script exports, computed by the parent. */
		symbols: ExportedFn[];
		/** Doctype label for the editor filename badge, e.g. "deal.lua". */
		doctypeLabel: string;
		readonly?: boolean;
	} = $props();
</script>

<div class="lualayout">
	<div class="symbols">
		<div class="sh">{m.configure_doctypes_exported_functions()}</div>
		{#each symbols as sym (sym.name)}
			<div class="sym" class:on={sym.kind !== 'function'}>
				<span class="fn">{sym.name}</span>
				<span class="bind"
					>{sym.kind}{#if sym.bound}
						· {sym.bound}{/if}</span
				>
			</div>
		{:else}
			<div class="sym-empty">{m.configure_doctypes_symbols_empty()}</div>
		{/each}
	</div>
	<div class="codewrap">
		<CodeEditor
			bind:value={script}
			language="lua"
			label="{doctypeLabel.toLowerCase()}.lua"
			helper={m.configure_doctypes_lua_helper()}
			minHeight="300px"
			{readonly}
		/>
	</div>
</div>

<style>
	.lualayout {
		display: grid;
		grid-template-columns: 200px 1fr;
		height: 100%;
		overflow: hidden;
	}

	.symbols {
		border-right: 1px solid var(--border);
		overflow: auto;
		padding: 16px;
		background: var(--surface-2);
	}
	.symbols .sh {
		font-size: 11px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.05em;
		margin-bottom: 12px;
	}
	.sym {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 7px 10px;
		border-radius: var(--r);
		border: 1px solid var(--border);
		background: var(--surface);
		margin-bottom: 4px;
	}
	.sym:hover {
		border-color: var(--border-strong);
	}
	.sym.on {
		background: var(--accent-weak);
		border-color: var(--accent);
	}
	.sym .fn {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 500;
	}
	.sym .bind {
		font-size: 10.5px;
		color: var(--text-3);
	}
	.sym-empty {
		font-size: 12px;
		color: var(--text-3);
		padding: 12px 0;
	}
	.codewrap {
		overflow: hidden;
		display: flex;
		flex-direction: column;
		height: 100%;
	}
</style>
