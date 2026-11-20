<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { ChildDef } from '$lib/doctype/types.js';
	import { sanitizeKeyInput } from '$lib/doctype/keys.js';
	import Input from '../../primitives/forms/Input.svelte';
	import Toggle from '../../primitives/forms/Toggle.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		children,
		doctypeLabel,
		readonly = false,
		onadd,
		ondelete
	}: {
		/** Working-copy children owned by the parent; entries are mutated in place. */
		children: ChildDef[];
		/** Parent doctype label for the cascade note. */
		doctypeLabel: string;
		readonly?: boolean;
		/** Add a child — the parent owns the working copy and appends the entry. */
		onadd: () => void;
		ondelete: (child: ChildDef) => void;
	} = $props();
</script>

<div class="scrollpane">
	<div class="maxw">
		{#each children as child (child.key)}
			<div class="card">
				<div class="ch">
					<span class="cap" style="--tint:var(--info)"
						><span class="fx"></span>{child.doctype || '—'}</span
					>
					<input
						class="inp mono keyinp"
						value={child.key}
						oninput={(e) =>
							(child.key = sanitizeKeyInput((e.currentTarget as HTMLInputElement).value))}
						disabled={readonly}
					/>
					<span class="badge muted"
						>{child.collection
							? m.configure_doctypes_badge_collection()
							: m.configure_doctypes_badge_single()}</span
					>
					<span class="sp"></span>
					{#if !readonly}
						<button
							class="btn sm ghost del-btn"
							aria-label={m.configure_doctypes_delete_child_aria()}
							onclick={() => ondelete(child)}
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
					<div class="f">
						<Input
							label={m.configure_doctypes_child_doctype_label()}
							placeholder={m.configure_doctypes_child_doctype_placeholder()}
							value={child.doctype}
							oninput={(e) => (child.doctype = (e.currentTarget as HTMLInputElement).value)}
							disabled={readonly}
						/>
					</div>
					<div class="f">
						<Toggle
							label={m.configure_doctypes_child_collection_label()}
							checked={child.collection ?? true}
							onchange={() => (child.collection = !(child.collection ?? true))}
							{readonly}
						/>
					</div>
					<div class="f wide">
						<label class="field-label" for="child-desc-{child.key}">{m.common_description()}</label>
						<textarea
							id="child-desc-{child.key}"
							class="inp textarea"
							rows="2"
							value={child.description ?? ''}
							oninput={(e) =>
								(child.description = (e.currentTarget as HTMLTextAreaElement).value || undefined)}
							disabled={readonly}></textarea>
					</div>
				</div>
				<div class="note">
					<svg
						class="ic"
						width="15"
						height="15"
						fill="none"
						stroke="currentColor"
						stroke-width="1.8"
						viewBox="0 0 24 24"
					>
						<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6" />
					</svg>
					<div>
						<b
							>{m.configure_doctypes_cascade_note({
								doctype: doctypeLabel,
								child: child.key
							})}</b
						>
					</div>
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
				{m.configure_doctypes_add_child_button()}
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

	.cap {
		font-family: var(--font-mono);
		font-size: 12.5px;
		font-weight: 600;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 2px 10px;
		border-radius: var(--r-pill);
		border: 1px solid var(--tint);
		background: color-mix(in srgb, var(--tint) 12%, transparent);
		color: var(--tint);
	}
	.cap .fx {
		width: 6px;
		height: 6px;
		border-radius: 1px;
		background: currentColor;
		transform: rotate(45deg);
	}

	.badge {
		font-size: 10.5px;
		font-weight: 600;
		padding: 1px 7px;
		border-radius: var(--r-pill);
		border: 1px solid var(--border);
		background: var(--sunken);
		letter-spacing: 0.02em;
	}
	.badge.muted {
		color: var(--text-3);
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

	.note {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		font-size: 12.5px;
		color: var(--text-3);
		line-height: 1.5;
		margin-top: 12px;
	}
	.note .ic {
		flex: none;
		margin-top: 2px;
	}
</style>
