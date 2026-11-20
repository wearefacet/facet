<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { parseLevelInput } from '$lib/iam/roleLevel.js';
	import * as m from '$lib/paraglide/messages';

	let {
		/** Two-way bindable open state. */
		open = $bindable(false),
		/**
		 * Called when the user confirms with a non-empty name and a valid
		 * level. Returns `null` on success (the dialog closes), a single
		 * error string (shown as one line), or a `{ message, details }` object
		 * so the structured `DataSourceError.details` array is surfaced with
		 * full context.
		 */
		oncreate = (_name: string, _description: string, _level: number) => Promise.resolve(null)
	}: {
		open?: boolean;
		oncreate?: (
			name: string,
			description: string,
			level: number
		) => Promise<string | { message: string; details: string[] } | null>;
	} = $props();

	let name = $state('');
	let description = $state('');
	// Text state for the level field; `parseLevelInput` owns the number.
	let levelInput = $state('');
	// The required hint waits for the first blur, so an untouched dialog does
	// not open with an error. The Create button stays disabled regardless.
	let levelTouched = $state(false);
	let errorMessage = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let submitting = $state(false);

	function reset() {
		name = '';
		description = '';
		levelInput = '';
		levelTouched = false;
		errorMessage = undefined;
		errorDetails = [];
		submitting = false;
	}

	// Reset whenever the dialog opens, so every open shows a fresh form. A
	// programmatic `open = false` (a successful create, or Cancel) does not fire
	// Bits UI's `onOpenChange`, so a close-time reset would miss those paths and
	// leak the previous entry into the next open.
	$effect(() => {
		if (open) reset();
	});

	// iam.Roles.name pattern: ^[a-z][a-z0-9_]*$ — lowercase, starts with a
	// letter, underscores allowed. Validated client-side as a courtesy; the
	// backend re-validates and rejects on conflict (unique).
	const PATTERN = /^[a-z][a-z0-9_]*$/;
	const valid = $derived(PATTERN.test(name.trim()));

	// iam.Roles.level: required integer, 0 through 100.
	const levelValue = $derived(parseLevelInput(levelInput));
	const levelValid = $derived(levelValue !== null);
	const levelError = $derived.by(() => {
		if (levelValid) return undefined;
		if (levelInput.trim() !== '') return m.admin_new_role_level_error();
		return levelTouched ? m.admin_new_role_level_required() : undefined;
	});

	async function handleSubmit() {
		const trimmed = name.trim();
		const level = parseLevelInput(levelInput);
		if (!trimmed || level === null || submitting) return;
		submitting = true;
		errorMessage = undefined;
		errorDetails = [];
		const err = await oncreate(trimmed, description.trim(), level);
		submitting = false;
		if (err) {
			if (typeof err === 'string') {
				errorMessage = err;
				errorDetails = [];
			} else {
				errorMessage = err.message;
				errorDetails = err.details;
			}
			return;
		}
		open = false;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Portal>
		<Dialog.Overlay class="new-role-overlay" />
		<Dialog.Content class="new-role-content">
			<Dialog.Title class="new-role-title">{m.admin_new_role()}</Dialog.Title>
			<Dialog.Description class="new-role-desc">
				{m.admin_new_role_helper()}
			</Dialog.Description>

			<form
				class="new-role-form"
				onsubmit={(e) => {
					e.preventDefault();
					handleSubmit();
				}}
			>
				<div class="field">
					<label class="field-label" for="new-role-name">{m.common_name()}</label>
					<input
						id="new-role-name"
						class="name-input"
						class:invalid={name.trim().length > 0 && !valid}
						bind:value={name}
						placeholder={m.admin_new_role_name_placeholder()}
						autocomplete="off"
					/>
					{#if name.trim().length > 0 && !valid}
						<p class="hint">
							{m.admin_new_role_name_error()}
						</p>
					{/if}
				</div>

				<div class="field">
					<label class="field-label" for="new-role-level">{m.admin_new_role_level_label()}</label>
					<input
						id="new-role-level"
						class="level-input"
						class:invalid={levelError !== undefined}
						type="text"
						inputmode="numeric"
						bind:value={levelInput}
						placeholder={m.admin_new_role_level_placeholder()}
						autocomplete="off"
						onblur={() => (levelTouched = true)}
					/>
					{#if levelError}
						<p class="hint hint-error">{levelError}</p>
					{:else}
						<p class="hint">{m.admin_new_role_level_helper()}</p>
					{/if}
				</div>

				<div class="field">
					<label class="field-label" for="new-role-desc">
						{m.common_description()}
						<span class="field-optional">{m.admin_new_role_desc_optional()}</span>
					</label>
					<textarea
						id="new-role-desc"
						class="desc-input"
						bind:value={description}
						placeholder={m.admin_new_role_desc_placeholder()}
						rows="3"></textarea>
				</div>

				<div class="actions">
					<button class="cancel-btn" type="button" onclick={() => (open = false)}
						>{m.common_cancel()}</button
					>
					<button class="create-btn" type="submit" disabled={!valid || !levelValid || submitting}>
						{submitting ? m.common_creating() : m.admin_create_role_button()}
					</button>
				</div>
			</form>

			{#if errorMessage}
				<div class="err" role="alert">
					<p class="err-head">{errorMessage}</p>
					{#if errorDetails.length > 0}
						<ul class="err-details">
							{#each errorDetails as d (d)}
								<li>{d}</li>
							{/each}
						</ul>
					{/if}
				</div>
			{/if}

			<Dialog.Close class="close-btn" title={m.common_close()}>
				<X size={16} stroke-width={1.8} />
			</Dialog.Close>
		</Dialog.Content>
	</Dialog.Portal>
</Dialog.Root>

<style>
	:global(.new-role-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.new-role-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(480px, 90vw);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg, 12px);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		z-index: 101;
		padding: 24px;
		gap: 16px;
	}

	:global(.new-role-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.new-role-desc) {
		font-size: 13px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.45;
	}

	:global(.new-role-desc code) {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.new-role-form {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.field-label {
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
	}

	.field-optional {
		font-weight: 400;
		color: var(--text-3);
	}

	.name-input,
	.desc-input,
	.level-input {
		width: 100%;
		padding: 9px 11px;
		border: 1px solid var(--border-strong, var(--border));
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 13.5px;
		font-family: var(--font-mono);
	}

	.level-input {
		width: 160px;
	}

	.desc-input {
		font-family: var(--font-sans);
		resize: vertical;
		min-height: 64px;
		line-height: 1.45;
	}

	.name-input:focus-visible,
	.desc-input:focus-visible,
	.level-input:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.name-input.invalid,
	.level-input.invalid {
		border-color: var(--danger);
	}

	.hint {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 0;
	}

	.hint-error {
		color: var(--danger);
	}

	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 4px;
	}

	.cancel-btn,
	.create-btn {
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

	.create-btn {
		border: 1px solid var(--accent);
		background: var(--accent);
		/* `--on-accent` (dark) sits on the gold fill. `--accent-ink` is gold-on-light
		   and renders near-invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
	}

	.create-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.err {
		display: flex;
		flex-direction: column;
		gap: 6px;
		font-size: 13px;
		color: var(--danger);
		margin: 0;
		padding: 8px 10px;
		background: var(--danger-weak, rgba(220, 38, 38, 0.08));
		border-radius: var(--r);
	}

	.err-head {
		margin: 0;
		font-weight: 600;
	}

	.err-details {
		margin: 0;
		padding-left: 16px;
	}

	.err-details li {
		font-family: var(--font-mono);
		font-size: 12px;
		line-height: 1.5;
	}

	:global(.new-role-content .close-btn) {
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

	:global(.new-role-content .close-btn:hover) {
		background: var(--sunken);
		color: var(--text);
	}

	:global(.new-role-content .close-btn:focus-visible) {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
