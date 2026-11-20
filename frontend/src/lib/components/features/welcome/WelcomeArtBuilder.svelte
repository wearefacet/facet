<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtBuilder — the illustration for the third step of the welcome
	 * tour. The assistant prompt types itself out, two hand-off dots pass the
	 * work on, a doctype card fills with typed fields (text, number, date,
	 * reference), wires draw to a referenced doctype and to a table view, and
	 * the DRAFT badge swaps for PUBLISHED.
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; the transient pieces (the draft badge) then keep
	 * their base `opacity: 0`, and the published state shows.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-builder-title">
	<title id="welcome-art-builder-title">{m.welcome_builder_art_aria()}</title>

	<!-- Assistant prompt bubble -->
	<g class="pop">
		<rect class="card" x="18" y="52" width="108" height="62" rx="10" />
		<path class="tail" d="M30 113 l-4 9 l12 -8" />
		<rect class="tail-cover" x="29" y="112" width="12" height="3" />
	</g>
	<path class="sparkle" d="M34 59 Q35 65 41 66 Q35 67 34 73 Q33 67 27 66 Q33 65 34 59 Z" />
	<rect class="line type t1" x="47" y="64" width="64" height="4" rx="2" />
	<rect class="line type t2" x="30" y="80" width="82" height="4" rx="2" />
	<rect class="line type t3" x="30" y="90" width="66" height="4" rx="2" />
	<rect class="line type t4" x="30" y="100" width="74" height="4" rx="2" />

	<!-- Hand-off -->
	<circle class="pop h1 dot" cx="134" cy="83" r="2" />
	<circle class="pop h2 dot" cx="141" cy="83" r="2" />
	<circle class="pop h3 dot" cx="148" cy="83" r="2" />

	<!-- Doctype being built -->
	<g class="fade schema">
		<rect class="card" x="156" y="30" width="138" height="136" rx="10" />
		<rect class="chip-a" x="168" y="42" width="20" height="8" rx="4" />
		<rect class="name" x="193" y="44" width="28" height="4" rx="2" />
		<line class="divider" x1="156" y1="58" x2="294" y2="58" />
	</g>

	<!-- Draft / Published badge -->
	<g class="draft">
		<rect class="badge-draft-bg" x="230" y="38" width="56" height="14" rx="7" />
		<text class="badge badge-draft" x="258" y="47.5" text-anchor="middle"
			>{m.welcome_builder_art_draft()}</text
		>
	</g>
	<g class="pop published">
		<rect class="badge-published-bg" x="230" y="38" width="56" height="14" rx="7" />
		<text class="badge badge-published" x="258" y="47.5" text-anchor="middle"
			>{m.welcome_builder_art_published()}</text
		>
	</g>

	<!-- Field: text -->
	<g class="row r1">
		<rect class="ibox" x="168" y="66" width="18" height="18" rx="4" />
		<text class="glyph" x="177" y="78" text-anchor="middle">Aa</text>
		<rect class="name" x="194" y="70" width="44" height="4" rx="2" />
		<rect class="line" x="194" y="77" width="22" height="3" rx="1.5" />
	</g>
	<!-- Field: number -->
	<g class="row r2">
		<rect class="ibox" x="168" y="90" width="18" height="18" rx="4" />
		<text class="glyph" x="177" y="102.5" text-anchor="middle">#</text>
		<rect class="name" x="194" y="94" width="34" height="4" rx="2" />
		<rect class="line" x="194" y="101" width="18" height="3" rx="1.5" />
	</g>
	<!-- Field: date -->
	<g class="row r3">
		<rect class="ibox" x="168" y="114" width="18" height="18" rx="4" />
		<rect class="date-icon" x="172" y="118.5" width="10" height="9.5" rx="1.5" />
		<line class="date-icon" x1="172" y1="121.5" x2="182" y2="121.5" />
		<rect class="name" x="194" y="118" width="40" height="4" rx="2" />
		<rect class="line" x="194" y="125" width="16" height="3" rx="1.5" />
	</g>
	<!-- Field: reference -->
	<g class="row r4">
		<rect class="tint" x="168" y="138" width="18" height="18" rx="4" />
		<path class="ref-arrow" d="M173 151 L181 143 M176 143 H181 V148" />
		<rect class="name" x="194" y="142" width="38" height="4" rx="2" />
		<rect class="line" x="194" y="149" width="26" height="3" rx="1.5" />
		<circle class="dot" cx="294" cy="147" r="2.5" />
	</g>

	<!-- Reference to another doctype -->
	<path class="wire draw w-ref" pathLength="100" d="M296 147 C307 147 307 133 318 133" />
	<g class="pop ref">
		<rect class="card" x="318" y="110" width="64" height="50" rx="8" />
		<rect class="chip-c" x="327" y="119" width="18" height="6" rx="3" />
		<rect class="line" x="327" y="131" width="42" height="3" rx="1.5" />
		<rect class="line" x="327" y="139" width="30" height="3" rx="1.5" />
		<rect class="line" x="327" y="147" width="36" height="3" rx="1.5" />
	</g>

	<!-- View (table) -->
	<path class="wire draw w-view" pathLength="100" d="M294 72 C306 72 306 64 318 64" />
	<g class="pop view">
		<rect class="card" x="318" y="36" width="64" height="58" rx="8" />
		<rect class="tint" x="326" y="44" width="48" height="7" rx="2" />
		<line class="divider" x1="342" y1="44" x2="342" y2="86" />
		<rect class="line" x="326" y="56" width="12" height="3" rx="1.5" />
		<rect class="line" x="346" y="56" width="24" height="3" rx="1.5" />
		<rect class="line" x="326" y="64" width="12" height="3" rx="1.5" />
		<rect class="line" x="346" y="64" width="18" height="3" rx="1.5" />
		<rect class="line" x="326" y="72" width="12" height="3" rx="1.5" />
		<rect class="line" x="346" y="72" width="26" height="3" rx="1.5" />
		<rect class="line" x="326" y="80" width="12" height="3" rx="1.5" />
		<rect class="line" x="346" y="80" width="20" height="3" rx="1.5" />
	</g>
</svg>

<style>
	svg {
		display: block;
		width: 100%;
		height: auto;
	}

	/* Design tokens only — the art re-themes with the dialog surface. */
	.card {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.line {
		fill: var(--border);
	}
	.name {
		fill: var(--border-strong);
	}
	.ibox {
		fill: var(--sunken);
	}
	.tint {
		fill: var(--accent-weak);
	}
	.chip-a {
		fill: var(--accent);
	}
	.chip-c {
		fill: var(--text-2);
	}
	.divider {
		stroke: var(--border);
		stroke-width: 1.25;
	}
	.dot {
		fill: var(--accent);
	}
	.tail {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
		stroke-linejoin: round;
	}
	.tail-cover {
		fill: var(--surface);
	}
	.glyph {
		font-family: var(--font-display);
		font-size: 8px;
		font-weight: 700;
		fill: var(--text-2);
	}
	.badge {
		font-family: var(--font-display);
		font-size: 7px;
		font-weight: 700;
		letter-spacing: 0.05em;
	}
	.badge-draft {
		fill: var(--text-3);
	}
	.badge-published {
		fill: var(--on-accent);
	}
	.badge-draft-bg {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
		stroke-dasharray: 3 2;
	}
	.badge-published-bg {
		fill: var(--accent);
	}
	.date-icon {
		fill: none;
		stroke: var(--text-2);
		stroke-width: 1.25;
	}
	.ref-arrow {
		fill: none;
		stroke: var(--accent-ink);
		stroke-width: 1.5;
		stroke-linecap: round;
		stroke-linejoin: round;
	}
	.wire {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
		stroke-linecap: round;
	}

	/* Base state is the final frame; the transient pieces (the draft badge)
	   start hidden, so a static render shows the published state. */
	.pop {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.35s cubic-bezier(0.3, 1.6, 0.5, 1) both;
	}
	.fade {
		animation: fade 0.4s ease-out both;
	}
	.type {
		transform-box: fill-box;
		transform-origin: left center;
		animation: type 0.35s steps(8, end) both;
	}
	.row {
		animation: slide 0.4s cubic-bezier(0.2, 0.8, 0.2, 1) both;
	}
	.draw {
		animation: draw 0.45s ease-in-out both;
	}
	@keyframes pop {
		from {
			opacity: 0;
			transform: scale(0.5);
		}
		to {
			opacity: 1;
			transform: scale(1);
		}
	}
	@keyframes fade {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}
	@keyframes type {
		from {
			transform: scaleX(0);
		}
		to {
			transform: scaleX(1);
		}
	}
	@keyframes slide {
		from {
			opacity: 0;
			transform: translateX(-10px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}
	@keyframes draw {
		from {
			stroke-dasharray: 100;
			stroke-dashoffset: 100;
		}
		to {
			stroke-dasharray: 100;
			stroke-dashoffset: 0;
		}
	}

	/* 1. Assistant prompt */
	.t1 {
		animation-delay: 0.15s;
	}
	.t2 {
		animation-delay: 0.45s;
	}
	.t3 {
		animation-delay: 0.7s;
	}
	.t4 {
		animation-delay: 0.95s;
	}
	.sparkle {
		fill: var(--accent);
		transform-box: fill-box;
		transform-origin: center;
		animation:
			pop 0.4s cubic-bezier(0.3, 1.6, 0.5, 1) both,
			twinkle 2.6s ease-in-out 3.2s infinite;
	}
	@keyframes twinkle {
		0%,
		100% {
			transform: scale(1) rotate(0);
		}
		50% {
			transform: scale(0.75) rotate(45deg);
		}
	}

	/* 2. Hand-off dots */
	.h1 {
		animation-delay: 1.2s;
	}
	.h2 {
		animation-delay: 1.3s;
	}
	.h3 {
		animation-delay: 1.4s;
	}

	/* 3. Doctype card + fields */
	.schema {
		animation-delay: 1.45s;
	}
	.r1 {
		animation-delay: 1.65s;
	}
	.r2 {
		animation-delay: 1.85s;
	}
	.r3 {
		animation-delay: 2.05s;
	}
	.r4 {
		animation-delay: 2.25s;
	}

	/* 4. Reference + view */
	.w-ref {
		animation-delay: 2.5s;
	}
	.ref {
		animation-delay: 2.75s;
	}
	.w-view {
		animation-delay: 2.6s;
	}
	.view {
		animation-delay: 2.85s;
	}

	/* 5. Draft, then published */
	.draft {
		opacity: 0;
		animation: draft 3.25s linear both;
	}
	@keyframes draft {
		0%,
		44% {
			opacity: 0;
		}
		46%,
		96% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	.published {
		animation-delay: 3.2s;
	}
</style>
