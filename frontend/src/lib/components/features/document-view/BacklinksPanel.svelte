<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * BacklinksPanel — the "Referenced by" section of the document show page.
	 *
	 * Lists the live documents whose `links` column carries this document's
	 * URN (see `doc/backend/links.md`), fetched through the driver's
	 * `backrefs()` accessor. The server already filters the referrer side by
	 * each doctype's list scope, so only readable referrers ever arrive.
	 *
	 * The section self-hides when the target has no referrers — an empty
	 * backlinks list is metadata noise, not a state worth a placeholder.
	 * A failed load shows an inline error row instead of hiding the section
	 * (the failure is invisible otherwise). Backlinks stay informational:
	 * delete is never blocked by referring documents.
	 */
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { BackrefItem, BackrefsResponse } from '$lib/datasource/types.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';

	let {
		/** Driver used to reach the target document's `backrefs()` accessor. */
		driver,
		/** Target domain. */
		domain,
		/** Target doctype. */
		docType,
		/** Target document id. */
		docId,
		/** Row cap for the section — metadata, not a list page. Past the cap
		 *  the section summarizes with a "more" hint. */
		items = 50
	}: {
		driver: DataDriver;
		domain: string;
		docType: string;
		docId: string;
		items?: number;
	} = $props();

	let rows = $state<BackrefItem[] | null>(null);
	let capped = $state(false);
	let loading = $state(false);
	let errorMsg = $state<string | null>(null);
	// Cancellation counter — a doc id change (QuickView navigation) must not
	// let a stale response overwrite the newer fetch.
	let seq = 0;

	async function load(): Promise<void> {
		const my = ++seq;
		loading = true;
		errorMsg = null;
		try {
			const res: BackrefsResponse = await driver
				.domain(domain)
				.doctype(docType)
				.doc(docId)
				.backrefs({ items });
			if (my !== seq) return;
			rows = res.data;
			capped = res.meta.capped;
		} catch (e) {
			if (my !== seq) return;
			rows = null;
			capped = false;
			errorMsg = errorMessage(e, m.doc_backrefs_load_failed());
		} finally {
			if (my === seq) loading = false;
		}
	}

	$effect(() => {
		void docId;
		void load();
	});

	function hrefFor(item: BackrefItem): string {
		return resolve('/[domain=notApi]/[doctype]/[id]', {
			domain: encodeURIComponent(item.domain),
			doctype: encodeURIComponent(item.doc_type),
			id: encodeURIComponent(item.id)
		});
	}

	function labelFor(item: BackrefItem): string {
		return item.display_name ?? item.id;
	}

	const hidden = $derived(rows !== null && !loading && !errorMsg && rows.length === 0);

	// The section self-hides once the load completed with zero referrers —
	// an empty backlinks list is metadata noise, not a state worth a
	// placeholder. Loading and failed states stay visible.
</script>

{#if !hidden}
	<section class="backlinks" aria-label={m.doc_backrefs_aria()}>
		<h3 class="backlinks-label">{m.doc_backrefs_title()}</h3>

		{#if loading && rows === null}
			<div class="backlinks-status" aria-live="polite">…</div>
		{:else if errorMsg}
			<div class="backlinks-error">{errorMsg}</div>
		{:else if rows !== null}
			<ul class="backlinks-list">
				{#each rows as item (item.domain + '.' + item.doc_type + '.' + item.id)}
					<li class="backlinks-row">
						<!-- hrefFor is a `resolve()`-built href from a helper, invisible to
						     the rule (same disable as the show page's shortcut goto). -->
						<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
						<a class="backlinks-link" href={hrefFor(item)}>
							<span class="backlinks-name">{labelFor(item)}</span>
							<span class="backlinks-doctype">{item.doc_type}</span>
						</a>
					</li>
				{/each}
				{#if capped}
					<li class="backlinks-row backlinks-more">
						{m.doc_backrefs_more({ count: rows.length })}
					</li>
				{/if}
			</ul>
		{/if}
	</section>
{/if}

<style>
	.backlinks {
		display: block;
		min-width: 0;
		/* Stacked below the view template — the section owns its own top
		   rhythm, mirroring `DvtSection`. */
		margin-top: 18px;
	}

	/* Eyebrow label — matches the `DvtSection` heading treatment. */
	.backlinks-label {
		margin: 0 0 10px;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.backlinks-status,
	.backlinks-error {
		font-size: 12px;
		color: var(--text-3);
	}

	.backlinks-error {
		color: var(--danger, #c0392b);
	}

	.backlinks-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.backlinks-link {
		display: flex;
		align-items: baseline;
		gap: 8px;
		min-width: 0;
		padding: 5px 6px;
		border-radius: var(--r, 6px);
		text-decoration: none;
		color: var(--text);
		font-size: 13px;
	}

	.backlinks-link:hover {
		background: var(--surface-2, var(--surface));
	}

	.backlinks-name {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.backlinks-link:hover .backlinks-name {
		text-decoration: underline;
	}

	.backlinks-doctype {
		flex: none;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.backlinks-more {
		padding: 5px 6px;
		font-size: 12px;
		color: var(--text-3);
	}
</style>
