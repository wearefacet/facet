<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Tooltip } from 'bits-ui';
	import { CircleAlert, Trash2 } from '@lucide/svelte';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { DataSourceError } from '$lib/datasource/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { doctypeTintForDomain, type DoctypeTint } from '$lib/doctype/tint.js';
	import '../shared.css';

	/**
	 * Resolve the doctype-definition registry via the global 60s TTL cache
	 * (see `clientCache.ts`). Many capsules rendering together share one
	 * `core.DocType` round-trip; the previous per-driver `WeakMap` never hit
	 * because every route load instantiated a fresh driver.
	 */
	function registryFor(driver: DataDriver): Promise<DoctypeRegistry> {
		return DoctypeRegistry.cached(driver);
	}

	/**
	 * Split a qualified document id (`"crm.Deal.1"`) into its three parts.
	 * Returns `null` when the value does not match the `domain.Type.id` shape;
	 * callers (e.g. `DvtField`) already gate on a reference field, so this
	 * is only a defensive parse.
	 */
	function splitQualified(value: string): { domain: string; doctype: string; id: string } | null {
		const firstDot = value.indexOf('.');
		if (firstDot < 1) return null;
		const secondDot = value.indexOf('.', firstDot + 1);
		if (secondDot < 0) return null;
		const domain = value.slice(0, firstDot);
		const doctype = value.slice(firstDot + 1, secondDot);
		const id = value.slice(secondDot + 1);
		if (id.length === 0) return null;
		return { domain, doctype, id };
	}

	/**
	 * Derive a fallback label from a referenced document's content when its
	 * `meta.display_name` is null/empty. Mirrors `MockDataSource.deriveDisplayName`
	 * so storybook-test rendering matches the production fallback contract:
	 * try `display_name` → `name` → `title` → `label` content fields, then the id.
	 *
	 * This handles doctypes whose definitions carry no `display_name:` template
	 * and were not imported via `domain:import` (which would otherwise
	 * populate `projections.display_name` server-side). Even after backend fixes,
	 * hand-written docs from `Mutation::Client.create` callers that bypass
	 * `Document::ProjectionGucs.set_all` (e.g. audit rollback fallbacks for
	 * tombstoned defs) may land with a NULL display_name — the capsule then
	 * still surfaces something readable instead of the bare id.
	 */
	function deriveFallbackLabel(content: Record<string, unknown> | undefined, id: string): string {
		if (content && typeof content === 'object') {
			for (const k of ['display_name', 'name', 'title', 'label'] as const) {
				const v = content[k];
				if (typeof v === 'string' && v.length > 0) return v;
			}
		}
		return id;
	}

	/**
	 * Combine the optional `qualifiedDoctype` hint with the value itself to
	 * split it into `(domain, doctype, id)`. This supports both qualified ids
	 * (e.g. `"crm.Deal.1"`) and bare ids whose doctype is only known via the
	 * reference field declaration (e.g. `"account_recruiter_kim"` for `iam.Account`).
	 * Returns `null` when neither source yields a doctype.
	 */
	function resolveParts(
		value: string,
		qualifiedDoctype: string | undefined
	): { domain: string; doctype: string; id: string } | null {
		const fromValue = splitQualified(value);
		if (fromValue) return fromValue;
		if (!qualifiedDoctype) return null;
		const dot = qualifiedDoctype.indexOf('.');
		if (dot < 1) return null;
		const domain = qualifiedDoctype.slice(0, dot);
		const doctype = qualifiedDoctype.slice(dot + 1);
		return { domain, doctype, id: value };
	}

	let {
		doctype,
		label,
		href,
		suffix,
		driver,
		reference,
		qualifiedDoctype,
		onreferenceclick,
		children,
		...rest
	}: {
		/** Per-doctype tint variant. Used as a fallback when `reference` is unset or the referenced doctype has no `color`. */
		doctype?: DoctypeTint;
		/** Capsule label text (alternative to children snippet). Overridden when `driver` + `reference` hydrate. */
		label?: string;
		/** When provided, renders as a link. */
		href?: string;
		/** Optional text/icon shown after the label (e.g. serial number). */
		suffix?: string;
		/**
		 * Optional driver — when paired with `reference`, hydrates the capsule
		 * label by fetching the referenced document's `meta.display_name`.
		 * On failure (RBAC, 404, network), the label falls back to the
		 * dotted `domain.Type.id` with a `(?)` indicator on the right.
		 */
		driver?: DataDriver;
		/**
		 * Qualified document id (e.g. `"crm.Deal.1"`). When set alongside
		 * `driver`, the capsule also resolves the referenced doctype's color
		 * for tinting — falling back to the static `doctype` prop or the
		 * domain-level tint when no color is found.
		 */
		reference?: string;
		/**
		 * Optional qualified doctype hint (e.g. `"iam.Account"`) used when the
		 * reference value is a bare id whose doctype is only known from the
		 * referencer's field declaration. Forwarded by `DvtField` when rendering
		 * a recognized reference field.
		 */
		qualifiedDoctype?: string;
		/**
		 * Optional click handler for hydrated reference capsules. When set,
		 * the capsule renders as a `<button>` and fires with the referenced
		 * `{ domain, doctype, id }` on click — typically wired by a parent
		 * drawer (e.g. QuickView) so clicking switches the preview to the
		 * referenced document. Ignored when `reference` is unset (no hydrated
		 * target → nothing meaningful to select).
		 */
		onreferenceclick?: (e: { domain: string; doctype: string; id: string }) => void;
		children?: import('svelte').Snippet;
	} = $props();

	const parts = $derived(reference ? resolveParts(reference, qualifiedDoctype) : null);

	// Hydration state: label string + whether the fetch failed. When `driver`
	// and `reference` are absent, `hydrated` stays `null` and the capsule
	// renders `label`/`children` as before. `deleted` marks a `410` tombstone
	// response — the label resolved, but the target is gone.
	let hydrated = $state<{ label: string; failed: boolean; deleted?: boolean } | null>(null);
	// Cancellation counter for label hydration fetches only.
	let labelSeq = 0;

	// Resolved color for the referenced doctype (looked up via the
	// DoctypeRegistry mirror of `core.DocType`). `null` means fall back to
	// the static `--dt-*` tint bucket selected below.
	let resolvedColor = $state<string | null>(null);
	// Resolved icon for the referenced doctype, looked up the same way.
	// `null` → the icon renderer falls back to the diamond mark.
	let resolvedIcon = $state<string | null>(null);
	// Cancellation counter for tint/icon lookup fetches only.
	let colorSeq = 0;

	$effect(() => {
		if (!driver || !parts) {
			resolvedColor = null;
			resolvedIcon = null;
			return;
		}
		const my = ++colorSeq;
		const target = `${parts.domain}.${parts.doctype}`;
		registryFor(driver)
			.then((reg) => {
				if (my !== colorSeq) return;
				const raw = reg.doctypeDefinitions.get(target);
				const c = raw?.color;
				resolvedColor = typeof c === 'string' && c.length > 0 ? c : null;
				const ic = raw?.icon;
				resolvedIcon = typeof ic === 'string' && ic.length > 0 ? ic : null;
			})
			.catch(() => {
				if (my !== colorSeq) return;
				resolvedColor = null;
				resolvedIcon = null;
			});
	});

	// Resolved tint token: when hydrating, prefer the referenced doctype's
	// color; otherwise use the explicit `doctype` prop, then the domain-level
	// fallback, then `document` as a last resort.
	const tintKey = $derived.by<DoctypeTint>(() => {
		if (parts) return doctypeTintForDomain(parts.domain);
		return doctype ?? 'document';
	});

	$effect(() => {
		if (!driver || !parts) {
			hydrated = null;
			return;
		}
		const my = ++labelSeq;
		const { domain, doctype: dt, id } = parts;
		// Provisional: show the id portion while the fetch is in flight.
		hydrated = { label: id, failed: false };

		(async () => {
			try {
				// `reference` is the stored value — a fully qualified token
				// (`"crm.Deal.1"`) or a bare id paired with the field's declared
				// doctype. The backend resolves the id shape at the route layer
				// (see `doc/backend/http-layer.md` → Document id forms), so a
				// single fetch covers live rows, seed-fixture rows and tombstones.
				const res = await driver
					.domain(domain)
					.doctype(dt)
					.doc(reference as string)
					.show();
				if (my !== labelSeq) return;
				// Prefer the backend-computed `meta.display_name` (always populated
				// when the doctype has a `display_name:` template and `ProjectionGucs`
				// was staged at write time). Fall back to deriving a label from
				// the document content — handles template-less doctypes and rows
				// written through code paths that bypass `set_all`.
				const data = res.data as Record<string, unknown> | undefined;
				const name = res.meta.display_name ?? deriveFallbackLabel(data, id);
				hydrated = { label: name, failed: false };
			} catch (err) {
				if (my !== labelSeq) return;
				if (err instanceof DataSourceError && err.status === 410) {
					// Tombstone: the backend carries the surviving label in the
					// error body — render it as a resolved capsule, not a failure.
					const label =
						typeof err.meta?.display_name === 'string' && err.meta.display_name.length > 0
							? err.meta.display_name
							: (reference as string);
					hydrated = { label, failed: false, deleted: true };
					return;
				}
				// Keep the dotted qualified id as the fallback label so the user
				// sees something they can act on (copy, search, …).
				hydrated = { label: reference as string, failed: true };
			}
		})();
	});

	const displayLabel = $derived(hydrated?.label ?? label);
	const hasFailed = $derived(hydrated?.failed ?? false);
	const isDeleted = $derived(hydrated?.deleted ?? false);
	const cls = $derived(['capsule', `capsule-${tintKey}`].join(' '));
	const styleTint = $derived(resolvedColor ? `--tint: ${resolvedColor};` : undefined);

	// Capsule labels can get long (e.g. a contact's full name in a table cell).
	// Truncate the visible label to keep the capsule from blowing out the row
	// width; the full name is still surfaced via the hover `title` tooltip below
	// so the user can read it without leaving the surface.
	const MAX_LABEL_LENGTH = 32;
	const visibleLabel = $derived(
		displayLabel && displayLabel.length > MAX_LABEL_LENGTH
			? displayLabel.slice(0, MAX_LABEL_LENGTH) + '…'
			: displayLabel
	);
	const tooltipTitle = $derived(
		displayLabel && displayLabel.length > MAX_LABEL_LENGTH ? displayLabel : undefined
	);

	// Capsule is clickable when both a hydrated reference target exists AND a
	// click handler is wired. Bare `label` capsules (no `reference`) stay
	// non-interactive — they're display-only badges.
	const clickable = $derived(!!onreferenceclick && !!parts && !!reference);

	// Which element renders this capsule: a button (clickable reference), a
	// link (has `href`), or a plain span. One element keeps the body markup
	// and the capsule CSS shared across the three variants.
	const tag = $derived(clickable ? 'button' : href ? 'a' : 'span');

	// Status of a hydrated reference, when it needs a warning badge.
	// `null` → no badge; the two states share one tooltip structure.
	const status = $derived.by(() => {
		if (isDeleted) {
			return {
				note: m.doc_capsule_deleted_note(),
				message: m.doc_capsule_deleted_message()
			};
		}
		if (hasFailed) {
			return {
				note: m.doc_capsule_load_failed_note(),
				message: m.doc_capsule_load_failed()
			};
		}
		return null;
	});

	function handleClick(e: MouseEvent) {
		// Prevent the link variant from navigating if both `href` and
		// `onreferenceclick` happen to be set (unlikely, but defensive).
		if (!onreferenceclick || !parts || !reference) return;
		e.preventDefault();
		// Stop the click from bubbling into ancestor handlers (e.g. a table
		// row's `onRowClick` that would otherwise open a different document).
		e.stopPropagation();
		onreferenceclick({ domain: parts.domain, doctype: parts.doctype, id: reference });
	}
</script>

{#snippet statusMarker()}
	{#if status}
		<Tooltip.Provider>
			<Tooltip.Root>
				<Tooltip.Trigger>
					{#if isDeleted}
						<Trash2 class="capsule-warn" size={12} strokeWidth={2} aria-hidden="true" />
					{:else}
						<CircleAlert class="capsule-warn" size={12} strokeWidth={2} aria-hidden="true" />
					{/if}
					<span class="sr-only">{status.note}</span>
				</Tooltip.Trigger>
				<Tooltip.Portal>
					<Tooltip.Content class="tooltip-pop">
						{status.message}
						<Tooltip.Arrow />
					</Tooltip.Content>
				</Tooltip.Portal>
			</Tooltip.Root>
		</Tooltip.Provider>
	{/if}
{/snippet}

{#snippet body()}
	<DoctypeIcon icon={resolvedIcon} color={resolvedColor} shadow active />
	{@render children?.()}
	{visibleLabel}
	{#if suffix}
		<span style="color: var(--text-3)">{suffix}</span>
	{/if}
	{@render statusMarker()}
{/snippet}

<!-- One element for the three variants: button (clickable), a (link), span. -->
<svelte:element
	this={tag}
	href={tag === 'a' ? href : undefined}
	class={cls}
	style={styleTint}
	type={tag === 'button' ? 'button' : undefined}
	{...rest}
	title={tooltipTitle}
	onclick={clickable ? handleClick : undefined}
>
	{@render body()}
</svelte:element>

<style>
	/* ── Capsule (doctype identifier) — matches design-guideline .cap ────── */
	.capsule {
		--tint: var(--text-2);
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 1px 8px 1px 7px;
		border-radius: var(--r-sm);
		border: 1px solid color-mix(in srgb, var(--tint) 34%, transparent);
		background: color-mix(in srgb, var(--tint) 9%, var(--surface));
		font-family: var(--font-mono);
		font-size: 11.5px;
		font-weight: 500;
		line-height: 18px;
		color: color-mix(in srgb, var(--tint) 70%, var(--text));
		text-decoration: none;
		white-space: nowrap;
	}

	/* When rendered as a `<button>` (clickable reference capsule), reset the
	   user-agent button defaults and add a hover/focus affordance. */
	button.capsule {
		cursor: pointer;
	}

	button.capsule:hover,
	button.capsule:focus-visible {
		background: color-mix(in srgb, var(--tint) 18%, var(--surface));
		border-color: color-mix(in srgb, var(--tint) 50%, transparent);
		outline: none;
	}

	button.capsule:focus-visible {
		box-shadow: 0 0 0 2px color-mix(in srgb, var(--tint) 60%, transparent);
	}

	/* Failure indicator — same slot as `suffix`, but tinted danger. */
	.capsule-warn {
		color: var(--danger);
	}

	/* Bits UI renders `<Tooltip.Trigger>` as a `<button>` — inline it inside
	   the capsule so the icon sits next to the label without breaking layout. */
	.capsule :global([data-tooltip-trigger]) {
		display: inline-flex;
		align-items: center;
		padding: 0;
		margin: 0 0 0 2px;
		border: none;
		background: transparent;
		color: var(--danger);
		cursor: help;
		font: inherit;
		line-height: 1;
	}

	/* Label for screen readers — visually hidden but available to AT. */
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}

	/* Bits UI Tooltip content — the shared tooltip shape. */

	/* Per-doctype tints */
	.capsule-invoice {
		--tint: var(--dt-invoice);
	}
	.capsule-shipment {
		--tint: var(--dt-shipment);
	}
	.capsule-contact {
		--tint: var(--dt-contact);
	}
	.capsule-task {
		--tint: var(--dt-task);
	}
	.capsule-document {
		--tint: var(--dt-document);
	}
	.capsule-contract {
		--tint: var(--dt-contract);
	}
</style>
