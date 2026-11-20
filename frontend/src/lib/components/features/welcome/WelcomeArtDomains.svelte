<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtDomains — the illustration for the second step of the
	 * welcome tour. Two domain boxes appear over their dashed ghosts: CRM
	 * forms on the left (the plus badge fades as the domain draws in), and
	 * an isometric bundle flies in from the right and unpacks into HR.
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; the transient pieces (ghosts, plus badge,
	 * bundle) then keep their base `opacity: 0`, and the complete art shows.
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-domains-title">
	<title id="welcome-art-domains-title">{m.welcome_domains_art_aria()}</title>

	<!-- Domain A: CRM, created from scratch -->
	<rect class="ghost ghost-a" x="30" y="40" width="160" height="120" rx="14" />
	<g class="plus">
		<circle class="plus-badge" cx="110" cy="100" r="16" />
		<path class="plus-mark" d="M110 93 v14 M103 100 h14" />
	</g>

	<rect class="dom dom-a" x="30" y="40" width="160" height="120" rx="14" />
	<text class="label pop a0" x="46" y="63">{m.welcome_domains_art_crm()}</text>
	<g class="pop a1">
		<rect class="card" x="46" y="76" width="38" height="66" rx="6" />
		<rect class="chip-a" x="53" y="83" width="16" height="6" rx="3" />
		<rect class="line" x="53" y="98" width="24" height="3" rx="1.5" />
		<rect class="line" x="53" y="106" width="18" height="3" rx="1.5" />
		<rect class="line" x="53" y="114" width="22" height="3" rx="1.5" />
	</g>
	<g class="pop a2">
		<rect class="card" x="91" y="76" width="38" height="66" rx="6" />
		<rect class="chip-b" x="98" y="83" width="20" height="6" rx="3" />
		<rect class="line" x="98" y="98" width="20" height="3" rx="1.5" />
		<rect class="line" x="98" y="106" width="24" height="3" rx="1.5" />
		<rect class="line" x="98" y="114" width="16" height="3" rx="1.5" />
	</g>
	<g class="pop a3">
		<rect class="card" x="136" y="76" width="38" height="66" rx="6" />
		<rect class="chip-c" x="143" y="83" width="14" height="6" rx="3" />
		<rect class="line" x="143" y="98" width="22" height="3" rx="1.5" />
		<rect class="line" x="143" y="106" width="16" height="3" rx="1.5" />
		<rect class="line" x="143" y="114" width="24" height="3" rx="1.5" />
	</g>

	<!-- Domain B: HR, imported from another instance -->
	<rect class="ghost ghost-b" x="210" y="40" width="160" height="120" rx="14" />

	<rect class="dom dom-b" x="210" y="40" width="160" height="120" rx="14" />
	<text class="label pop b0" x="226" y="63">{m.welcome_domains_art_hr()}</text>
	<g class="pop b1">
		<rect class="card" x="226" y="76" width="38" height="66" rx="6" />
		<rect class="chip-b" x="233" y="83" width="18" height="6" rx="3" />
		<rect class="line" x="233" y="98" width="24" height="3" rx="1.5" />
		<rect class="line" x="233" y="106" width="16" height="3" rx="1.5" />
		<rect class="line" x="233" y="114" width="20" height="3" rx="1.5" />
	</g>
	<g class="pop b2">
		<rect class="card" x="271" y="76" width="38" height="66" rx="6" />
		<rect class="chip-c" x="278" y="83" width="14" height="6" rx="3" />
		<rect class="line" x="278" y="98" width="22" height="3" rx="1.5" />
		<rect class="line" x="278" y="106" width="24" height="3" rx="1.5" />
		<rect class="line" x="278" y="114" width="14" height="3" rx="1.5" />
	</g>
	<g class="pop b3">
		<rect class="card" x="316" y="76" width="38" height="66" rx="6" />
		<rect class="chip-a" x="323" y="83" width="20" height="6" rx="3" />
		<rect class="line" x="323" y="98" width="18" height="3" rx="1.5" />
		<rect class="line" x="323" y="106" width="24" height="3" rx="1.5" />
		<rect class="line" x="323" y="114" width="20" height="3" rx="1.5" />
	</g>

	<!-- The bundle flies in from the right, then unpacks -->
	<g class="bundle">
		<path class="bundle-top" d="M290 80 L310 90 L290 100 L270 90 Z" />
		<path class="bundle-left" d="M270 90 L290 100 L290 122 L270 112 Z" />
		<path class="bundle-right" d="M310 90 L290 100 L290 122 L310 112 Z" />
		<path class="bundle-shine" d="M280 85 L300 95" />
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
	.dom {
		fill: var(--accent-weak);
		stroke: var(--accent);
		stroke-width: 1.75;
	}
	.ghost {
		fill: none;
		stroke: var(--border-strong);
		stroke-width: 1.5;
		stroke-dasharray: 6 5;
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
	.label {
		font-family: var(--font-display);
		font-size: 12px;
		font-weight: 600;
		letter-spacing: 0.02em;
		fill: var(--text);
	}
	.plus-badge {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.5;
	}
	.plus-mark {
		fill: none;
		stroke: var(--text-3);
		stroke-width: 2;
		stroke-linecap: round;
	}
	.bundle-top {
		fill: var(--accent);
	}
	.bundle-left {
		fill: var(--text-2);
	}
	.bundle-right {
		fill: var(--text-3);
	}
	.bundle-shine {
		fill: none;
		stroke: var(--surface);
		stroke-width: 2;
		opacity: 0.7;
	}

	/* Base state is the final frame; the transient pieces (ghosts, plus
	   badge, bundle) start hidden, so a static render shows the complete
	   art. */
	.pop {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.35s cubic-bezier(0.3, 1.6, 0.5, 1) both;
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

	/* Domain A — from scratch */
	.ghost-a {
		opacity: 0;
		animation: ghostA 0.9s ease-out both;
	}
	@keyframes ghostA {
		0%,
		65% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	.plus {
		opacity: 0;
		transform-box: fill-box;
		transform-origin: center;
		animation: plusOut 0.9s ease-in both;
	}
	@keyframes plusOut {
		0%,
		45% {
			opacity: 1;
			transform: none;
		}
		100% {
			opacity: 0;
			transform: rotate(90deg) scale(0.3);
		}
	}
	.dom-a {
		animation: fade 0.45s ease-out 0.65s both;
	}
	.a0 {
		animation-delay: 0.85s;
	}
	.a1 {
		animation-delay: 0.95s;
	}
	.a2 {
		animation-delay: 1.05s;
	}
	.a3 {
		animation-delay: 1.15s;
	}

	/* Domain B — imported bundle */
	.ghost-b {
		opacity: 0;
		animation: ghostB 2.4s ease-out both;
	}
	@keyframes ghostB {
		0%,
		88% {
			opacity: 1;
		}
		100% {
			opacity: 0;
		}
	}
	.bundle {
		opacity: 0;
		transform-box: fill-box;
		transform-origin: center;
		animation: fly 1.2s cubic-bezier(0.4, 0, 0.2, 1) 1.35s both;
	}
	@keyframes fly {
		0% {
			opacity: 0;
			transform: translate(130px, -34px) rotate(12deg);
		}
		15% {
			opacity: 1;
		}
		65% {
			opacity: 1;
			transform: none;
		}
		80% {
			opacity: 1;
			transform: scale(1.12);
		}
		100% {
			opacity: 0;
			transform: scale(1.5);
		}
	}
	.dom-b {
		animation: fade 0.4s ease-out 2.2s both;
	}
	.b0 {
		animation-delay: 2.3s;
	}
	.b1 {
		animation-delay: 2.4s;
	}
	.b2 {
		animation-delay: 2.5s;
	}
	.b3 {
		animation-delay: 2.6s;
	}
</style>
