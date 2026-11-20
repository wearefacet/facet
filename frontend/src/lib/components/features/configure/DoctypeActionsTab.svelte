<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { ActionDef } from '$lib/doctype/types.js';
	import { sanitizeKeyInput } from '$lib/doctype/keys.js';
	import { FIELD_TYPE_OPTIONS } from './field-type-options.js';
	import Toggle from '../../primitives/forms/Toggle.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		actions,
		readonly = false,
		onadd,
		ondelete,
		onaddarg,
		ondeletearg
	}: {
		/** Working-copy actions owned by the parent; entries are mutated in place. */
		actions: ActionDef[];
		readonly?: boolean;
		/** Add an action — the parent owns the working copy and appends the entry. */
		onadd: () => void;
		ondelete: (action: ActionDef) => void;
		/** Add an argument to `action` — appended by the parent. */
		onaddarg: (action: ActionDef) => void;
		ondeletearg: (action: ActionDef, arg: ActionDef['args'][number]) => void;
	} = $props();
</script>

<div class="scrollpane">
	<div class="maxw">
		{#each actions as action (action.key)}
			<div class="card">
				<div class="ch">
					<input
						class="inp mono keyinp"
						value={action.key}
						oninput={(e) =>
							(action.key = sanitizeKeyInput((e.currentTarget as HTMLInputElement).value))}
						disabled={readonly}
					/>
					<span class="sp"></span>
					{#if !readonly}
						<button
							class="btn sm ghost del-btn"
							aria-label={m.configure_doctypes_delete_action_aria()}
							onclick={() => ondelete(action)}
						>
							<svg
								width="15"
								height="15"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="1.8"
							>
								<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
							</svg>
						</button>
					{/if}
				</div>
				<div class="grid2">
					<div class="f wide">
						<label class="field-label" for="action-desc-{action.key}"
							>{m.common_description()}</label
						>
						<textarea
							id="action-desc-{action.key}"
							class="inp textarea"
							rows="2"
							value={action.description ?? ''}
							oninput={(e) =>
								(action.description = (e.currentTarget as HTMLTextAreaElement).value || undefined)}
							disabled={readonly}></textarea>
					</div>
				</div>
				<div class="args">
					<div class="args-h">
						<span>{m.configure_doctypes_arguments_label()}</span>
						{#if !readonly}
							<button class="arg-add" onclick={() => onaddarg(action)}>
								{m.configure_doctypes_add_arg_button()}
							</button>
						{/if}
					</div>
					{#each action.args as arg (arg.key)}
						<div class="argrow">
							<input
								class="inp mono an"
								value={arg.key}
								oninput={(e) =>
									(arg.key = sanitizeKeyInput((e.currentTarget as HTMLInputElement).value))}
								disabled={readonly}
							/>
							<div class="at">
								<Select options={FIELD_TYPE_OPTIONS} bind:value={arg.type} {readonly} />
							</div>
							<Toggle
								label={m.configure_doctypes_required_label()}
								checked={arg.required ?? false}
								onchange={() => (arg.required = !(arg.required ?? false))}
								{readonly}
							/>
							{#if !readonly}
								<button
									class="btn sm ghost arg-del"
									aria-label={m.configure_doctypes_delete_arg_aria()}
									onclick={() => ondeletearg(action, arg)}
								>
									<svg
										width="14"
										height="14"
										viewBox="0 0 24 24"
										fill="none"
										stroke="currentColor"
										stroke-width="2"
									>
										<path d="M18 6 6 18M6 6l12 12" />
									</svg>
								</button>
							{/if}
						</div>
					{:else}
						<div class="args-empty">{m.configure_doctypes_args_empty()}</div>
					{/each}
				</div>
			</div>
		{/each}
		{#if !readonly}
			<button class="addbtn" style="max-width:none" onclick={onadd}>
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
				{m.configure_doctypes_add_action_button()}
			</button>
		{/if}
	</div>
</div>

<style>
	.scrollpane {
		overflow: auto;
		height: 100%;
	}

	.maxw {
		max-width: 720px;
		padding: 20px 24px;
	}

	.card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		padding: 16px;
		margin-bottom: 12px;
	}

	.card .ch {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 14px;
	}
	.card .ch .sp {
		flex: 1;
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
	.inp:disabled {
		opacity: 0.55;
		cursor: not-allowed;
	}
	.textarea {
		resize: vertical;
		font-family: var(--font-sans);
		line-height: 1.5;
	}
	.field-label {
		font-size: 12.5px;
		font-weight: 600;
	}

	.btn {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 8px 13px;
		border-radius: var(--r);
		font-size: 13px;
		font-weight: 600;
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		cursor: pointer;
		font: inherit;
	}
	.btn:hover {
		border-color: var(--border-strong);
		background: var(--surface-2);
	}
	.btn.ghost {
		border-color: transparent;
		color: var(--text-2);
	}
	.btn.ghost:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.btn.sm {
		padding: 6px 10px;
		font-size: 12.5px;
	}

	.del-btn {
		color: var(--danger);
	}
	.del-btn:hover {
		background: var(--danger-weak);
		border-color: transparent;
		color: var(--danger);
	}

	.arg-del {
		background: none;
		border: none;
		padding: 4px;
		color: var(--text-3);
		cursor: pointer;
		border-radius: 4px;
		display: flex;
		align-items: center;
	}
	.arg-del:hover {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.args {
		margin-top: 12px;
	}
	.args-h {
		display: flex;
		align-items: center;
		justify-content: space-between;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		margin-bottom: 8px;
	}
	.arg-add {
		margin-left: auto;
		border: none;
		background: none;
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		color: var(--accent);
		cursor: pointer;
		padding: 4px 6px;
		border-radius: var(--r-sm);
	}
	.arg-add:hover {
		text-decoration: underline;
	}
	.args-empty {
		font-size: 12px;
		color: var(--text-3);
		padding: 6px 0;
	}

	.argrow {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 6px 0;
	}

	.argrow .an {
		font-family: var(--font-mono);
		width: 140px;
		flex: none;
	}

	.argrow .at {
		flex: 1;
		min-width: 0;
	}
	.argrow .at :global(.select-field-wrap) {
		width: 100%;
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
