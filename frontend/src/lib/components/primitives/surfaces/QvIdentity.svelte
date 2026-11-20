<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import { relativeTime } from '$lib/utils/relativeTime.js';
	import Badge from '../data/Badge.svelte';
	import {
		avatarTintOf,
		deletedTitle,
		displayLabel,
		initialsFromLabel,
		photoUrlOf,
		sourceLabelOf,
		statusBadgeLabel,
		statusBadgeTint,
		statusFieldOf,
		statusValueOf,
		subLabel,
		type QvDeletedDoc
	} from './documentIdentity.js';

	let {
		doc,
		def,
		deleted,
		errorName,
		error
	}: {
		/** Loaded document. Null while the drawer shows the deleted or error state. */
		doc: DocumentResponse<Record<string, unknown>> | null;
		/** Active nav doctype definition. Feeds the status lookup and the avatar tint. */
		def: DoctypeDef;
		/** Tombstone state. Set when the requested document is deleted (`410`). */
		deleted: QvDeletedDoc | null;
		/** Qualified doctype name of the failed request. The error title. */
		errorName: string | null;
		/** Error message. Set when the request failed without a tombstone. */
		error: string | null;
	} = $props();

	// Identity values. The pure helpers in `./documentIdentity.ts`, fed with the props.
	const tint = $derived(avatarTintOf(def));
	const label = $derived(displayLabel(doc));
	const sub = $derived(subLabel(doc));
	const photo = $derived(photoUrlOf(doc));
	const initials = $derived(initialsFromLabel(label));
	const statusField = $derived(statusFieldOf(def));
	const statusValue = $derived(statusValueOf(doc, statusField));
	const badgeLabel = $derived(statusBadgeLabel(statusValue));
	const badgeTint = $derived(statusBadgeTint(statusField, statusValue));
	const source = $derived(sourceLabelOf(doc));
	const updatedRelative = $derived(doc ? relativeTime(doc.meta.updated_at) : '');
</script>

{#if doc?.meta}
	<div class="qv-identity">
		<div class="qv-avatar" style="--tint: {tint}">
			{#if photo}
				<img src={photo} alt="" />
			{:else}
				<span class="qv-avatar-initials">{initials}</span>
			{/if}
		</div>
		<div class="qv-name-block">
			<h2 class="qv-title">{label}</h2>
			{#if sub}
				<p class="qv-sub-label">{sub}</p>
			{/if}
		</div>
		{#if badgeLabel}
			<Badge size="sm" label={badgeLabel} tint={badgeTint} class="qv-status" />
		{/if}
	</div>
	<div class="qv-meta">
		<span class="qv-meta-id">{doc.meta.id}</span>
		{#if doc.meta.version != null}
			<span class="qv-meta-sep">·</span>
			<span class="qv-meta-version">v{doc.meta.version}</span>
		{/if}
		{#if source}
			<span class="qv-meta-sep">·</span>
			<span class="qv-meta-source">{source}</span>
		{/if}
		<span class="qv-meta-sep">·</span>
		<time class="qv-meta-updated" datetime={doc.meta.updated_at}>{updatedRelative}</time>
	</div>
{:else if deleted}
	<div class="qv-identity">
		<div class="qv-name-block">
			<h2 class="qv-title">{deletedTitle(deleted)}</h2>
		</div>
		<Badge size="sm" label={m.common_deleted()} tint="danger" class="qv-status" />
	</div>
{:else if error}
	<h2 class="qv-title qv-title-error">{errorName ?? m.common_error()}</h2>
{/if}

<style>
	/* ── Identity row (avatar + name + subtitle + status pill) ──────────── */
	.qv-identity {
		display: flex;
		align-items: center;
		gap: 12px;
	}

	.qv-avatar {
		flex: none;
		width: 40px;
		height: 40px;
		border-radius: 50%;
		overflow: hidden;
		background: color-mix(in srgb, var(--tint) 14%, transparent);
		color: var(--tint);
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.qv-avatar img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.qv-avatar-initials {
		font-size: 14px;
		font-weight: 600;
		font-family: var(--font-display);
		line-height: 1;
	}

	.qv-name-block {
		min-width: 0;
		flex: 1;
	}

	.qv-title {
		margin: 0;
		font-family: var(--font-display);
		font-size: 17px;
		font-weight: 500;
		letter-spacing: -0.01em;
		color: var(--text);
		line-height: 1.2;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.qv-title.qv-title-error {
		color: var(--danger);
	}

	.qv-sub-label {
		margin: 2px 0 0;
		font-size: 13px;
		color: var(--text-2);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* `class="qv-status"` lands on the `Badge` root span (child component),
	   so scoped analysis doesn't see the usage — declared global to match. */
	:global(.qv-status) {
		flex: none;
	}

	/* ── Meta strip (id · vN · source · updated relative) ───────────────── */
	.qv-meta {
		margin-top: 10px;
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 6px;
	}

	.qv-meta-sep {
		opacity: 0.6;
	}
</style>
