<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import Badge from './Badge.svelte';
	import ColorSwatch from './ColorSwatch.svelte';
	import Money from './Money.svelte';
	import RelativeTime from './RelativeTime.svelte';
	import Duration from './Duration.svelte';
	import PhoneCapsule from './PhoneCapsule.svelte';
	import UrlLink from './UrlLink.svelte';
	import FileArtifact from './FileArtifact.svelte';
	import FileCell from './FileCell.svelte';
	import type { ArtifactGrant } from '$lib/artifacts.js';
	import { asSecretMarker, humanize } from '$lib/doctype/types.js';
	import type { FieldDef, FieldType, MoneyValue } from '$lib/doctype/types.js';
	import { formatRangeValue } from '$lib/utils/relativeTime.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import { cellKind, plainTextValue, referenceTokens } from './cellKind.js';
	import type { Snippet } from 'svelte';

	/**
	 * Render one typed field value for read-only display.
	 *
	 * The shared renderer behind the table's default cells and the
	 * document-view value surfaces. `cellKind.ts` sends each field type to a
	 * render kind; this component draws each kind. A blank value renders as a
	 * muted dash. An untyped value renders as plain text — the `fallback`
	 * text wins when the value is blank.
	 *
	 * A `reference` value renders one cell per token: a collection reference
	 * (`collection: true`) stores a JSON array of qualified ids, and each
	 * unique element hydrates its own capsule — a repeated token renders
	 * once (the dedupe lives in `referenceTokens`). Array values were once
	 * joined into a single comma-joined id, which the backend could never
	 * resolve (404). An `array` field whose `items` are `reference` stores
	 * the same token array, so it renders through the reference kind too —
	 * the item definition carries the target doctype.
	 *
	 * Consumers own their special hooks through snippet props:
	 * `booleanCell` (the table's inline boolean toggle), `referenceCell`
	 * (the table's reference capsule, rendered once per token), `enumCell`
	 * (the table's dense enum pill), and `plainCell` (dense surfaces that
	 * show phone/url values as plain text). A `file` value renders through
	 * the dense `FileCell` when the consumer supplies `fetchArtifact` (the
	 * table does), and through the show-page capsule otherwise. Without a
	 * snippet, each kind renders its canonical form.
	 */
	let {
		value,
		fieldType,
		fieldDef = null,
		fallback = '',
		precision,
		detectIsoDates = false,
		booleanCell,
		enumCell,
		referenceCell,
		plainCell,
		fetchArtifact
	}: {
		/** The raw field value from the document content. */
		value: unknown;
		/** The field's declared type. */
		fieldType: FieldType | null;
		/** The field definition — enum values, money currency, reference doctype. */
		fieldDef?: FieldDef | null;
		/** Plain-text fallback for untyped fields (e.g. interpolated values). */
		fallback?: string;
		/** Money display precision. Omit to let the currency row decide. */
		precision?: number;
		/**
		 * Render untyped text values that parse as ISO-8601 instants through
		 * `RelativeTime`. Table columns may carry no schema, so the table turns
		 * this on; typed surfaces keep raw text.
		 */
		detectIsoDates?: boolean;
		/** Consumer-owned boolean cell. Receives the non-blank value. */
		booleanCell?: Snippet<[unknown]>;
		/** Consumer-owned enum cell. Receives the non-blank value. */
		enumCell?: Snippet<[unknown]>;
		/** Consumer-owned reference cell. Receives the value string and the field definition. */
		referenceCell?: Snippet<[string, FieldDef | null]>;
		/** Consumer-owned plain-text cell for phone/url kinds. Receives the value. */
		plainCell?: Snippet<[unknown]>;
		/**
		 * Injectable artifact metadata fetch for the `file` kind. A consumer that
		 * supplies it gets the dense `FileCell` (filename when cached, the id as
		 * the fallback and the tooltip) instead of the show-page capsule.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
	} = $props();

	/** ISO-8601 instant detector. The time part is required, so a plain
	 * calendar date (`YYYY-MM-DD`) renders verbatim instead of as a relative
	 * label computed from UTC midnight. */
	const ISO_DATE = /^\d{4}-\d{2}-\d{2}T[\d:.]+(Z|[+-]\d{2}:?\d{2})?$/;

	/** True when a field carries no value. An empty array is blank too — it
	 * holds no content, and rendering `"[]"` (or an empty capsule) reads as
	 * broken data rather than as "no value". */
	function isBlankValue(v: unknown): boolean {
		if (Array.isArray(v)) return v.length === 0;
		return v === null || v === undefined || v === '';
	}

	/** Number coercion for duration fields. */
	function toNumber(v: unknown): number {
		if (typeof v === 'number') return Number.isFinite(v) ? v : NaN;
		if (typeof v === 'string') {
			const n = Number(v);
			return Number.isFinite(n) ? n : NaN;
		}
		return NaN;
	}

	/**
	 * Extract a numeric amount + currency from a money field value. Money is
	 * stored as the composite `{value, currency}` object; the `value` member is
	 * a decimal string. Returns `null` for blank or non-money values so the
	 * caller renders the muted dash.
	 */
	function asMoney(v: unknown): { amount: number; currency: string } | null {
		if (v && typeof v === 'object') {
			const mv = v as Partial<MoneyValue>;
			if (typeof mv.value === 'string') {
				const n = Number(mv.value);
				if (Number.isFinite(n)) {
					return { amount: n, currency: (mv.currency ?? fieldDef?.currency) || 'EUR' };
				}
			}
		}
		return null;
	}

	/** Find the declared color for an enum field value, if any. */
	function enumColorFor(f: FieldDef | null | undefined, v: unknown): string | undefined {
		if (!f || !f.values) return undefined;
		const key = String(v ?? '');
		const entry = f.values.find((e) => e.key === key);
		return entry?.color;
	}

	const kind = $derived(cellKind(fieldType, fieldDef));
	const enumTint = $derived(enumColorFor(fieldDef, value));
	// Reference tokens: one per element for a collection reference (a JSON
	// array of qualified ids), one for the scalar. Empty renders the blank
	// dash — never a capsule with a comma-joined (unfetchable) id.
	const refTokens = $derived(referenceTokens(value));
	// An array-of-reference field declares its target doctype on `items`, not
	// on the field itself. The `referenceCell` consumer reads
	// `fieldDef.doctype` for the capsule's doctype hint, so flatten the item
	// definition for the reference render path.
	const referenceFieldDef = $derived.by<FieldDef | null>(() => {
		if (!fieldDef) return null;
		if (
			kind === 'reference' &&
			fieldDef.type === 'array' &&
			fieldDef.items?.type === 'reference' &&
			typeof fieldDef.items.doctype === 'string' &&
			fieldDef.items.doctype.length > 0
		) {
			return { ...fieldDef, doctype: fieldDef.items.doctype };
		}
		return fieldDef;
	});
</script>

{#if isBlankValue(value) && isBlankValue(fallback)}
	<span class="fv-blank">—</span>
{:else if kind === 'text'}
	{#if detectIsoDates && typeof value === 'string' && ISO_DATE.test(value)}
		<RelativeTime date={value} />
	{:else}
		<span class="fv-text">{fallback || plainTextValue(value)}</span>
	{/if}
{:else if isBlankValue(value)}
	<span class="fv-blank">—</span>
{:else if kind === 'reference'}
	{#if refTokens.length === 0}
		<span class="fv-blank">—</span>
	{:else if referenceCell}
		{#each refTokens as ref (ref)}
			{@render referenceCell(ref, referenceFieldDef)}
		{/each}
	{:else}
		<span class="fv-text">{refTokens.join(', ')}</span>
	{/if}
{:else if kind === 'money'}
	{@const mv = asMoney(value)}
	{#if mv}
		<Money amount={mv.amount} currency={mv.currency} {precision} />
	{:else}
		<span class="fv-blank">—</span>
	{/if}
{:else if kind === 'datetime'}
	<RelativeTime date={typeof value === 'string' || value instanceof Date ? value : String(value)} />
{:else if kind === 'date'}
	<!-- A calendar date (`YYYY-MM-DD`) is not an instant: it renders verbatim,
			never through a timezone converter. -->
	<span class="fv-date">{String(value)}</span>
{:else if kind === 'daterange'}
	<span class="fv-date">
		{formatRangeValue(value, fieldType === 'period' ? 'period' : 'dateperiod', displayTimezone())}
	</span>
{:else if kind === 'enum'}
	{#if enumCell}
		{@render enumCell(value)}
	{:else if enumTint}
		<Badge label={humanize(String(value))} tint={enumTint} />
	{:else}
		<Badge label={humanize(String(value))} />
	{/if}
{:else if kind === 'boolean'}
	{#if booleanCell}
		{@render booleanCell(value)}
	{:else}
		<span class="fv-bool" class:fv-bool-true={value === true}>
			{value === true ? '✓' : '✕'}
		</span>
	{/if}
{:else if kind === 'color'}
	<ColorSwatch value={String(value)} />
{:else if kind === 'secret'}
	{@const marker = asSecretMarker(value)}
	{#if marker}
		<Badge label={m.common_marker_set_badge({ mode: marker.mode })} />
	{:else}
		<span class="fv-blank">—</span>
	{/if}
{:else if kind === 'integer'}
	<span class="fv-num">{String(value)}</span>
{:else if kind === 'duration'}
	{@const n = toNumber(value)}
	<!-- 0 is a value, not a blank: `Duration` renders `0s` and clamps a
				 negative. The gate rejects only non-numeric values. -->
	{#if Number.isFinite(n)}
		<Duration value={n} />
	{:else}
		<span class="fv-blank">—</span>
	{/if}
{:else if kind === 'phone' || kind === 'url' || kind === 'file'}
	{#if kind === 'file' && fetchArtifact}
		<FileCell artifactId={String(value)} {fetchArtifact} />
	{:else if plainCell}
		{@render plainCell(value)}
	{:else if kind === 'phone'}
		<PhoneCapsule phone={String(value)} />
	{:else if kind === 'url'}
		<UrlLink href={String(value)} />
	{:else}
		<FileArtifact artifactId={String(value)} />
	{/if}
{/if}

<style>
	.fv-text {
		font-size: 13px;
		color: var(--text);
	}

	/* Data is mono — numbers and dates carry the mono face. */
	.fv-num {
		font-family: var(--font-mono);
		font-variant-ligatures: none;
		font-size: 13px;
		color: var(--text);
	}

	/* Calendar dates and range bounds — data, so mono. */
	.fv-date {
		font-family: var(--font-mono);
		font-variant-ligatures: none;
		font-size: 13px;
		color: var(--text);
		white-space: nowrap;
	}

	.fv-bool {
		font-size: 13px;
		color: var(--danger);
		font-weight: 600;
	}

	.fv-bool-true {
		color: var(--ok);
	}

	.fv-blank {
		color: var(--text-3);
		font-family: var(--font-mono);
	}
</style>
