<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { PencilRuler, DoorOpen, Sparkles, Trash2, Rocket } from '@lucide/svelte';

	/**
	 * Builder mode top bar.
	 *
	 * Per the configure UX brief, the builder top bar carries context state
	 * only (the brief's principle 3): the draft badge, the Build/Preview
	 * segmented toggle, and the publish/discard actions. These apply to
	 * everything below them, so they live here rather than in the page
	 * header of the individual tab surfaces.
	 *
	 * The toggle is segmented rather than a button because preview is a
	 * mode the user flips in and out of continuously while designing; a
	 * button reads as navigation and loses the user's place in the doctype
	 * tree.
	 *
	 * Publish/Discard are surfaced here (not on the page header) because
	 * the brief mandates a single point of truth for "what am I about to
	 * do with this draft" and because they apply to the draft as a whole,
	 * not to the currently-selected tab.
	 *
	 * The chrome matches `Topbar`: same height, surface, and hairline
	 * bottom border. Builder mode shows as a 2px gold edge on top of the
	 * bar, plus the draft pill — no themed background.
	 */

	let {
		message = m.builder_status_live(),
		draftName,
		draftBadge = m.builder_badge_draft(),
		isPreview = false,
		onselectbuild = () => {},
		onselectpreview = () => {},
		isDraft = false,
		checkIssueCount = 0,
		canPublish = false,
		onpublish = () => {},
		ondiscard = () => {},
		exitLabel = m.builder_exit_label(),
		onexit = () => {},
		assistantOpen = false,
		ontoggleassistant = () => {},
		assistantLabel = m.assistant_title(),
		children
	}: {
		/** Status line shown next to the builder icon. */
		message?: string;
		/** Optional draft display name; shown in the chip when present. */
		draftName?: string;
		/** Badge label for the draft mode pill, e.g. "draft". */
		draftBadge?: string;
		/** Whether the builder is currently in preview mode (URL-derived). */
		isPreview?: boolean;
		/** Called when the user clicks the Build segment. */
		onselectbuild?: () => void;
		/** Called when the user clicks the Preview segment. */
		onselectpreview?: () => void;
		/** Whether the active draft is editable (publish/discard are draft-only). */
		isDraft?: boolean;
		/** Open issues on the draft's check; surfaces a count chip on Publish. */
		checkIssueCount?: number;
		/** When false, Publish renders disabled (e.g. while busy). */
		canPublish?: boolean;
		/** Called when the user clicks Publish. */
		onpublish?: () => void;
		/** Called when the user clicks Discard. */
		ondiscard?: () => void;
		/** Label for the exit button on the right. */
		exitLabel?: string;
		/** Called when the user clicks Exit. The parent owns the mode state. */
		onexit?: () => void;
		/** Whether the assistant panel is open. */
		assistantOpen?: boolean;
		/** Called when the user clicks the assistant toggle button. */
		ontoggleassistant?: () => void;
		/** Label for the assistant pill; the layout passes the configured
		 * name so builder and workspace show one name. */
		assistantLabel?: string;
		/** Optional extra content rendered on the right, before Exit. */
		children?: import('svelte').Snippet;
	} = $props();

	const publishTitle = $derived(
		checkIssueCount > 0
			? m.builder_publish_warnings_title({ count: checkIssueCount })
			: m.builder_publish_title()
	);
</script>

<header class="builder-bar">
	<div class="content">
		<span class="ident">
			<PencilRuler class="ident-ic" size={15} stroke-width={1.9} />
			<span class="msg">{draftName ?? message}</span>
		</span>

		{#if isDraft}
			<span class="draft-pill" title={m.builder_draft_pill_title()}>
				{draftBadge}
			</span>
		{/if}

		<div class="segmented" role="group" aria-label={m.builder_mode_title()}>
			<button
				class="seg"
				class:on={!isPreview}
				aria-pressed={!isPreview}
				onclick={onselectbuild}
				type="button"
			>
				{m.builder_tab_build()}
			</button>
			<button
				class="seg"
				class:on={isPreview}
				aria-pressed={isPreview}
				onclick={onselectpreview}
				type="button"
			>
				{m.builder_tab_preview()}
			</button>
		</div>

		<div class="trailing">
			{@render children?.()}
			{#if isDraft}
				<button
					class="publish"
					disabled={!canPublish}
					onclick={onpublish}
					title={publishTitle}
					type="button"
				>
					<Rocket size={13} stroke-width={1.9} />
					{m.builder_publish_button()}{#if checkIssueCount > 0}
						<span class="issue-count">{checkIssueCount}</span>{/if}
				</button>
				<button
					class="ghost discard"
					onclick={ondiscard}
					title={m.builder_discard_title()}
					type="button"
				>
					<Trash2 size={13} stroke-width={1.9} />
					{m.builder_discard_button()}
				</button>
			{/if}
			<button
				class="assistant"
				onclick={ontoggleassistant}
				type="button"
				title={assistantOpen ? m.nav_assistant_close() : m.nav_assistant_open()}
				aria-label={m.nav_assistant_toggle_aria()}
				aria-pressed={assistantOpen}
			>
				<span class="pulse" aria-hidden="true"></span>
				<Sparkles size={14} stroke-width={1.8} />
				{assistantLabel}
			</button>
			<button class="ghost" type="button" onclick={onexit}>
				<DoorOpen size={14} stroke-width={1.9} />
				{exitLabel}
			</button>
		</div>
	</div>
</header>

<style>
	/*
	 * Same chrome as `Topbar`: topbar height, surface background, hairline
	 * bottom border. The 2px gold edge on top is the builder-mode marker —
	 * quiet, and theme-proof because it reads from the accent tokens.
	 */
	.builder-bar {
		position: relative;
		grid-area: top;
		height: var(--topbar-h);
		background: var(--surface);
		border-bottom: 1px solid var(--border);
		display: flex;
		align-items: center;
		padding: 0 18px;
	}

	.builder-bar::before {
		content: '';
		position: absolute;
		top: 0;
		left: 0;
		right: 0;
		height: 2px;
		background: var(--accent);
	}

	.content {
		display: flex;
		align-items: center;
		gap: 12px;
		width: 100%;
		min-width: 0;
	}

	/* ── Left identity: icon + draft name, crumb-style ───── */
	.ident {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font-size: 13px;
		color: var(--text-2);
		min-width: 0;
		max-width: min(40%, 360px);
	}

	.ident :global(.ident-ic) {
		color: var(--text-3);
		flex: none;
	}

	.msg {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		color: var(--text);
		font-weight: 600;
	}

	/* ── Draft pill ──────────────────────────────────────── */
	.draft-pill {
		flex: none;
		padding: 3px 9px;
		border-radius: var(--r-pill);
		background: var(--accent-weak);
		color: var(--accent-ink);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 700;
		text-transform: lowercase;
		letter-spacing: 0.04em;
	}

	/* ── Build / Preview segmented toggle ────────────────── */
	.segmented {
		display: inline-flex;
		align-items: center;
		gap: 2px;
		padding: 2px;
		border-radius: var(--r-pill);
		background: var(--sunken);
		flex: none;
	}

	.seg {
		padding: 4px 12px;
		border: none;
		border-radius: var(--r-pill);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.seg:hover {
		color: var(--text);
	}

	.seg.on {
		background: var(--surface);
		color: var(--text);
		box-shadow: var(--sh-1);
	}

	/* ── Right cluster ───────────────────────────────────── */
	.trailing {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		margin-left: auto;
	}

	/* Primary action — brand gold fill. */
	.publish {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 6px 12px;
		border: none;
		border-radius: var(--r-pill);
		background: var(--accent);
		color: var(--on-accent);
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		white-space: nowrap;
		transition: background 0.12s ease;
	}

	.publish:hover {
		background: var(--accent-press);
	}

	.publish:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* Warning count chip — a surface chip so the warn pair keeps AA on gold. */
	.issue-count {
		padding: 1px 6px;
		border-radius: var(--r-pill);
		background: var(--surface);
		color: var(--warn);
		font-family: var(--font-mono);
		font-size: 10px;
		font-weight: 700;
	}

	/* Quiet bordered action — mirrors Topbar's assistant pill. */
	.ghost {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 5px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		background: var(--surface);
		color: var(--text-2);
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		white-space: nowrap;
		transition:
			border-color 0.12s ease,
			color 0.12s ease;
	}

	.ghost:hover {
		border-color: var(--border-strong);
		color: var(--text);
	}

	.ghost.discard:hover {
		border-color: var(--danger);
		color: var(--danger);
	}

	/* Assistant pill — same control as Topbar's, one name on both surfaces. */
	.assistant {
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 6px 11px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill);
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface);
		cursor: pointer;
		flex: none;
	}

	.assistant:hover {
		border-color: var(--border-strong);
		color: var(--text);
	}

	.assistant .pulse {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--ok);
		box-shadow: 0 0 0 3px var(--ok-weak);
		flex: none;
	}

	/* ── Focus ───────────────────────────────────────────── */
	.seg:focus-visible,
	.publish:focus-visible,
	.ghost:focus-visible,
	.assistant:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}
</style>
