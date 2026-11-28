<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { FieldDef } from '$lib/doctype/types.js';
	import { humanize } from '$lib/doctype/types.js';
	import { validFilterCapabilities, type FilterCapability } from '$lib/doctype/capabilities.js';
	import { hashColor } from '$lib/utils/color.js';
	import Input from '../../primitives/forms/Input.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import Toggle from '../../primitives/forms/Toggle.svelte';
	import ColorInput from '../../primitives/forms/ColorInput.svelte';
	import * as m from '$lib/paraglide/messages';

	let {
		field,
		readonly = false,
		domain = '',
		onchange
	}: {
		field: FieldDef | undefined;
		readonly?: boolean;
		/** Domain of the doctype being edited. A bare reference target is
		 *  qualified into the `domain.Target` form the backend Check requires
		 *  (empty when unknown — no qualification). */
		domain?: string;
		/** Reports the edited field after every edit — the parent owns the
		 *  definition, so the edits are never written into the prop itself. */
		onchange?: (field: FieldDef) => void;
	} = $props();

	/** The working copy this editor shows. */
	let draft = $derived(field);

	function edit(mutate: (d: FieldDef) => void) {
		if (!draft) return;
		const next = { ...draft };
		mutate(next);
		draft = next;
		onchange?.(next);
	}

	/**
	 * Qualifies a bare reference target at commit time. The backend Check
	 * (`src/doctype/check.cr`) rejects a target without a dot — bare names
	 * match no registered doctype. Values that already carry a domain
	 * (cross-domain like `iam.Account`) pass through untouched. Runs on
	 * `change`, not `input`: per-keystroke qualification would prefix the
	 * first character and make typing a cross-domain name impossible.
	 */
	function qualifyReferenceTarget(raw: string): string {
		if (!raw || !domain || raw.includes('.')) return raw;
		return `${domain}.${raw}`;
	}

	/** Commit handler for the reference target input. */
	function handleReferenceTargetChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLInputElement;
		const qualified = qualifyReferenceTarget(target.value);
		target.value = qualified;
		edit((d) => {
			d.doctype = qualified || undefined;
		});
	}

	/**
	 * Authored filter capabilities, mirroring the backend `FilterCapability`
	 * enum (`src/doctype/filter_capability.cr`). The backend derives the
	 * runtime operator set and the physical indexes from these; raw
	 * operators are never authored. The tables live in
	 * `$lib/doctype/capabilities.js`, shared with the doctype editor's
	 * add-field default.
	 */

	/** Capabilities the author may pick for a field of the given type. */
	function capabilitiesFor(type: string): FilterCapability[] {
		return validFilterCapabilities(type);
	}

	// ── Enum helpers ──────────────────────────────────────────────────────

	let newEnumValue = $state('');

	function addEnumValue() {
		if (!draft || readonly) return;
		const v = newEnumValue.trim();
		if (!v) return;
		// Duplicate keys would throw `each_key_duplicate` at the keyed {#each}.
		if ((draft.values ?? []).some((e) => e.key === v)) return;
		edit((d) => {
			d.values = [...(d.values ?? []), { key: v }];
		});
		newEnumValue = '';
	}

	function removeEnumValue(v: string) {
		if (!draft || readonly) return;
		edit((d) => {
			d.values = (d.values ?? []).filter((x) => x.key !== v);
			if (d.default === v) d.default = undefined;
		});
	}

	function setEnumDefault(v: string) {
		if (!draft || readonly) return;
		const same = v === draft.default;
		edit((d) => {
			d.default = same ? undefined : v;
		});
	}

	function enumLabel(v: { key: string; label?: string; color?: string }): string {
		return v.label ?? humanize(v.key);
	}

	function enumColor(v: { key: string; label?: string; color?: string }): string {
		return v.color ?? hashColor(v.key);
	}

	// ── Capability toggle ─────────────────────────────────────────────────

	function toggleCapability(cap: string) {
		if (!draft || readonly) return;
		edit((d) => {
			const caps = d.filters ?? [];
			d.filters = caps.includes(cap) ? caps.filter((c) => c !== cap) : [...caps, cap];
		});
	}

	// ── Shape editor for array/object ─────────────────────────────────────

	let shapeNewKey = $state('');

	function addShapeField() {
		if (!draft || readonly) return;
		const k = shapeNewKey.trim();
		if (!k) return;
		edit((d) => {
			d.properties = [...(d.properties ?? []), { key: k, type: 'string' }];
		});
		shapeNewKey = '';
	}

	function removeShapeField(key: string) {
		if (!draft || readonly) return;
		edit((d) => {
			d.properties = (d.properties ?? []).filter((s) => s.key !== key);
		});
	}

	// ── Default type editor (string/datetime/boolean) ─────────────────────

	function handleDefaultChange(e: Event) {
		if (!draft || readonly) return;
		const target = e.target as HTMLInputElement;
		const next = target.value || undefined;
		edit((d) => {
			d.default = next;
		});
	}
</script>

{#if draft}
	<div class="fsec">
		<h4>
			{draft.type === 'enum'
				? m.configure_doctypes_enum_title()
				: draft.type === 'integer'
					? m.configure_doctypes_number_title()
					: draft.type === 'reference'
						? m.configure_doctypes_reference_title()
						: draft.type === 'data' && draft.compute
							? m.configure_doctypes_computed_title()
							: draft.type === 'money'
								? m.configure_doctypes_money_title()
								: draft.type === 'object'
									? m.configure_doctypes_object_title()
									: draft.type === 'array'
										? m.configure_doctypes_array_items_title()
										: draft.type === 'secret'
											? m.configure_doctypes_secret_title()
											: m.configure_doctypes_default_title()}
		</h4>

		<!-- ─── enum ─── -->
		{#if draft.type === 'enum'}
			<div class="vchips">
				{#each draft.values ?? [] as v (v.key)}
					<span
						class="vchip"
						class:def={v.key === draft.default}
						onclick={() => !readonly && setEnumDefault(v.key)}
						role="button"
						tabindex="0"
						onkeydown={(e) => e.key === 'Enter' && !readonly && setEnumDefault(v.key)}
						style={`background: color-mix(in srgb, ${enumColor(v)} 14%, transparent); color: ${enumColor(v)};`}
					>
						{#if v.key === draft.default}<span class="star">★</span>{/if}
						{enumLabel(v)}
						{#if !readonly}
							<button
								class="x"
								onclick={(e) => {
									e.stopPropagation();
									removeEnumValue(v.key);
								}}>✕</button
							>
						{/if}
					</span>
				{/each}
				{#if !readonly}
					<span class="vchip vchip-add">
						<input
							type="text"
							placeholder={m.configure_doctypes_value_add_placeholder()}
							bind:value={newEnumValue}
							onkeydown={(e) => e.key === 'Enter' && addEnumValue()}
							class="vchip-input"
						/>
					</span>
				{/if}
			</div>
			<div class="f" style="margin-top:13px">
				<Select
					label={m.configure_doctypes_enum_default_label()}
					value={(draft.default as string) ?? ''}
					options={(draft.values ?? []).map((v) => ({
						value: v.key,
						label: v.label ?? humanize(v.key)
					}))}
					onchange={() => {}}
					disabled={readonly}
				/>
			</div>

			<!-- ─── integer ─── -->
		{:else if draft.type === 'integer'}
			<div class="grid2">
				<div class="f">
					<Input
						label={m.configure_doctypes_default_label()}
						value={(draft.default as string) ?? ''}
						oninput={handleDefaultChange}
						disabled={readonly}
					/>
				</div>
				<div></div>
				<div class="f">
					<Input
						label={m.configure_doctypes_min_label()}
						value={draft.min ?? ''}
						type="number"
						oninput={(e) => {
							const min = Number((e.target as HTMLInputElement).value) || undefined;
							edit((d) => {
								d.min = min;
							});
						}}
						disabled={readonly}
					/>
				</div>
				<div class="f">
					<Input
						label={m.configure_doctypes_max_label()}
						value={draft.max ?? ''}
						type="number"
						oninput={(e) => {
							const max = Number((e.target as HTMLInputElement).value) || undefined;
							edit((d) => {
								d.max = max;
							});
						}}
						disabled={readonly}
					/>
				</div>
			</div>

			<!-- ─── reference ─── -->
		{:else if draft.type === 'reference'}
			<div class="grid2">
				<div class="f">
					<Input
						label={m.configure_doctypes_target_doctype_label()}
						value={draft.doctype ?? ''}
						oninput={(e) => {
							const doctype = (e.target as HTMLInputElement).value || undefined;
							edit((d) => {
								d.doctype = doctype;
							});
						}}
						onchange={handleReferenceTargetChange}
						disabled={readonly}
					/>
				</div>
				<div class="f">
					<Select
						label={m.configure_doctypes_on_delete_label()}
						value={draft.on_source_delete ?? 'restrict'}
						options={[
							{ value: 'restrict', label: 'restrict' },
							{ value: 'set null', label: 'set null' },
							{ value: 'cascade', label: 'cascade' }
						]}
						disabled={readonly}
					/>
				</div>
			</div>
			<div class="note" style="margin-top:13px">
				<svg
					class="ic"
					width="15"
					height="15"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					viewBox="0 0 24 24"
				>
					<path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1" /><path
						d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"
					/>
				</svg>
				<div>
					{m.configure_doctypes_reference_note({ doctype: draft.doctype ?? '(unknown)' })}
				</div>
			</div>

			<!-- ─── computed (data + compute) ─── -->
		{:else if draft.type === 'data' && draft.compute}
			<div class="f">
				<label for="compute-fn">{m.configure_doctypes_compute_fn_label()}</label>
				<div style="display:flex;gap:9px;align-items:center">
					<input id="compute-fn" class="inp mono" value={draft.compute} readonly />
				</div>
			</div>
			<div class="f" style="margin-top:13px">
				<span class="label">{m.configure_doctypes_recompute_when_label()}</span>
				<div class="vchips">
					{#each draft.compute_when ?? [] as c, i (i)}
						<span class="vchip">{c}</span>
					{/each}
				</div>
			</div>
			<div class="note compute" style="margin-top:13px">
				<svg class="ic" width="15" height="15" fill="currentColor" viewBox="0 0 24 24">
					<path d="M12 2l1.8 6.2L20 10l-6.2 1.8L12 18l-1.8-6.2L4 10l6.2-1.8z" />
				</svg>
				<div>
					<b>{m.configure_doctypes_compute_note()}</b>
				</div>
			</div>

			<!-- ─── money ─── -->
		{:else if draft.type === 'money'}
			<div class="grid2">
				<div class="f">
					<Input
						label={m.configure_doctypes_currency_from_label()}
						value={draft.currency ?? 'currency'}
						oninput={(e) => {
							const currency = (e.target as HTMLInputElement).value || undefined;
							edit((d) => {
								d.currency = currency;
							});
						}}
						disabled={readonly}
					/>
				</div>
				<div class="f">
					<Select
						label={m.configure_doctypes_stored_as_label()}
						value="minor"
						options={[
							{ value: 'minor', label: m.configure_doctypes_stored_minor_label() },
							{ value: 'decimal', label: m.configure_doctypes_stored_decimal_label() }
						]}
						disabled={readonly}
					/>
				</div>
			</div>

			<!-- ─── object ─── -->
		{:else if draft.type === 'object'}
			<div class="shape">
				{#each draft.properties ?? [] as sub (sub.key)}
					<div class="sr">
						<span class="sk">{sub.key}</span>
						{#if sub.required}<span class="rq">*</span>{/if}
						<span class="sp"></span>
						<span class="st">{sub.type}</span>
						{#if !readonly}
							<button
								class="kb"
								aria-label={m.configure_doctypes_remove_sub_aria({ name: sub.key })}
								onclick={() => removeShapeField(sub.key)}
							>
								<svg
									width="14"
									height="14"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
									viewBox="0 0 24 24"
								>
									<path d="M18 6L6 18M6 6l12 12" />
								</svg>
							</button>
						{/if}
					</div>
				{/each}
				{#if !readonly}
					<div class="addsr-row">
						<input
							class="inp mono"
							placeholder={m.configure_doctypes_subfield_placeholder()}
							bind:value={shapeNewKey}
							onkeydown={(e) => e.key === 'Enter' && addShapeField()}
						/>
						<button class="addsr" onclick={addShapeField}>
							<svg
								width="13"
								height="13"
								fill="none"
								stroke="currentColor"
								stroke-width="2"
								viewBox="0 0 24 24"
							>
								<path d="M12 5v14M5 12h14" />
							</svg>
							{m.configure_doctypes_add_subfield_button()}
						</button>
					</div>
				{/if}
			</div>
			<div class="note" style="margin-top:13px">
				<svg
					class="ic"
					width="15"
					height="15"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					viewBox="0 0 24 24"
				>
					<rect x="3" y="3" width="18" height="18" rx="2" /><path d="M3 9h18" />
				</svg>
				<div>
					<b>{m.configure_doctypes_object_note()}</b>
				</div>
			</div>

			<!-- ─── array ─── -->
		{:else if draft.type === 'array'}
			<div class="f" style="max-width:260px">
				<Select
					label={m.configure_doctypes_item_type_label()}
					value={draft.items?.type ?? 'object'}
					options={[
						{ value: 'object', label: 'object' },
						{ value: 'string', label: 'string' },
						{ value: 'integer', label: 'integer' },
						{ value: 'money', label: 'money' },
						{ value: 'reference', label: 'reference' }
					]}
					disabled={readonly}
				/>
			</div>
			{#if draft.items?.type === 'object' || !draft.items}
				<div style="margin-top:13px">
					<div style="font-size:12.5px;font-weight:600;display:block;margin-bottom:9px">
						{m.configure_doctypes_item_shape_label()}
						<span class="opt" style="color:var(--text-3);font-weight:400"
							>{m.configure_doctypes_item_shape_opt()}</span
						>
					</div>
					<div class="shape">
						{#each draft.items?.properties ?? [] as sub (sub.key)}
							<div class="sr">
								<span class="sk">{sub.key}</span>
								{#if sub.required}<span class="rq">*</span>{/if}
								<span class="sp"></span>
								<span class="st">{sub.type}</span>
								{#if !readonly}
									<button
										class="kb"
										aria-label={m.configure_doctypes_remove_sub_aria({ name: sub.key })}
									>
										<svg
											width="14"
											height="14"
											fill="none"
											stroke="currentColor"
											stroke-width="2"
											viewBox="0 0 24 24"
										>
											<path d="M18 6L6 18M6 6l12 12" />
										</svg>
									</button>
								{/if}
							</div>
						{/each}
					</div>
					{#if !readonly}
						<div class="addsr-row">
							<input class="inp mono" placeholder={m.configure_doctypes_subfield_placeholder()} />
							<button class="addsr">
								<svg
									width="13"
									height="13"
									fill="none"
									stroke="currentColor"
									stroke-width="2"
									viewBox="0 0 24 24"
								>
									<path d="M12 5v14M5 12h14" />
								</svg>
								{m.configure_doctypes_add_subfield_button()}
							</button>
						</div>
					{/if}
				</div>
			{/if}
			<div class="fsec" style="margin-top:16px">
				<h4>{m.configure_doctypes_array_constraints_title()}</h4>
				<div class="grid2">
					<div class="f">
						<Input
							label={m.configure_doctypes_min_items_label()}
							type="number"
							value={draft.min ?? ''}
							placeholder="—"
							oninput={(e) => {
								const min = Number((e.target as HTMLInputElement).value) || undefined;
								edit((d) => {
									d.min = min;
								});
							}}
							disabled={readonly}
						/>
					</div>
					<div class="f">
						<Input
							label={m.configure_doctypes_max_items_label()}
							type="number"
							value={draft.max ?? ''}
							placeholder="—"
							oninput={(e) => {
								const max = Number((e.target as HTMLInputElement).value) || undefined;
								edit((d) => {
									d.max = max;
								});
							}}
							disabled={readonly}
						/>
					</div>
					<div class="f wide">
						<Toggle
							label={m.configure_doctypes_unique_items_label()}
							checked={draft.unique ?? false}
							onchange={() => {
								const next = !draft?.unique;
								edit((d) => {
									d.unique = next;
								});
							}}
							disabled={readonly}
						/>
					</div>
				</div>
			</div>
			<div class="note" style="margin-top:13px">
				<svg
					class="ic"
					width="15"
					height="15"
					fill="none"
					stroke="currentColor"
					stroke-width="1.8"
					viewBox="0 0 24 24"
				>
					<rect x="3" y="3" width="18" height="18" rx="2" /><path d="M3 9h18" />
				</svg>
				<div>
					<b>{m.configure_doctypes_array_note()}</b>
				</div>
			</div>

			<!-- ─── boolean ─── -->
		{:else if draft.type === 'boolean'}
			<div class="f" style="max-width:280px">
				<Toggle
					label={m.configure_doctypes_default_value_label()}
					checked={draft.default === true}
					onchange={() => {
						const next = !draft?.default;
						edit((d) => {
							d.default = next;
						});
					}}
					disabled={readonly}
				/>
			</div>

			<!-- ─── color ─── -->
		{:else if draft.type === 'color'}
			<div class="f" style="max-width:280px">
				<ColorInput
					label={m.configure_doctypes_default_value_label()}
					value={(draft.default as string) ?? ''}
					onchange={(v) => {
						if (readonly) return;
						edit((d) => {
							d.default = v || undefined;
						});
					}}
					placeholder="#c89329"
					disabled={readonly}
				/>
			</div>

			<!-- ─── secret ─── -->
		{:else if draft.type === 'secret'}
			<div class="f" style="max-width:320px">
				<Select
					label={m.configure_doctypes_mode_label()}
					value={draft.mode ?? 'hash'}
					options={[
						{ value: 'hash', label: m.configure_doctypes_mode_verify() },
						{ value: 'sealed', label: m.configure_doctypes_mode_reveal() },
						{ value: 'token', label: m.configure_doctypes_mode_token() }
					]}
					onValueChange={(v) => {
						if (readonly) return;
						edit((d) => {
							d.mode = v as FieldDef['mode'];
						});
					}}
					helper={m.configure_doctypes_mode_helper()}
					disabled={readonly}
				/>
			</div>

			<!-- ─── default (string, datetime, longtext, data, any, etc.) ─── -->
		{:else}
			<div class="f" style="max-width:280px">
				<Input
					label={m.configure_doctypes_default_value_label()}
					placeholder="—"
					value={(draft.default as string) ?? ''}
					oninput={(e) => {
						const next = (e.target as HTMLInputElement).value || undefined;
						edit((d) => {
							d.default = next;
						});
					}}
					disabled={readonly}
				/>
			</div>
		{/if}
	</div>

	<!-- ─── Filter capabilities section (common to all field types) ─── -->
	<div class="fsec" style="margin-top:0">
		<h4>{m.configure_doctypes_query_indexing_title()}</h4>
		<div style="font-size:12.5px;font-weight:600;display:block;margin-bottom:9px">
			{m.configure_doctypes_filter_capabilities_title()}
		</div>
		{#if capabilitiesFor(draft.type).length > 0}
			<div class="opchips">
				{#each capabilitiesFor(draft.type) as cap (cap)}
					<button
						class="opchip"
						class:on={(draft.filters ?? []).includes(cap)}
						onclick={() => toggleCapability(cap)}
						disabled={readonly}>{cap}</button
					>
				{/each}
			</div>
		{:else}
			<div class="note" style="margin-top:0">
				<svg
					class="ic"
					width="15"
					height="15"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					viewBox="0 0 24 24"
				>
					<path d="M4 6h16M7 12h10M10 18h4" />
				</svg>
				<div>
					<b>{m.configure_doctypes_not_filterable_note({ type: draft.type })}</b>
				</div>
			</div>
		{/if}
	</div>
{/if}

<style>
	.fsec {
		margin-bottom: 24px;
		max-width: 620px;
	}
	.fsec h4 {
		font-size: 11px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0 0 13px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		gap: 8px;
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
	.f label,
	.f .label {
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
	.inp:focus {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}
	.vchips,
	.opchips {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		align-items: center;
	}
	.vchip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 3px 10px;
		font-size: 12.5px;
		font-family: var(--font-mono);
		cursor: pointer;
		transition: border-color 0.1s;
	}
	.vchip .x {
		background: none;
		border: none;
		padding: 0 0 0 3px;
		font-size: 11px;
		color: var(--text-3);
		cursor: pointer;
		line-height: 1;
	}
	.vchip.def {
		background: var(--accent-weak);
		border-color: var(--accent);
	}
	.vchip .star {
		color: var(--accent-ink);
		font-size: 11px;
		margin-right: 2px;
	}
	.vchip-add {
		background: transparent;
		border-style: dashed;
		padding: 3px 6px 3px 10px;
	}
	.vchip-input {
		border: none;
		background: transparent;
		font: inherit;
		font-size: 12.5px;
		font-family: var(--font-mono);
		color: inherit;
		width: 60px;
		outline: none;
	}
	.opchip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		padding: 3px 10px;
		font-size: 12.5px;
		font-family: var(--font-mono);
		color: var(--text-2);
		cursor: pointer;
		transition: border-color 0.1s;
		font: inherit;
	}
	.opchip.on {
		background: var(--accent-weak);
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
	}
	.note .ic {
		flex: none;
		margin-top: 2px;
	}
	.note.compute {
		background: var(--accent-weak);
		border: 1px solid var(--accent);
		border-radius: var(--r);
		padding: 12px 14px;
	}
	.note.compute .ic {
		stroke: var(--accent-ink);
		color: var(--accent-ink);
	}
	.shape {
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-width: 420px;
	}
	.sr {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 8px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}
	.sk {
		font-family: var(--font-mono);
		font-size: 12.5px;
		font-weight: 500;
	}
	.rq {
		color: var(--danger);
		font-weight: 700;
		font-size: 12px;
		margin-left: -2px;
	}
	.sp {
		flex: 1;
	}
	.st {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 4px;
		padding: 1px 6px;
	}
	.kb {
		background: none;
		border: none;
		padding: 2px;
		color: var(--text-3);
		cursor: pointer;
		border-radius: 4px;
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.kb:hover {
		background: var(--danger-weak);
		color: var(--danger);
	}
	.addsr-row {
		display: flex;
		gap: 6px;
		align-items: center;
		margin-top: 4px;
	}
	.addsr {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 5px 10px;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r);
		background: transparent;
		font: inherit;
		font-size: 12px;
		color: var(--text-2);
		cursor: pointer;
	}
	.addsr:hover {
		border-color: var(--accent);
		color: var(--accent-ink);
	}
</style>
