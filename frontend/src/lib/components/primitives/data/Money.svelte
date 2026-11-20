<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { useCurrencies } from './currencyStore.svelte.js';
	import { canonicalTicker, DEFAULT_CURRENCY } from './currencies.js';
	import { composeMoneyText, formatMoneyAmount } from './format.js';

	let {
		amount,
		currency = DEFAULT_CURRENCY,
		precision,
		...rest
	}: {
		/** Numeric amount to format. */
		amount: number;
		/** Currency ticker. Stored values keep their ticker verbatim; empty falls back to the default. */
		currency?: string;
		/**
		 * Explicit precision override. When omitted the resolved currency row's
		 * `digits` drive the display (row unknown → `2`). Set to `0` for
		 * firmographic estimates and other amounts where cent precision would
		 * imply a false accuracy the source data does not carry.
		 */
		precision?: number;
	} = $props();

	const { resolve } = useCurrencies();

	const ticker = $derived(canonicalTicker(currency));
	const row = $derived(resolve(ticker));
	const digits = $derived(precision ?? row?.digits ?? 2);
	const grouping = $derived(row?.grouping ?? 'standard');
	const label = $derived(row && row.symbol !== '' ? row.symbol : ticker);
	const formatted = $derived(
		composeMoneyText(label, formatMoneyAmount(amount, { digits, grouping }))
	);
</script>

<span class="money" {...rest}>
	{formatted}
</span>

<style>
	/* ── Money ── matches design-guideline "Data is mono" rule ──────────── */
	.money {
		font-family: var(--font-mono);
		font-size: 13px;
		font-weight: 500;
		color: var(--text);
		white-space: nowrap;
	}
</style>
