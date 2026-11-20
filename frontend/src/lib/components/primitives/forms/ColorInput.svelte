<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Portal } from 'bits-ui';
	import {
		type HoneyCell,
		generateCells,
		generateNeutralCells,
		hexPts,
		computeViewBox,
		computeRailViewBox,
		hexToOklch,
		NEUTRAL_L_VALUES
	} from '$lib/utils/color';

	const RINGS = 4;
	const S = 27;
	const cells = generateCells(RINGS, S);
	const neutrals = generateNeutralCells(NEUTRAL_L_VALUES, S);
	const viewBox = computeViewBox(cells, S);
	const railViewBox = computeRailViewBox(neutrals, S);

	let {
		value = $bindable('#5B8DEF'),
		label,
		placeholder = '#RRGGBB',
		disabled = false,
		id
	}: {
		value?: string;
		label?: string;
		placeholder?: string;
		disabled?: boolean;
		id?: string;
	} = $props();

	let popoverOpen = $state(false);
	let hexInputValue = $state(value);
	let hoveredHex = $state('');
	let triggerRef: HTMLDivElement | undefined = $state();
	let popoverStyle = $state('');

	/* ── invalid-hex feedback ────────────────────────────────
	 * An invalid entry never commits — the field keeps the last valid
	 * value. The blur announces the rejection (role=alert error text)
	 * instead of reverting the text silently; refocusing clears it. */
	const uid = $props.id();
	const fieldErrId = `${uid}-err`;
	const popoverErrId = `${uid}-popover-err`;
	let hexError = $state<string | null>(null);
	const hasHexError = $derived(hexError !== null);

	function isFullHex(v: string): boolean {
		const clean = v.startsWith('#') ? v : '#' + v;
		return /^#[0-9a-fA-F]{6}$/.test(clean);
	}

	/* ── find closest cell (honeycomb + neutrals) to current value ─ */
	const selectedHex = $derived.by(() => {
		const oc = hexToOklch(value);
		if (!oc) return '';
		let best = '';
		let bestD = Infinity;
		const allCells = [...cells, ...neutrals];
		for (const c of allCells) {
			const d = (c.l - oc.L) ** 2 + (c.c - oc.C) ** 2 + (c.h - oc.H) ** 2;
			if (d < bestD) {
				bestD = d;
				best = c.hex;
			}
		}
		return bestD < Infinity ? best : '';
	});

	function isSelected(cell: HoneyCell): boolean {
		return cell.hex === selectedHex;
	}

	/* ── select a cell ──────────────────────────────────────── */
	function pickColor(cell: HoneyCell) {
		value = cell.hex;
		hexInputValue = cell.hex;
		hexError = null;
		closePopover();
	}

	function pickHover(cell: HoneyCell) {
		hoveredHex = cell.hex;
	}

	function clearHover() {
		hoveredHex = '';
	}

	/* ── hex fallback input ────────────────────────────── */
	function onHexInput(e: Event) {
		const v = (e.target as HTMLInputElement).value;
		hexInputValue = v;
		const clean = v.startsWith('#') ? v : '#' + v;
		if (/^#[0-9a-fA-F]{6}$/.test(clean)) {
			value = clean.toUpperCase();
			hexError = null;
		}
	}

	function onHexInputBlur() {
		if (isFullHex(hexInputValue)) {
			hexError = null;
			return;
		}
		hexError = m.doc_color_hex_error();
		// Snap the text back to the last valid value — the error text
		// (trigger level, or inside the open popover) explains the revert.
		hexInputValue = value;
	}

	/* ── sync hexInputValue when value changes externally ──── */
	$effect(() => {
		const v = value;
		if (!popoverOpen && hexInputValue !== v) hexInputValue = v;
	});

	/* when trigger input changes, validate hex and update value */
	$effect(() => {
		const v = hexInputValue;
		const clean = v.startsWith('#') ? v : '#' + v;
		if (/^#[0-9a-fA-F]{6}$/.test(clean) && clean.toUpperCase() !== value) {
			value = clean.toUpperCase();
		}
	});

	const displayHex = $derived(hoveredHex || value);

	function openPopover() {
		if (disabled || !triggerRef) return;
		hexError = null;
		hexInputValue = value;
		const r = triggerRef.getBoundingClientRect();
		popoverStyle = `top:${r.bottom + 6}px;left:${r.left}px`;
		popoverOpen = true;
	}

	function closePopover() {
		popoverOpen = false;
	}

	function onTriggerKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			closePopover();
		}
	}

	function onPopoverKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			closePopover();
			triggerRef?.querySelector('input')?.focus();
		}
	}

	/* close on outside click */
	$effect(() => {
		if (!popoverOpen) return;
		function onClick(e: MouseEvent) {
			if (!triggerRef) return;
			const target = e.target as Node;
			if (!triggerRef.closest('.color-input-wrap')?.contains(target)) {
				popoverOpen = false;
			}
		}
		const id = setTimeout(() => document.addEventListener('click', onClick), 0);
		return () => {
			clearTimeout(id);
			document.removeEventListener('click', onClick);
		};
	});
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="color-input-wrap"
	class:color-disabled={disabled}
	bind:this={triggerRef}
	onkeydown={onTriggerKeydown}
>
	{#if label}
		<label class="color-label" for={id ?? `color-input-${label}`}>
			{label}
		</label>
	{/if}

	<div class="color-trigger">
		<input
			{id}
			class="color-field"
			class:color-invalid={hasHexError}
			type="text"
			bind:value={hexInputValue}
			{placeholder}
			{disabled}
			onfocus={openPopover}
			onblur={onHexInputBlur}
			aria-label={label ?? m.doc_color_value_aria()}
			aria-invalid={hasHexError || undefined}
			aria-describedby={hasHexError && !popoverOpen ? fieldErrId : undefined}
		/>

		<button
			class="color-swatch-button"
			{disabled}
			aria-label={m.doc_color_pick_aria()}
			onclick={openPopover}
		>
			<span class="color-swatch" style="background: {value}"></span>
		</button>
	</div>

	{#if hasHexError && !popoverOpen}
		<span class="color-err" id={fieldErrId} role="alert">{hexError}</span>
	{/if}

	{#if popoverOpen}
		<Portal>
			<!-- svelte-ignore a11y_no_static_element_interactions -->
			<div
				class="color-popover"
				style={popoverStyle}
				role="dialog"
				aria-label={m.doc_color_picker_aria()}
				tabindex="-1"
				onkeydown={onPopoverKeydown}
			>
				<div class="honeycomb-wrap">
					<svg class="honeycomb-svg" {viewBox} xmlns="http://www.w3.org/2000/svg">
						{#each cells as cell, _i (cell.x + '-' + cell.y)}
							<!-- svelte-ignore a11y_no_static_element_interactions -->
							<g
								class="cell"
								class:cell-selected={isSelected(cell)}
								tabindex="0"
								role="button"
								aria-label={cell.hex}
								onclick={() => pickColor(cell)}
								onmouseenter={() => pickHover(cell)}
								onmouseleave={clearHover}
								onkeydown={(e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										pickColor(cell);
									}
								}}
							>
								<polygon points={hexPts(cell.x, cell.y, S)} fill={cell.hex} />
							</g>
						{/each}
					</svg>
				</div>

				<div class="neutrals-wrap">
					<span class="neutrals-label">{m.doc_color_neutrals()}</span>
					<svg class="neutrals-svg" viewBox={railViewBox} xmlns="http://www.w3.org/2000/svg">
						{#each neutrals as cell (cell.hex)}
							<!-- svelte-ignore a11y_no_static_element_interactions -->
							<g
								class="cell"
								class:cell-selected={isSelected(cell)}
								tabindex="0"
								role="button"
								aria-label={cell.hex}
								onclick={() => pickColor(cell)}
								onmouseenter={() => pickHover(cell)}
								onmouseleave={clearHover}
								onkeydown={(e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										pickColor(cell);
									}
								}}
							>
								<polygon points={hexPts(cell.x, cell.y, S)} fill={cell.hex} />
							</g>
						{/each}
					</svg>
				</div>

				<div class="popover-footer">
					<div class="popover-hex-input-wrap">
						<input
							class="popover-hex-input"
							class:color-invalid={hasHexError}
							type="text"
							bind:value={hexInputValue}
							placeholder="#RRGGBB"
							maxlength={7}
							oninput={onHexInput}
							onblur={onHexInputBlur}
							onfocus={() => (hexError = null)}
							aria-label={m.doc_color_paste_aria()}
							aria-invalid={hasHexError || undefined}
							aria-describedby={hasHexError ? popoverErrId : undefined}
						/>
						<span class="popover-hex-dot" style="background: {displayHex}"></span>
					</div>
				</div>

				{#if hasHexError}
					<span class="color-err color-err-popover" id={popoverErrId} role="alert">
						{hexError}
					</span>
				{/if}
			</div>
		</Portal>
	{/if}
</div>

<style>
	/* ── Wrap ───────────────────────────────────────────────── */
	.color-input-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	/* ── Label ──────────────────────────────────────────────── */
	.color-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	/* ── Trigger row ─────────────────────────────────────────── */
	.color-trigger {
		display: flex;
		align-items: center;
		position: relative;
	}

	.color-field {
		font-family: var(--font-mono);
		font-size: 13px;
		line-height: 1.5;
		padding: 9px 11px;
		padding-right: 40px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
		outline: none;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
		flex: 1;
		min-width: 0;
	}

	.color-field::placeholder {
		color: var(--text-3);
	}

	.color-field:disabled {
		opacity: 0.5;
		cursor: not-allowed;
		background: var(--surface-2);
	}

	.color-trigger:focus-within .color-field {
		outline: none;
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	/* ── Invalid hex feedback ─────────────────────────────────── */
	.color-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.color-err-popover {
		margin-top: 8px;
	}

	.color-field.color-invalid,
	.popover-hex-input.color-invalid {
		border-color: var(--danger);
	}

	.color-trigger:focus-within .color-field.color-invalid {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}

	/* ── Swatch button ───────────────────────────────────────── */
	.color-swatch-button {
		all: unset;
		position: absolute;
		right: 8px;
		top: 50%;
		transform: translateY(-50%);
		line-height: 0;
		cursor: pointer;
		flex: none;
		border-radius: var(--r-sm);
	}

	.color-swatch-button:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.color-swatch-button:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.color-swatch {
		display: block;
		width: 20px;
		height: 20px;
		border-radius: var(--r-sm);
		border: 1px solid var(--border-strong);
	}

	.color-swatch-button:not(:disabled):hover .color-swatch {
		transform: scale(1.1);
	}

	/* ── Popover (portal-rendered, position via inline style) ─── */
	.color-popover {
		position: fixed;
		z-index: 200;
		background: var(--surface);
		border: 1px solid var(--border-strong);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-2);
		padding: 12px;
		width: 260px;
	}

	/* ── Honeycomb SVG ───────────────────────────────────────── */
	.honeycomb-wrap {
		display: flex;
		justify-content: center;
		width: 100%;
	}

	.honeycomb-svg {
		width: 100%;
		height: auto;
		touch-action: manipulation;
		display: block;
	}

	/* ── Neutrals rail ────────────────────────────────────────── */
	.neutrals-wrap {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-top: 10px;
		padding-top: 10px;
		border-top: 1px solid var(--border);
	}

	.neutrals-label {
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.22em;
		text-transform: uppercase;
		color: var(--text-3);
		writing-mode: vertical-lr;
		text-orientation: mixed;
		flex: none;
	}

	.neutrals-svg {
		flex: 1;
		height: auto;
		max-height: 34px;
		touch-action: manipulation;
		display: block;
	}

	/* ── Cell styling (shared by honeycomb + neutrals) ───────── */
	.cell {
		cursor: pointer;
		transition: transform 0.08s ease;
	}

	.cell polygon {
		stroke: rgba(0, 0, 0, 0.28);
		stroke-width: 1;
	}

	.cell:hover {
		transform: scale(1.06);
	}

	.cell:focus-visible {
		outline: none;
	}

	.cell:focus-visible polygon {
		stroke: var(--accent);
		stroke-width: 3;
		paint-order: stroke;
	}

	.cell-selected polygon {
		stroke: #fff;
		stroke-width: 3;
		paint-order: stroke;
	}

	/* ── Footer ────────────────────────────────────────────── */
	.popover-footer {
		display: flex;
		align-items: center;
		margin-top: 10px;
		padding-top: 10px;
		border-top: 1px solid var(--border);
	}

	.popover-hex-input-wrap {
		display: flex;
		align-items: center;
		gap: 6px;
		flex: 1;
	}

	.popover-hex-input {
		font-family: var(--font-mono);
		font-size: 12px;
		padding: 5px 8px;
		color: var(--text);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		outline: none;
		flex: 1;
		min-width: 0;
	}

	.popover-hex-input:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 2px var(--accent-weak);
	}

	.popover-hex-dot {
		width: 18px;
		height: 18px;
		border-radius: var(--r-sm);
		border: 1px solid var(--border-strong);
		flex: none;
	}
</style>
