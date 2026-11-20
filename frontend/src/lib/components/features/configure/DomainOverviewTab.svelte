<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ColorInput from '../../primitives/forms/ColorInput.svelte';
	import Markdown from '../../primitives/content/Markdown.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		domain,
		label,
		color = $bindable(''),
		description,
		onlabelinput,
		ondescriptionchange
	}: {
		/** Domain id, shown read-only in the identity form. */
		domain: string;
		/** Human display label. The parent's working copy owns the stored value;
		 *  the parent callback applies the `|| undefined` empty-to-absent rule. */
		label: string;
		/**
		 * Color working copy. Held as an always-defined string because
		 * `ColorInput`'s `value` prop is `$bindable('#5B8DEF')` (a fallback)
		 * and Svelte 5 rejects `bind:value={undefined}` with
		 * props_invalid_value. The parent binds its `colorValue` `$state`
		 * here and writes it back on save.
		 */
		color?: string;
		/** Markdown description. The parent's working copy owns the stored value. */
		description: string;
		/** Called with the typed display label on every input. */
		onlabelinput: (value: string) => void;
		/** Called with the edited markdown on every change. */
		ondescriptionchange: (value: string) => void;
	} = $props();
</script>

<div class="fsec">
	<h2 class="sec-title">{m.configure_identity_title()}</h2>
	<div class="grid2">
		<div class="f">
			<label for="dom-label">{m.configure_domains_label()}</label>
			<input
				id="dom-label"
				class="inp"
				placeholder={m.configure_domains_label_placeholder()}
				value={label}
				oninput={(e) => onlabelinput((e.target as HTMLInputElement).value)}
			/>
		</div>
		<div class="f">
			<ColorInput label={m.configure_color_label()} bind:value={color} placeholder="#3F51B5" />
		</div>
		<div class="f wide">
			<label for="dom-id">{m.configure_domains_id_label()}</label>
			<input id="dom-id" class="inp mono" value={domain} readonly />
		</div>
	</div>
</div>

<div class="fsec">
	<h2 class="sec-title">{m.common_description()}</h2>
	<div class="md-wrap">
		<Markdown
			value={description}
			onchange={(v) => ondescriptionchange(v)}
			placeholder={m.configure_domains_description_placeholder()}
		/>
	</div>
</div>

<style>
	/* ── Form sections (mirrors DomainEditor) ──────────────────────────── */
	.fsec {
		margin-bottom: 28px;
	}
	.fsec h2.sec-title {
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0 0 13px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
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
	.inp:disabled,
	.inp[readonly] {
		opacity: 0.6;
		background: var(--sunken);
		cursor: not-allowed;
	}

	.md-wrap {
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}

	@media (max-width: 720px) {
		.grid2 {
			grid-template-columns: 1fr;
		}
	}
</style>
