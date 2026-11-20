<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtPitch — the illustration for the first step of the welcome
	 * tour. Typed documents sit inside a gold governance frame, a lock sits
	 * on the frame edge, and a chain of change blocks runs under the frame.
	 *
	 * The frame draws itself, the documents rise, the lock pops shut, the
	 * chain fills in, and the last block pulses. The colours come from the
	 * design tokens, so the art follows the theme of the dialog surface. The
	 * `prefers-reduced-motion` guard in `base.css` stops every animation; the
	 * pulse then keeps its base `opacity: 0` and stays hidden.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-pitch-title">
	<title id="welcome-art-pitch-title">{m.welcome_pitch_art_aria()}</title>

	<!-- Governance layer -->
	<rect class="frame-fill" x="30" y="30" width="340" height="122" rx="14" />
	<path
		class="frame-line"
		pathLength="100"
		d="M200 30 H356 a14 14 0 0 1 14 14 V138 a14 14 0 0 1 -14 14 H44 a14 14 0 0 1 -14 -14 V44 a14 14 0 0 1 14 -14 Z"
	/>

	<!-- Typed documents -->
	<g class="doc d1">
		<rect class="card" x="58" y="48" width="80" height="90" rx="8" />
		<rect class="chip-a" x="68" y="58" width="28" height="8" rx="4" />
		<circle class="line" cx="71" cy="80" r="3" />
		<rect class="line" x="78" y="78" width="48" height="4" rx="2" />
		<circle class="line" cx="71" cy="93" r="3" />
		<rect class="line" x="78" y="91" width="36" height="4" rx="2" />
		<circle class="line" cx="71" cy="106" r="3" />
		<rect class="line" x="78" y="104" width="44" height="4" rx="2" />
		<rect class="line" x="68" y="119" width="30" height="8" rx="4" />
	</g>
	<g class="doc d2">
		<rect class="card" x="160" y="48" width="80" height="90" rx="8" />
		<rect class="chip-b" x="170" y="58" width="34" height="8" rx="4" />
		<circle class="line" cx="173" cy="80" r="3" />
		<rect class="line" x="180" y="78" width="40" height="4" rx="2" />
		<circle class="line" cx="173" cy="93" r="3" />
		<rect class="line" x="180" y="91" width="50" height="4" rx="2" />
		<circle class="line" cx="173" cy="106" r="3" />
		<rect class="line" x="180" y="104" width="30" height="4" rx="2" />
		<rect class="line" x="170" y="119" width="40" height="8" rx="4" />
	</g>
	<g class="doc d3">
		<rect class="card" x="262" y="48" width="80" height="90" rx="8" />
		<rect class="chip-c" x="272" y="58" width="24" height="8" rx="4" />
		<circle class="line" cx="275" cy="80" r="3" />
		<rect class="line" x="282" y="78" width="46" height="4" rx="2" />
		<circle class="line" cx="275" cy="93" r="3" />
		<rect class="line" x="282" y="91" width="34" height="4" rx="2" />
		<circle class="line" cx="275" cy="106" r="3" />
		<rect class="line" x="282" y="104" width="42" height="4" rx="2" />
		<rect class="line" x="272" y="119" width="26" height="8" rx="4" />
	</g>

	<!-- Access control: the lock on the layer edge -->
	<g class="lock">
		<circle class="lock-badge" cx="200" cy="30" r="15" />
		<path class="shackle" d="M195.5 29 v-3.5 a4.5 4.5 0 0 1 9 0 V29" />
		<rect class="lock-body" x="193" y="28.5" width="14" height="10" rx="2" />
		<circle class="lock-keyhole" cx="200" cy="33.5" r="1.6" />
	</g>

	<!-- Verifiable record: the chain of change blocks -->
	<line class="link" pathLength="100" x1="135" y1="177" x2="265" y2="177" />
	<rect class="blk b1 blk-card" x="128" y="170" width="14" height="14" rx="3" />
	<rect class="blk b2 blk-card" x="154" y="170" width="14" height="14" rx="3" />
	<rect class="blk b3 blk-card" x="180" y="170" width="14" height="14" rx="3" />
	<rect class="blk b4 blk-card" x="206" y="170" width="14" height="14" rx="3" />
	<rect class="blk b5 blk-card" x="232" y="170" width="14" height="14" rx="3" />
	<rect class="blk b6 accent" x="258" y="170" width="14" height="14" rx="3" />
	<rect class="pulse" x="258" y="170" width="14" height="14" rx="3" />
</svg>

<style>
	svg {
		display: block;
		width: 100%;
		height: auto;
	}

	/* Design tokens only — the art re-themes with the dialog surface. */
	.accent {
		fill: var(--accent);
	}
	.card {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.line {
		fill: var(--border);
	}
	.chip-a {
		fill: var(--accent);
	}
	.chip-b {
		fill: var(--text-3);
	}
	.chip-c {
		fill: var(--text-2);
	}

	/* Base state is the final frame; every animation plays from hidden, so a
	   static render (no animation support) shows the complete art. */
	.doc {
		animation: rise 0.55s cubic-bezier(0.2, 0.8, 0.2, 1) both;
		transform-box: fill-box;
	}
	.d1 {
		animation-delay: 0.1s;
	}
	.d2 {
		animation-delay: 0.25s;
	}
	.d3 {
		animation-delay: 0.4s;
	}
	@keyframes rise {
		from {
			opacity: 0;
			transform: translateY(12px);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.frame-fill {
		fill: var(--accent-weak);
		animation: fade 0.6s ease-out 1.05s both;
	}
	.frame-line {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.75;
		animation: draw 0.8s ease-in-out 0.75s both;
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
	@keyframes fade {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}

	.lock {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.45s cubic-bezier(0.3, 1.6, 0.5, 1) 1.35s both;
	}
	.lock-badge {
		fill: var(--accent);
		stroke: var(--surface);
		stroke-width: 3;
	}
	.shackle {
		fill: none;
		stroke: var(--on-accent);
		stroke-width: 2;
		stroke-linecap: round;
		animation: close 0.25s ease-in 1.75s both;
	}
	.lock-body {
		fill: var(--on-accent);
	}
	.lock-keyhole {
		fill: var(--accent);
	}
	@keyframes pop {
		from {
			opacity: 0;
			transform: scale(0.4);
		}
		to {
			opacity: 1;
			transform: scale(1);
		}
	}
	@keyframes close {
		from {
			transform: translateY(-3px);
		}
		to {
			transform: none;
		}
	}

	.link {
		stroke: var(--border-strong);
		stroke-width: 1.5;
		animation: draw 1s linear 1.95s both;
	}
	.blk {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.3s cubic-bezier(0.3, 1.6, 0.5, 1) both;
	}
	.blk-card {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.5;
	}
	.b1 {
		animation-delay: 1.95s;
	}
	.b2 {
		animation-delay: 2.1s;
	}
	.b3 {
		animation-delay: 2.25s;
	}
	.b4 {
		animation-delay: 2.4s;
	}
	.b5 {
		animation-delay: 2.55s;
	}
	.b6 {
		animation-delay: 2.7s;
	}
	.pulse {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
		transform-box: fill-box;
		transform-origin: center;
		opacity: 0;
		animation: ring 2.4s ease-out 3.1s infinite;
	}
	@keyframes ring {
		0% {
			opacity: 0.9;
			transform: scale(1);
		}
		70%,
		100% {
			opacity: 0;
			transform: scale(1.9);
		}
	}
</style>
