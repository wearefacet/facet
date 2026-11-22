<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import {
		splitInterpolation,
		resolveInterpolated,
		getDocContent,
		resolveRaw,
		fieldDefFor,
		type InterpolationSegment
	} from '$lib/template-resolve';
	import { referenceLabel, referenceParts } from '$lib/referenceLabel.js';
	import type { HeaderNode, ReferenceClickHandler } from '$lib/template-types';
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import { cellKind, referenceTokens } from '$lib/components/primitives/data/cellKind.js';
	import { useCurrencies } from '$lib/components/primitives/data/currencyStore.svelte.js';
	import { canonicalTicker } from '$lib/components/primitives/data/currencies.js';
	import { composeMoneyText, formatMoneyAmount } from '$lib/components/primitives/data/format.js';
	import ArtifactImage from './ArtifactImage.svelte';
	import type { ArtifactGrant } from '$lib/artifacts.js';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		driver,
		def,
		onreferenceclick,
		fetchArtifact
	}: {
		/** The header template node. */
		template: HeaderNode;
		/** The full document response. */
		document: DocumentResponse;
		/** Driver for reference-label hydration in the subtitle. When omitted,
		 *  the subtitle falls back to plain interpolation (raw ids). */
		driver?: DataDriver;
		/** Doctype definition — used to look up the status enum color and to
		 *  detect `reference`-typed title and subtitle tokens. */
		def?: DoctypeDef;
		/** Click handler for a subtitle rendered as a reference Capsule. */
		onreferenceclick?: ReferenceClickHandler;
		/** Injectable artifact metadata fetcher — used by the logo avatar to
		 *  resolve the stored artifact id to a grant URL. Defaults to
		 *  `GET /Api/core/artifacts/:id` via `apiFetch`. Stories pass a
		 *  synthetic fetcher so the play function can assert the avatar renders. */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
	} = $props();

	const content = $derived(getDocContent(document));
	const hasTitle = $derived(template.title !== undefined && template.title !== '');

	// ── Reference title / subtitle ────────────────────────────────────
	// A `$field` token whose declared type is `reference` must render the
	// target document's label, not its URN. A subtitle that is exactly one
	// reference token renders a hydrated Capsule inline; a mixed string
	// resolves each reference token to its label inline. The title (B-315)
	// follows the same rule but always renders text — a pure reference
	// title shows the hydrated label, a mixed one reuses the segment loop.
	// Without a driver or a definition, both interpolate plainly — the
	// stored values show, as they did before reference tokens were
	// recognized.

	/** A title/subtitle token whose declared field type is `reference`. */
	interface RefToken {
		/** Field key without the leading `$`. */
		key: string;
		/** Qualified target doctype from the definition. */
		doctype: string;
	}

	/** Reference-typed leaf tokens among an interpolation's segments. */
	function refTokensIn(segments: InterpolationSegment[]): RefToken[] {
		if (!def) return [];
		const out: RefToken[] = [];
		for (const seg of segments) {
			// Dotted tokens resolve as plain interpolation — only a leaf field
			// key can be a declared reference.
			if (!seg.isToken || seg.text.includes('.')) continue;
			const fd = fieldDefFor(def, seg.text);
			if (!fd || fd.type !== 'reference') continue;
			if (typeof fd.doctype !== 'string' || fd.doctype.length === 0) continue;
			out.push({ key: seg.text, doctype: fd.doctype });
		}
		return out;
	}

	const subtitleSegments = $derived(template.subtitle ? splitInterpolation(template.subtitle) : []);
	const subtitleRefs = $derived(refTokensIn(subtitleSegments));

	const titleSegments = $derived(template.title ? splitInterpolation(template.title) : []);
	const titleRefs = $derived(refTokensIn(titleSegments));

	/** The pure subtitle case: the whole subtitle is one reference token with
	 *  a stored value — renders as a Capsule instead of text. */
	const subtitleReference = $derived.by<{ doctype: string; value: string } | null>(() => {
		if (!driver || subtitleSegments.length !== 1 || subtitleRefs.length !== 1) return null;
		const raw = resolveRaw(subtitleRefs[0].key, content);
		if (typeof raw !== 'string' || raw.length === 0) return null;
		return { doctype: subtitleRefs[0].doctype, value: raw };
	});

	/** The pure title case: the whole title is one reference token with a
	 *  stored value — renders the hydrated label as text (never a Capsule:
	 *  the title is a heading). B-315. */
	const titleReference = $derived.by<{ doctype: string; value: string } | null>(() => {
		if (!driver || titleSegments.length !== 1 || titleRefs.length !== 1) return null;
		const raw = resolveRaw(titleRefs[0].key, content);
		if (typeof raw !== 'string' || raw.length === 0) return null;
		return { doctype: titleRefs[0].doctype, value: raw };
	});

	/** Resolved labels keyed by the stored reference value. Filled by the
	 *  effect below; a lookup miss renders the id portion until the label
	 *  lands — mirroring Capsule's provisional state. */
	let refLabels = $state<Map<string, string>>(new Map());
	let refSeq = 0;

	/** One label-hydration request: a stored token plus its declared target. */
	interface HydrationTarget {
		value: string;
		doctype: string;
	}

	/** Reference tokens stored on reference-typed chip fields. Empty without
	 *  a driver — nothing can hydrate, so the chips show the stored tokens. */
	const chipRefs = $derived.by<HydrationTarget[]>(() => {
		if (!template.chips || !def || !driver) return [];
		const out: HydrationTarget[] = [];
		for (const key of template.chips) {
			const fd = fieldDefFor(def, key);
			if (!fd || cellKind(fd.type, fd) !== 'reference') continue;
			const doctype = chipRefDoctype(fd);
			if (!doctype) continue;
			for (const token of referenceTokens(resolveRaw(key, content))) {
				out.push({ value: token, doctype });
			}
		}
		return out;
	});

	$effect(() => {
		// The subtitle's pure case renders a Capsule, which hydrates its own
		// label. The mixed subtitle, the title, and the chips render text.
		if (!driver) return;
		const targets: HydrationTarget[] = [];
		const textRefs = [...(subtitleReference ? [] : subtitleRefs), ...titleRefs];
		for (const ref of textRefs) {
			const raw = resolveRaw(ref.key, content);
			if (typeof raw === 'string' && raw.length > 0) {
				targets.push({ value: raw, doctype: ref.doctype });
			}
		}
		targets.push(...chipRefs);
		if (targets.length === 0) return;
		const my = ++refSeq;
		for (const target of targets) {
			void referenceLabel(driver, target.value, target.doctype).then((label) => {
				if (my !== refSeq) return;
				if (refLabels.get(target.value) === label) return;
				// Replace the map — an in-place `set` on the $state Map does not
				// dirty this derived reliably across the await boundary.
				const next = new Map(refLabels);
				next.set(target.value, label);
				refLabels = next;
			});
		}
	});

	const subtitleDisplay = $derived.by<string>(() => {
		if (!template.subtitle) return '';
		if (!driver) return resolveInterpolated(template.subtitle, content);
		if (subtitleReference) return subtitleReference.value;
		let out = '';
		for (const seg of subtitleSegments) {
			if (!seg.isToken) {
				out += seg.text;
				continue;
			}
			const ref = subtitleRefs.find((r) => r.key === seg.text);
			const raw = resolveRaw(seg.text, content);
			if (ref && typeof raw === 'string' && raw.length > 0) {
				const label = refLabels.get(raw);
				out += label ?? referenceParts(raw, ref.doctype)?.id ?? raw;
				continue;
			}
			out += resolveInterpolated(`$${seg.text}`, content);
		}
		return out;
	});

	// ── Reference title (B-315) ──────────────────────────────────────────
	// Mirrors the subtitle handling: reference-typed tokens render the
	// target document's label, not the stored URN. The hydrated label
	// replaces the id once it lands — until then the id shows. Without a
	// driver the title interpolates plainly, as before.
	const titleDisplay = $derived.by<string>(() => {
		if (!template.title) return '';
		if (!driver) return resolveInterpolated(template.title, content);
		if (titleReference) {
			return (
				refLabels.get(titleReference.value) ??
				referenceParts(titleReference.value, titleReference.doctype)?.id ??
				titleReference.value
			);
		}
		let out = '';
		for (const seg of titleSegments) {
			if (!seg.isToken) {
				out += seg.text;
				continue;
			}
			const ref = titleRefs.find((r) => r.key === seg.text);
			const raw = resolveRaw(seg.text, content);
			if (ref && typeof raw === 'string' && raw.length > 0) {
				const label = refLabels.get(raw);
				out += label ?? referenceParts(raw, ref.doctype)?.id ?? raw;
				continue;
			}
			out += resolveInterpolated(`$${seg.text}`, content);
		}
		return out;
	});

	/** Snake_case value → human-readable chip label. */
	function humanize(v: string): string {
		return v.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
	}

	// ── Status chip ──────────────────────────────────────────────────────────
	// The only color-bearing chip. When the doctype declares an enum `color`
	// for the current value, that color is used; otherwise the chip falls back
	// to the neutral Badge variant. Categorical chips below never get a tint.
	const statusDef = $derived(template.statusField ? fieldDefFor(def, template.statusField) : null);
	const statusValue = $derived(
		template.statusField ? resolveRaw(template.statusField, content) : undefined
	);
	const statusColor = $derived.by<string | undefined>(() => {
		if (!statusDef?.values || statusValue == null) return undefined;
		const entry = statusDef.values.find((e) => e.key === String(statusValue));
		return entry?.color;
	});
	// The declared enum label wins; the humanized value is only the fallback
	// for a key with no declared label. Mirrors the table's enum cell.
	const statusLabel = $derived.by<string>(() => {
		if (statusValue == null || statusValue === '') return '';
		const entry = statusDef?.values?.find((e) => e.key === String(statusValue));
		return entry?.label ?? humanize(String(statusValue));
	});

	// ── Logo avatar ───────────────────────────────────────────────────────────
	// Resolves the `logo` field (a `file`-typed field whose value is a bare
	// artifact id) to a displayable avatar, rendered left of the title. The
	// avatar fetch is owned by `ArtifactImage`; here we only need the id.
	const logoId = $derived(
		template.logo ? (resolveRaw(template.logo, content) as string | undefined) : undefined
	);

	// ── Categorical chips ────────────────────────────────────────────────────
	// Neutral by definition. Rendered as plain text pills; color is reserved
	// for the status field, where the value changes what you would do next.
	// The label dispatch follows the field type, as the title and subtitle do:
	// - A declared enum label wins, as on the status chip.
	// - A reference field (scalar or collection) renders one chip per stored
	//   token. The label hydrates through the shared resolver. While a label
	//   loads, the id portion shows. Without a driver the stored token shows.
	// - A money field renders through the same `formatMoneyAmount` +
	//   `composeMoneyText` pair as the show page (`Money.svelte`), so one
	//   stored `{value, currency}` pair reads the same on every surface.
	// - Every other non-string value goes through the shared typed-text
	//   pipeline (`resolveInterpolated`): a secret marker renders empty (the
	//   chip is dropped), and any other object or array renders as JSON.
	//   `String(v)` is never used on an object here — it prints the
	//   "[object Object]" artifact.
	// - String, number, and boolean values keep the humanized form.

	const { resolve: resolveCurrency } = useCurrencies();

	/**
	 * Display text of a money-shaped value, formatted as the show page does.
	 * Returns `null` when the value is not a money pair. The currency row's
	 * `digits` and `grouping` drive the amount; an unknown ticker renders the
	 * bare ticker with 2 digits (the `Money` fallback).
	 */
	function moneyChipText(v: object): string | null {
		const o = v as Record<string, unknown>;
		if (typeof o['currency'] !== 'string' || o['currency'].length === 0) return null;
		const raw = o['value'];
		const amount = typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : raw;
		if (typeof amount !== 'number' || !Number.isFinite(amount)) return null;
		const ticker = canonicalTicker(o['currency']);
		const row = resolveCurrency(ticker);
		const label = row && row.symbol !== '' ? row.symbol : ticker;
		return composeMoneyText(
			label,
			formatMoneyAmount(amount, { digits: row?.digits ?? 2, grouping: row?.grouping ?? 'standard' })
		);
	}

	/** Declared hydration target of a reference-typed chip field. A reference
	 *  carries the doctype itself; an `array` field whose items are references
	 *  carries it on `items`. */
	function chipRefDoctype(fd: FieldDef): string | undefined {
		if (typeof fd.doctype === 'string' && fd.doctype.length > 0) return fd.doctype;
		const items = fd.items;
		if (
			items &&
			items.type === 'reference' &&
			typeof items.doctype === 'string' &&
			items.doctype.length > 0
		) {
			return items.doctype;
		}
		return undefined;
	}

	/** Label of one reference chip token. */
	function chipRefLabel(token: string, doctype: string | undefined): string {
		if (!driver) return token;
		return refLabels.get(token) ?? referenceParts(token, doctype)?.id ?? token;
	}

	type Chip = { label: string };
	const chips = $derived.by<Chip[]>(() => {
		if (!template.chips) return [];
		const out: Chip[] = [];
		for (const key of template.chips) {
			const v = resolveRaw(key, content);
			if (v == null || v === '') continue;
			const fd = fieldDefFor(def, key);
			const declared = fd?.values?.find((e) => e.key === String(v))?.label;
			if (declared !== undefined) {
				out.push({ label: declared });
				continue;
			}
			if (fd && cellKind(fd.type, fd) === 'reference') {
				const doctype = chipRefDoctype(fd);
				for (const token of referenceTokens(v)) {
					out.push({ label: chipRefLabel(token, doctype) });
				}
				continue;
			}
			if (typeof v === 'object') {
				const money = moneyChipText(v);
				if (money !== null) {
					out.push({ label: money });
					continue;
				}
				const text = resolveInterpolated(`$${key}`, content);
				if (text === '') continue;
				out.push({ label: text });
				continue;
			}
			out.push({ label: humanize(String(v)) });
		}
		return out;
	});
</script>

<header class="dvt-header" class:has-logo={Boolean(logoId)}>
	{#if logoId}
		<ArtifactImage
			artifactId={logoId}
			{fetchArtifact}
			variant="avatar"
			size={56}
			alt={titleDisplay}
		/>
	{/if}
	<div class="dvt-header-text">
		{#if hasTitle}
			<h2 class="dvt-header-title">{titleDisplay}</h2>
		{/if}

		<div class="dvt-header-chips">
			{#if statusLabel}
				<Badge label={statusLabel} tint={statusColor} />
			{/if}

			{#each chips as chip, i (i)}
				<Badge label={chip.label} variant="neutral" />
			{/each}
		</div>

		{#if subtitleDisplay}
			<span class="dvt-header-subtitle">
				{#if subtitleReference}
					<Capsule
						{driver}
						reference={subtitleReference.value}
						qualifiedDoctype={subtitleReference.doctype}
						{onreferenceclick}
					/>
				{:else}
					{subtitleDisplay}
				{/if}
			</span>
		{/if}
	</div>
</header>

<style>
	.dvt-header {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	/* Without a logo the header must wrap: the subtitle owns a full row
	   (`flex: 1 0 100%` below) and can only reach its own line when the
	   container wraps. Without wrapping, the 100% basis is measured against
	   the whole row and the subtitle sticks out past the right edge by the
	   width of the title + chips that precede it — a horizontal scrollbar
	   on the show page's document column. */
	.dvt-header:not(.has-logo) {
		flex-wrap: wrap;
	}

	/* Without a logo, the text content lives directly in the header so the
	   existing chip-wrap-below behaviour is unchanged. */
	.dvt-header-text {
		display: contents;
	}

	/* With a logo, the text + chips + subtitle collapse into a column so the
	   avatar stays vertically centered against the whole header content and
	   chips wrap inside the column rather than across the full header width. */
	.dvt-header.has-logo {
		flex-wrap: nowrap;
	}

	.dvt-header.has-logo .dvt-header-text {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 6px;
		min-width: 0;
		flex: 1 1 auto;
	}

	.dvt-header-chips {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 8px;
	}

	.dvt-header-title {
		margin: 0;
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
		color: var(--text);
		line-height: 1.2;
		/* Title takes the space it needs; chips wrap below on narrow viewports. */
		flex: 0 1 auto;
		min-width: 0;
	}

	/* The doctype chrome (DoctypeHeader) owns the page's h1; the DVT header
	   title is a section-level heading to avoid two h1s on the show page. */

	.dvt-header-subtitle {
		font-size: 13px;
		color: var(--text-2);
		line-height: 1.4;
	}

	/* Without a logo, the subtitle falls to its own line beneath the chips so
	   it does not share a row with the chips + title cluster. */
	.dvt-header:not(.has-logo) .dvt-header-subtitle {
		flex: 1 0 100%;
		margin-top: 2px;
	}
</style>
