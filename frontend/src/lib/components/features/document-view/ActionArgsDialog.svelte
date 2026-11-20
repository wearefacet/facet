<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import type { ArgDef } from '$lib/doctype/types.js';

	/** The input controls the args prompt renders, keyed by the declared arg type. */
	export type ArgControlKind =
		| 'text'
		| 'number'
		| 'url'
		| 'tel'
		| 'money'
		| 'toggle'
		| 'select'
		| 'reference'
		| 'date'
		| 'datetime';

	/**
	 * The control that renders one action argument, or `null` when the
	 * declared type has no input renderer here (container/typed editors such
	 * as longtext, period, color, file, secret, object/array shapes) or the
	 * arg is a collection. The host keeps its disabled "(args required)" menu
	 * item for an action whose required args cannot all render.
	 *
	 * `ActionArgDefinition` mirrors `FieldDefinition`, so this is the DVT
	 * input mapping (`doctype/autoInput.ts`) minus the template-node layer:
	 * scalar types dispatch to the same form primitives, and the no-renderer
	 * verdict takes the place of the not-editable one.
	 */
	export function argControl(arg: ArgDef): ArgControlKind | null {
		if (arg.collection) return null;
		switch (arg.type) {
			case 'string':
			case 'any':
				return 'text';
			case 'integer':
			case 'duration':
				return 'number';
			case 'url':
				return 'url';
			case 'phone':
				return 'tel';
			case 'money':
				return 'money';
			case 'boolean':
				return 'toggle';
			case 'enum':
				return 'select';
			case 'reference':
				return 'reference';
			case 'date':
				return 'date';
			case 'datetime':
				return 'datetime';
			default:
				return null;
		}
	}
</script>

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import MoneyInput from '$lib/components/primitives/forms/MoneyInput.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import { humanize, type ActionDef, type MoneyValue } from '$lib/doctype/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { BannerError } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	let {
		open = $bindable(false),
		action,
		driver,
		domain,
		error = null,
		onsubmit
	}: {
		/** Two-way bindable open state — the host's menu item flips it. */
		open?: boolean;
		/** The action whose arguments the prompt collects. `null` renders nothing. */
		action: ActionDef | null;
		/** Driver for the reference picker (doctype metadata + record search). */
		driver: DataDriver;
		/** The host document's domain — qualifies bare reference targets. */
		domain: string;
		/** The host's action failure, rendered above the fields so the user can correct the arguments. */
		error?: BannerError | null;
		/** Called with the collected args after the client checks pass. The host owns the action call and returns `false` to keep the prompt open. */
		onsubmit: (args: Record<string, unknown>) => Promise<boolean> | boolean | void;
	} = $props();

	/** One entry per arg key — seeded ahead of each open, mutated in place by the controls. */
	let values = $state<Record<string, unknown>>({});
	let errors = $state<Record<string, string>>({});
	/** True while the host's action call is in flight — blocks a double submit. */
	let submitting = $state(false);

	function seedPrompt(): void {
		values = seedArgs(action);
		errors = {};
	}

	// Mount seed: a prompt that opens with the component (open passed as
	// true) renders before any effect flush — the body runs first, so the
	// bag is already shaped for the initial action.
	seedPrompt();

	// Re-seed the bag ahead of each open — stale values from a previous
	// prompt must never leak into the next one. `$effect.pre` runs before the
	// DOM update, so the controls never render against an empty bag and never
	// bind `undefined` (every control's `$bindable` prop rejects it). The
	// writes never read `values`/`errors`, so the effect cannot loop
	// (workflow.md → the equality-guard trap in writeback effects).
	$effect.pre(() => {
		if (!open) return;
		seedPrompt();
	});

	/** Seed one arg from its declared default, shaped for its control. */
	function seedValue(arg: ArgDef): unknown {
		const d = arg.default;
		switch (argControl(arg)) {
			case 'toggle':
				return d === undefined || d === null ? false : Boolean(d);
			case 'number': {
				const n = d === undefined || d === null ? NaN : Number(d);
				return Number.isFinite(n) ? n : '';
			}
			case 'money':
				return d !== null && typeof d === 'object' ? (d as MoneyValue) : '';
			case 'select':
			case 'reference':
			case 'date':
			case 'datetime':
				return typeof d === 'string' ? d : '';
			case 'text':
			case 'url':
			case 'tel':
				return d === undefined || d === null ? '' : String(d);
			default:
				return undefined; // no renderer — never collected
		}
	}

	function seedArgs(act: ActionDef | null): Record<string, unknown> {
		const bag: Record<string, unknown> = {};
		if (!act) return bag;
		for (const arg of act.args) bag[arg.key] = seedValue(arg);
		return bag;
	}

	/** True when the control holds no committed value. Booleans always hold one. */
	function isEmptyValue(kind: ArgControlKind, v: unknown): boolean {
		if (kind === 'toggle') return false;
		if (v === undefined || v === null) return true;
		if (kind === 'money') return v === '' || (v as MoneyValue).value === '';
		return typeof v === 'string' ? v === '' : false;
	}

	/** The same bounds the backend applies: numeric on integer args, length on string args. */
	function outOfRange(bound: 'min' | 'max', n: number): string {
		const label = bound === 'min' ? m.list_filter_min() : m.list_filter_max();
		return m.validation_out_of_range({ reason: `${label} ${n}` });
	}

	function validate(act: ActionDef): Record<string, string> {
		const errs: Record<string, string> = {};
		for (const arg of act.args) {
			const kind = argControl(arg);
			if (!kind) continue; // no renderer — the backend 422 stays the guard
			const v = values[arg.key];
			if (isEmptyValue(kind, v)) {
				if (arg.required) errs[arg.key] = m.validation_required();
				continue;
			}
			if (kind === 'number') {
				const n = typeof v === 'number' ? v : Number(v);
				if (!Number.isFinite(n)) {
					errs[arg.key] = m.validation_invalid_type({ expected: 'number' });
				} else if (arg.min !== undefined && n < arg.min) {
					errs[arg.key] = outOfRange('min', arg.min);
				} else if (arg.max !== undefined && n > arg.max) {
					errs[arg.key] = outOfRange('max', arg.max);
				}
			} else if (kind === 'text' || kind === 'url' || kind === 'tel') {
				const s = String(v);
				if (arg.min !== undefined && s.length < arg.min) {
					errs[arg.key] = outOfRange('min', arg.min);
				} else if (arg.max !== undefined && s.length > arg.max) {
					errs[arg.key] = outOfRange('max', arg.max);
				}
			}
		}
		return errs;
	}

	/** Collect the submitted args. Empty values stay absent keys, so the backend fills the declared default. */
	function buildArgs(act: ActionDef): Record<string, unknown> {
		const out: Record<string, unknown> = {};
		for (const arg of act.args) {
			const kind = argControl(arg);
			if (!kind) continue; // no renderer — absent key, the default applies
			const v = values[arg.key];
			if (isEmptyValue(kind, v)) continue;
			if (kind === 'number') {
				const n = typeof v === 'number' ? v : Number(v);
				if (Number.isFinite(n)) out[arg.key] = n;
			} else {
				out[arg.key] = v;
			}
		}
		return out;
	}

	async function submit(): Promise<void> {
		const act = action;
		if (!act || submitting) return;
		const errs = validate(act);
		errors = errs;
		if (Object.keys(errs).length > 0) return;
		// The host owns the action call: it returns `false` when the action
		// failed, so the prompt stays open with the args intact for a retry.
		submitting = true;
		try {
			const ok = await onsubmit(buildArgs(act));
			if (ok === false) return;
			open = false;
		} finally {
			submitting = false;
		}
	}

	/** Qualify a bare reference target (`Company` → `crm.Company`); undefined opens the picker. */
	function referenceTarget(arg: ArgDef): string | undefined {
		if (!arg.doctype) return undefined;
		return arg.doctype.includes('.') ? arg.doctype : `${domain}.${arg.doctype}`;
	}

	function argLabel(arg: ArgDef): string {
		return humanize(arg.key);
	}
</script>

{#if action}
	<Dialog.Root bind:open>
		<Dialog.Portal>
			<Dialog.Overlay class="argsdlg-overlay" />
			<Dialog.Content class="argsdlg-content">
				<Dialog.Title class="argsdlg-title">{action.label ?? humanize(action.key)}</Dialog.Title>
				{#if action.description}
					<Dialog.Description class="argsdlg-desc">{action.description}</Dialog.Description>
				{/if}

				{#if error}
					<div class="argsdlg-error">
						<AlertBanner message={error.message} details={error.details} />
					</div>
				{/if}

				<div class="argsdlg-fields">
					{#each action.args as arg (arg.key)}
						{@const kind = argControl(arg)}
						{#if kind === 'text' || kind === 'url' || kind === 'tel'}
							<Input
								type={kind}
								label={argLabel(arg)}
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as string}
							/>
						{:else if kind === 'number'}
							<Input
								type="number"
								label={argLabel(arg)}
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as string | number}
							/>
						{:else if kind === 'toggle'}
							<Toggle
								label={argLabel(arg)}
								error={errors[arg.key]}
								bind:checked={values[arg.key] as boolean}
							/>
						{:else if kind === 'select'}
							<Select
								label={argLabel(arg)}
								options={(arg.values ?? []).map((v) => ({
									value: v.key,
									label: v.label ?? humanize(v.key)
								}))}
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as string}
							/>
						{:else if kind === 'money'}
							<MoneyInput
								label={argLabel(arg)}
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as MoneyValue | ''}
							/>
						{:else if kind === 'reference'}
							<ReferencePicker
								label={argLabel(arg)}
								required={arg.required}
								error={errors[arg.key]}
								doctype={referenceTarget(arg)}
								{driver}
								bind:value={values[arg.key] as string}
							/>
						{:else if kind === 'date'}
							<DatetimePicker
								label={argLabel(arg)}
								granularity="date"
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as string}
							/>
						{:else if kind === 'datetime'}
							<DatetimePicker
								label={argLabel(arg)}
								required={arg.required}
								error={errors[arg.key]}
								bind:value={values[arg.key] as string}
							/>
						{/if}
					{/each}
				</div>

				<div class="argsdlg-actions">
					<Button variant="secondary" size="sm" onclick={() => (open = false)}>
						{m.common_cancel()}
					</Button>
					<Button variant="primary" size="sm" onclick={submit} disabled={submitting}>
						{m.common_confirm()}
					</Button>
				</div>
			</Dialog.Content>
		</Dialog.Portal>
	</Dialog.Root>
{/if}

<style>
	/* The overlay, content, title, and description land on Bits UI's own
	   rendered elements, so their classes need :global — the portalled DOM
	   carries no scope class (ConfirmDialog sets the precedent). */
	:global(.argsdlg-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 120;
	}

	:global(.argsdlg-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(440px, 90vw);
		max-height: 80vh;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
		padding: 20px;
		z-index: 121;
	}

	:global(.argsdlg-title) {
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		margin: 0;
	}

	:global(.argsdlg-desc) {
		font-size: 13px;
		color: var(--text-2);
		line-height: 1.5;
		margin: 0;
	}

	.argsdlg-fields {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	/* The banner's page margins do not fit the dialog's own padding. */
	.argsdlg-error :global(.alert-banner) {
		margin: 0;
	}

	.argsdlg-actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 8px;
	}
</style>
