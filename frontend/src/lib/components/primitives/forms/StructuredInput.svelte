<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Field from './Field.svelte';
	import { parseStructured } from './structuredSchema.js';
	import type { FieldDef } from '$lib/doctype/types.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * StructuredInput — JSON-text editor for `object`, `array`, and
	 * `dictionary` fields.
	 *
	 * The text parses and validates against the field's declared schema
	 * (`structuredSchema.ts`) on every keystroke. A valid text binds the
	 * parsed structure into the form's values bag; blank text binds the `''`
	 * cleared sentinel. While the text is invalid the last valid structure
	 * stays bound — raw text never reaches the wire, and a typo cannot
	 * silently clear or clobber the stored value. The schema error renders
	 * through the shared `Field` chrome and wins over a forwarded 422 error.
	 *
	 * Validity flips report through `onvaliditychange`, so the host form can
	 * gate the save (B-118): text that parses to nothing saveable must block
	 * the submit instead of silently dropping or staling the field.
	 */
	let {
		label,
		required = false,
		helper,
		error,
		disabled = false,
		field,
		value = $bindable(''),
		onchange,
		onvaliditychange,
		id
	}: {
		label?: string;
		required?: boolean;
		helper?: string;
		error?: string;
		disabled?: boolean;
		/** The field's declared schema — drives the validation. */
		field: FieldDef;
		/** The parsed structure, or `''` when the field is cleared. */
		value?: unknown;
		/** Called with each parsed structure the component binds. */
		onchange?: (value: unknown) => void;
		/** Called on each parse-validity flip — `false` marks text the host
		 *  must not save (invalid JSON or a schema mismatch), `true` restores
		 *  the save. Blank text is valid (the cleared sentinel). */
		onvaliditychange?: (ok: boolean) => void;
		/** Stable base id for the label/ARIA wiring. */
		id?: string;
	} = $props();

	// Plain-`let` shadow of the last composite this component emitted. The
	// seeding effect compares against it so our own writeback never re-serializes
	// the textarea under the user's hands (the MoneyInput pattern).
	let lastEmitted = '';
	let text = $state('');

	/**
	 * Serialize a bound structure to the textarea text. Pretty-printed so a
	 * stored structure reads as editable JSON, not one long line.
	 */
	function serialize(v: unknown): string {
		if (v === '' || v === null || v === undefined) return '';
		try {
			return JSON.stringify(v, null, 2) ?? '';
		} catch {
			return '';
		}
	}

	// Seed from the bound value on mount and on external resets only.
	$effect(() => {
		const incoming = value;
		const key = JSON.stringify(incoming) ?? '';
		if (key === lastEmitted) return; // our own writeback — ignore
		lastEmitted = key;
		text = serialize(incoming);
	});

	/**
	 * The parse-and-validate outcome for the current text. Pure — drives both
	 * the error display and the emit decision.
	 */
	const outcome = $derived(parseStructured(text, field));

	const localError = $derived.by<string | undefined>(() => {
		if (outcome.ok) return undefined;
		if (outcome.reason === 'json') return m.doc_structured_invalid_json();
		return m.doc_structured_mismatch({
			path: outcome.issue.path,
			expected: outcome.issue.expected
		});
	});

	// A local schema failure is more actionable than the 422's field message,
	// so it takes precedence over any forwarded server `error`.
	const effectiveError = $derived(localError ?? error);

	// Report validity flips to the host so the form can gate the save. The
	// parse outcome is the single source — a mount seeds valid text, and both
	// user edits and external reseeds land here. `reportedValid` keeps the
	// call to one per flip, never per keystroke; the null start reports the
	// initial validity once, so a remount heals any stale host-side state.
	let reportedValid: boolean | null = null;
	$effect(() => {
		const ok = outcome.ok;
		if (ok === reportedValid) return;
		reportedValid = ok;
		onvaliditychange?.(ok);
	});

	function handleInput(event: Event) {
		const target = event.target as HTMLTextAreaElement;
		text = target.value;
		// Emit on user action only (never from an effect). Valid text binds the
		// parsed structure; blank binds the cleared sentinel; invalid text binds
		// nothing — the last valid structure stays, raw text never travels.
		if (!outcome.ok) return;
		const next = outcome.value;
		value = next;
		lastEmitted = JSON.stringify(next) ?? '';
		onchange?.(next);
	}
</script>

<div class="structured-wrap" class:structured-error={Boolean(effectiveError)}>
	<Field
		{label}
		{required}
		helper={helper ?? m.doc_structured_helper()}
		error={effectiveError}
		{id}
		forId={id}
	>
		{#snippet children(meta)}
			<textarea
				{id}
				class="structured-text"
				class:structured-text-err={Boolean(effectiveError)}
				rows="6"
				spellcheck="false"
				autocomplete="off"
				aria-invalid={effectiveError ? true : undefined}
				aria-describedby={meta.describedBy}
				{disabled}
				value={text}
				oninput={handleInput}></textarea>
		{/snippet}
	</Field>
</div>

<style>
	.structured-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	/* The JSON text is code — mono face, same field styling as the inputs. */
	.structured-text {
		font-family: var(--font-mono);
		font-variant-ligatures: none;
		font-size: 12.5px;
		line-height: 1.55;
		padding: 9px 11px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		resize: vertical;
		min-height: 96px;
		width: 100%;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.structured-wrap:focus-within .structured-text {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.structured-text:disabled {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	.structured-text-err {
		border-color: var(--danger);
	}

	.structured-wrap:focus-within .structured-text-err {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}
</style>
