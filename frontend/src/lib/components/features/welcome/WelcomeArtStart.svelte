<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtStart — the illustration for the last step of the welcome
	 * tour. Six tokens recap the tour topics (layers, document, fields,
	 * access, history, integrations) on a gold spine; the spine rises into a
	 * gold badge whose check draws itself, one-shot rings and confetti burst
	 * once, and the badge then floats and breathes.
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; the rings and the breathing halo keep their base
	 * `opacity: 0`, and the confetti shows at its final positions.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-start-title">
	<title id="welcome-art-start-title">{m.welcome_start_art_aria()}</title>

	<!-- Connecting lines -->
	<path class="draw spine rail" pathLength="100" d="M135 166 H265" />
	<path class="draw spine rise" pathLength="100" d="M200 166 V108" />

	<!-- Recap tokens (steps 1-6) -->
	<g class="pop k1">
		<circle class="tok" cx="135" cy="166" r="11" />
		<path
			class="ico"
			d="M130 164 L135 161.5 L140 164 L135 166.5 Z M130 167.5 L135 170 L140 167.5"
		/>
	</g>
	<g class="pop k2">
		<circle class="tok" cx="161" cy="166" r="11" />
		<rect class="ico" x="156" y="161.5" width="10" height="9" rx="2" />
		<path class="ico" d="M156 164.5 H166" />
	</g>
	<g class="pop k3">
		<circle class="tok" cx="187" cy="166" r="11" />
		<text class="glyph" x="187" y="168.5" text-anchor="middle">Aa</text>
	</g>
	<g class="pop k4">
		<circle class="tok" cx="213" cy="166" r="11" />
		<path class="ico" d="M210.6 164.5 v-2 a2.4 2.4 0 0 1 4.8 0 v2" />
		<rect class="ico-fill" x="209" y="164.5" width="8" height="6" rx="1.5" />
	</g>
	<g class="pop k5">
		<circle class="tok" cx="239" cy="166" r="11" />
		<path class="ico" d="M235.6 164 a4.2 4.2 0 1 1 0.4 4.3 M235 161.5 L235.6 164.2 L238.3 163.4" />
	</g>
	<g class="pop k6">
		<circle class="tok" cx="265" cy="166" r="11" />
		<path
			class="ico"
			d="M263 161 V163 M267 161 V163 M261.5 163 H268.5 V165 A3.5 3.5 0 0 1 261.5 165 Z M265 168.5 V171"
		/>
	</g>

	<!-- Confetti (final positions; it flies out from the badge centre) -->
	<g class="cf" style="--dx: 60px; --dy: 40px; animation-delay: 1.35s">
		<rect
			class="cf-a"
			x="136"
			y="34"
			width="9"
			height="5"
			rx="1.5"
			transform="rotate(-25 140 36)"
		/>
	</g>
	<circle
		class="cf"
		style="--dx: -62px; --dy: 42px; animation-delay: 1.4s"
		cx="262"
		cy="36"
		r="3.5"
	/>
	<path
		class="cf cf-a"
		style="--dx: 82px; --dy: -10px; animation-delay: 1.38s"
		d="M118 82 Q119 87 124 88 Q119 89 118 94 Q117 89 112 88 Q117 87 118 82 Z"
	/>
	<g class="cf" style="--dx: -82px; --dy: -18px; animation-delay: 1.42s">
		<rect class="cf-c" x="278" y="93" width="9" height="5" rx="1.5" transform="rotate(30 282 96)" />
	</g>
	<circle
		class="cf cf-a"
		style="--dx: -56px; --dy: -48px; animation-delay: 1.45s"
		cx="256"
		cy="126"
		r="3"
	/>
	<circle
		class="cf cf-c"
		style="--dx: 26px; --dy: 56px; animation-delay: 1.37s"
		cx="174"
		cy="22"
		r="2.5"
	/>
	<g class="cf" style="--dx: -28px; --dy: 58px; animation-delay: 1.43s">
		<rect
			class="cf-a"
			x="223"
			y="17"
			width="8"
			height="4.5"
			rx="1.5"
			transform="rotate(20 227 19)"
		/>
	</g>
	<circle
		class="cf cf-d"
		style="--dx: 90px; --dy: 22px; animation-delay: 1.47s"
		cx="110"
		cy="56"
		r="2.5"
	/>
	<path
		class="cf cf-b"
		style="--dx: -94px; --dy: 20px; animation-delay: 1.41s"
		d="M294 52 Q295 56 299 57 Q295 58 294 62 Q293 58 289 57 Q293 56 294 52 Z"
	/>
	<g class="cf" style="--dx: 52px; --dy: -44px; animation-delay: 1.46s">
		<rect
			class="cf-b"
			x="144"
			y="119"
			width="8"
			height="4.5"
			rx="1.5"
			transform="rotate(-40 148 121)"
		/>
	</g>
	<circle
		class="cf cf-a"
		style="--dx: 100px; --dy: -34px; animation-delay: 1.5s"
		cx="100"
		cy="112"
		r="2"
	/>
	<circle
		class="cf cf-d"
		style="--dx: -104px; --dy: -48px; animation-delay: 1.52s"
		cx="304"
		cy="126"
		r="2"
	/>

	<!-- Badge -->
	<circle class="ring ring1" cx="200" cy="78" r="28" />
	<circle class="ring ring2" cx="200" cy="78" r="28" />
	<circle class="idle" cx="200" cy="78" r="28" />
	<g class="float">
		<g class="badge">
			<circle class="badge-fill" cx="200" cy="78" r="28" />
			<path class="check" pathLength="100" d="M187.5 78.5 L196.5 87.5 L213 70" />
		</g>
	</g>
</svg>

<style>
	svg {
		display: block;
		width: 100%;
		height: auto;
	}

	/* Design tokens only — the art re-themes with the dialog surface. */
	.tok {
		fill: var(--accent-weak);
		stroke: var(--accent);
		stroke-width: 1.25;
	}
	.ico {
		fill: none;
		stroke: var(--text-2);
		stroke-width: 1.25;
		stroke-linecap: round;
		stroke-linejoin: round;
	}
	.ico-fill {
		fill: var(--text-2);
	}
	.glyph {
		font-family: var(--font-display);
		font-size: 7px;
		font-weight: 700;
		fill: var(--text-2);
	}
	.spine {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
	}
	.cf-a {
		fill: var(--accent);
	}
	.cf-b {
		fill: var(--text-2);
	}
	.cf-c {
		fill: var(--text-3);
	}
	.cf-d {
		fill: var(--border-strong);
	}
	.ring {
		fill: none;
		stroke: var(--accent);
	}
	.idle {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.5;
	}
	.badge-fill {
		fill: var(--accent);
	}
	/* Ink on a gold fill is --on-accent (the dark ink), not white. */
	.check {
		fill: none;
		stroke: var(--on-accent);
		stroke-width: 5;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	/* Base state is the final frame; a static render shows the badge with
	   the check and the confetti in place. */
	.pop {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.35s cubic-bezier(0.3, 1.6, 0.5, 1) both;
	}
	.draw {
		stroke-dasharray: 100;
		animation: draw 0.4s ease-in-out both;
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
	@keyframes draw {
		from {
			stroke-dashoffset: 100;
		}
		to {
			stroke-dashoffset: 0;
		}
	}

	/* 1. Recap tokens */
	.k1 {
		animation-delay: 0s;
	}
	.k2 {
		animation-delay: 0.1s;
	}
	.k3 {
		animation-delay: 0.2s;
	}
	.k4 {
		animation-delay: 0.3s;
	}
	.k5 {
		animation-delay: 0.4s;
	}
	.k6 {
		animation-delay: 0.5s;
	}
	.rail {
		animation-delay: 0.6s;
		animation-duration: 0.45s;
	}
	.rise {
		animation-delay: 1s;
		animation-duration: 0.25s;
	}

	/* 2. Badge + check */
	.badge {
		transform-box: fill-box;
		transform-origin: center;
		animation: badge 0.5s cubic-bezier(0.3, 1.7, 0.5, 1) 1.2s both;
	}
	@keyframes badge {
		from {
			opacity: 0;
			transform: scale(0.2);
		}
		to {
			opacity: 1;
			transform: scale(1);
		}
	}
	.check {
		stroke-dasharray: 100;
		animation: draw 0.35s ease-out 1.5s both;
	}

	/* 3. Celebration: one-shot rings + confetti */
	.ring {
		transform-box: fill-box;
		transform-origin: center;
		opacity: 0;
	}
	.ring1 {
		stroke-width: 2;
		animation: ring 1s ease-out 1.4s both;
	}
	.ring2 {
		stroke-width: 1.5;
		animation: ring 1.2s ease-out 1.55s both;
	}
	@keyframes ring {
		0% {
			opacity: 0.9;
			transform: scale(1);
		}
		100% {
			opacity: 0;
			transform: scale(2.1);
		}
	}

	.cf {
		transform-box: fill-box;
		transform-origin: center;
		animation: burst 0.7s cubic-bezier(0.15, 0.8, 0.3, 1) both;
	}
	@keyframes burst {
		from {
			opacity: 0;
			transform: translate(var(--dx), var(--dy)) scale(0.2) rotate(-120deg);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	/* Idle: the badge breathes and floats */
	.idle {
		transform-box: fill-box;
		transform-origin: center;
		opacity: 0;
		animation: ring 2.6s ease-out 3.2s infinite;
	}
	.float {
		animation: float 3.2s ease-in-out 2.4s infinite;
	}
	@keyframes float {
		0%,
		100% {
			transform: none;
		}
		50% {
			transform: translateY(-2px);
		}
	}
</style>
