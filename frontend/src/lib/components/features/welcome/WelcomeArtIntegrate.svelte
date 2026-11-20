<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	/**
	 * WelcomeArtIntegrate — the illustration for the sixth step of the
	 * welcome tour. Two triggers (a document change and a clock) feed a Lua
	 * script, the script feeds the Facet hub, the hub sits on the
	 * PostgreSQL cylinder, four connection pills branch off (REST API, API
	 * keys, OAuth, MCP), and a bundle ships from the hub into an export
	 * slot. In the idle state, gold dashes flow along every wire.
	 *
	 * The colours come from the design tokens, so the art follows the theme
	 * of the dialog surface. The `prefers-reduced-motion` guard in `base.css`
	 * stops every animation; this component also hides the flow overlay in
	 * that case (the global guard cannot — the dashes show as a static
	 * layer, which the design does not want at rest).
	 */
</script>

<svg viewBox="0 0 400 200" role="img" aria-labelledby="welcome-art-integrate-title">
	<title id="welcome-art-integrate-title">{m.welcome_integrate_art_aria()}</title>

	<!-- Wires (base) -->
	<path class="wire draw w-t1" pathLength="100" d="M43 64 C57 64 56 76 70 76" />
	<path class="wire draw w-t2" pathLength="100" d="M43 108 C57 108 56 96 70 96" />
	<path class="wire draw w-s" pathLength="100" d="M136 86 H176" />
	<path class="wire draw w-db" pathLength="100" d="M200 110 V131" />
	<path class="wire draw w-c1" pathLength="100" d="M224 86 C248 86 244 40 268 40" />
	<path class="wire draw w-c2" pathLength="100" d="M224 86 C248 86 244 66 268 66" />
	<path class="wire draw w-c3" pathLength="100" d="M224 86 C248 86 244 92 268 92" />
	<path class="wire draw w-c4" pathLength="100" d="M224 86 C248 86 244 118 268 118" />
	<path class="wire draw w-x" pathLength="100" d="M218 110 C236 150 262 164 312 164" />

	<!-- Flow overlay (idle) -->
	<path class="flow" d="M43 64 C57 64 56 76 70 76" />
	<path class="flow" d="M43 108 C57 108 56 96 70 96" />
	<path class="flow" d="M136 86 H176" />
	<path class="flow" d="M200 110 V131" />
	<path class="flow" d="M224 86 C248 86 244 40 268 40" />
	<path class="flow" d="M224 86 C248 86 244 66 268 66" />
	<path class="flow" d="M224 86 C248 86 244 92 268 92" />
	<path class="flow" d="M224 86 C248 86 244 118 268 118" />

	<!-- Triggers -->
	<g class="pop t1">
		<circle class="badge" cx="30" cy="64" r="13" />
		<path class="ico" d="M25.5 58.5 h6 l3 3 v8 h-9 z" />
		<circle class="dot-accent" cx="34.5" cy="69.5" r="2.6" />
	</g>
	<g class="pop t2">
		<circle class="badge" cx="30" cy="108" r="13" />
		<circle class="ico" cx="30" cy="108" r="5.5" />
		<path class="ico" d="M30 105 V108 H32.5" />
	</g>

	<!-- Lua script -->
	<g class="pop script">
		<rect class="script-card" x="70" y="56" width="66" height="60" rx="8" />
		<text class="tag" x="128" y="67" text-anchor="end">LUA</text>
		<rect class="code-a" x="78" y="74" width="16" height="4" rx="2" />
		<rect class="code-b" x="97" y="74" width="20" height="4" rx="2" />
		<rect class="code-b" x="84" y="84" width="30" height="4" rx="2" />
		<rect class="code-a" x="84" y="94" width="12" height="4" rx="2" />
		<rect class="code-b" x="99" y="94" width="16" height="4" rx="2" />
		<rect class="code-b" x="78" y="104" width="14" height="4" rx="2" />
	</g>

	<!-- Facet hub -->
	<g class="pop hub">
		<rect class="hub-fill" x="176" y="62" width="48" height="48" rx="12" />
		<path class="hub-ink" d="M200 75 L213 81.5 L200 88 L187 81.5 Z" />
		<path class="hub-ink-line" d="M187 87 L200 93.5 L213 87" />
		<path class="hub-ink-line hub-ink-dim" d="M187 92.5 L200 99 L213 92.5" />
	</g>

	<!-- PostgreSQL -->
	<g class="pop db">
		<path class="db-body" d="M180 136 V160 A20 5.5 0 0 0 220 160 V136" />
		<path class="db-arc" d="M180 148 A20 5.5 0 0 0 220 148" />
		<ellipse class="db-top" cx="200" cy="136" rx="20" ry="5.5" />
	</g>

	<!-- Connections -->
	<g class="pop c1">
		<rect class="pill" x="268" y="30" width="84" height="20" rx="10" />
		<path class="ico" d="M276 37.5 H285 L282.5 35 M285 42.5 H276 L278.5 45" />
		<text class="lbl" x="291" y="43.5">{m.welcome_integrate_art_rest()}</text>
	</g>
	<g class="pop c2">
		<rect class="pill" x="268" y="56" width="84" height="20" rx="10" />
		<circle class="ico" cx="278.5" cy="66" r="2.8" />
		<path class="ico" d="M281.3 66 H287 M285 66 V68.5" />
		<text class="lbl" x="291" y="69.5">{m.welcome_integrate_art_api_keys()}</text>
	</g>
	<g class="pop c3">
		<rect class="pill" x="268" y="82" width="84" height="20" rx="10" />
		<path
			class="ico"
			d="M281 86.5 L286 88.3 V91.5 C286 94.5 283.8 96.2 281 97.3 C278.2 96.2 276 94.5 276 91.5 V88.3 Z"
		/>
		<text class="lbl" x="291" y="95.5">{m.welcome_integrate_art_oauth()}</text>
	</g>
	<g class="pop c4">
		<rect class="pill" x="268" y="108" width="84" height="20" rx="10" />
		<path
			class="ico"
			d="M278.5 112 V115 M283.5 112 V115 M276.5 115 H285.5 V117 A4.5 4.5 0 0 1 276.5 117 Z M281 121.5 V124"
		/>
		<text class="lbl" x="291" y="121.5">{m.welcome_integrate_art_mcp()}</text>
	</g>

	<!-- Export to another environment -->
	<rect class="slot fade" x="312" y="142" width="66" height="44" rx="9" />
	<g transform="translate(345 163)">
		<g class="bundle">
			<path class="bundle-top" d="M0 -14 L14 -7 L0 0 L-14 -7 Z" />
			<path class="bundle-left" d="M-14 -7 L0 0 L0 15 L-14 8 Z" />
			<path class="bundle-right" d="M14 -7 L0 0 L0 15 L14 8 Z" />
			<path class="bundle-shine" d="M-7 -10.5 L7 -3.5" />
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
	.wire {
		fill: none;
		stroke: var(--border-strong);
		stroke-width: 1.5;
		stroke-linecap: round;
	}
	.pill {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.badge {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.dot-accent {
		fill: var(--accent);
		stroke: var(--surface);
		stroke-width: 1;
	}
	.ico {
		fill: none;
		stroke: var(--text-2);
		stroke-width: 1.3;
		stroke-linecap: round;
		stroke-linejoin: round;
	}
	.lbl {
		font-family: var(--font-display);
		font-size: 9px;
		font-weight: 600;
		fill: var(--text);
	}
	.tag {
		font-family: var(--font-display);
		font-size: 7px;
		font-weight: 600;
		letter-spacing: 0.04em;
		fill: var(--accent);
	}
	.script-card {
		/* Always-dark slab (the ink token), so the gold tag keeps its
		   contrast in both themes. */
		fill: var(--on-accent);
	}
	.code-a {
		fill: var(--accent);
	}
	.code-b {
		fill: var(--text-3);
	}
	.hub-fill {
		fill: var(--accent);
	}
	/* Ink on a gold fill is --on-accent (the dark ink), not white. */
	.hub-ink {
		fill: var(--on-accent);
	}
	.hub-ink-line {
		fill: none;
		stroke: var(--on-accent);
		stroke-width: 2;
		stroke-linejoin: round;
		stroke-linecap: round;
	}
	.hub-ink-dim {
		opacity: 0.7;
	}
	.db-body {
		fill: var(--surface);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.db-arc {
		fill: none;
		stroke: var(--border);
		stroke-width: 1.25;
	}
	.db-top {
		fill: var(--sunken);
		stroke: var(--border-strong);
		stroke-width: 1.25;
	}
	.slot {
		fill: none;
		stroke: var(--border-strong);
		stroke-width: 1.5;
		stroke-dasharray: 5 4;
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
		stroke-width: 1.75;
		opacity: 0.7;
	}

	/* Base state is the final frame; a static render shows the complete
	   network with the bundle in its slot. */
	.pop {
		transform-box: fill-box;
		transform-origin: center;
		animation: pop 0.35s cubic-bezier(0.3, 1.6, 0.5, 1) both;
	}
	.fade {
		animation: fade 0.4s ease-out both;
	}
	.draw {
		stroke-dasharray: 100;
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
	@keyframes draw {
		from {
			stroke-dashoffset: 100;
		}
		to {
			stroke-dashoffset: 0;
		}
	}

	.hub {
		animation-delay: 0s;
	}
	.w-db {
		animation-delay: 0.2s;
	}
	.db {
		animation-delay: 0.35s;
	}
	.t1 {
		animation-delay: 0.45s;
	}
	.t2 {
		animation-delay: 0.55s;
	}
	.w-t1 {
		animation-delay: 0.6s;
	}
	.w-t2 {
		animation-delay: 0.7s;
	}
	.script {
		animation-delay: 0.75s;
	}
	.w-s {
		animation-delay: 0.95s;
	}
	.w-c1 {
		animation-delay: 1.1s;
	}
	.w-c2 {
		animation-delay: 1.2s;
	}
	.w-c3 {
		animation-delay: 1.3s;
	}
	.w-c4 {
		animation-delay: 1.4s;
	}
	.c1 {
		animation-delay: 1.3s;
	}
	.c2 {
		animation-delay: 1.4s;
	}
	.c3 {
		animation-delay: 1.5s;
	}
	.c4 {
		animation-delay: 1.6s;
	}

	/* Export: the slot appears, the bundle travels from the hub into it */
	.w-x {
		animation-delay: 1.75s;
	}
	.slot {
		animation-delay: 1.8s;
	}
	.bundle {
		transform-box: view-box;
		animation: ship 0.8s cubic-bezier(0.4, 0, 0.2, 1) 2s both;
	}
	@keyframes ship {
		0% {
			opacity: 0;
			transform: translate(-144px, -78px) scale(0.4);
		}
		20% {
			opacity: 1;
		}
		100% {
			opacity: 1;
			transform: none;
		}
	}

	/* Idle: data flows along every wire */
	.flow {
		fill: none;
		stroke: var(--accent);
		stroke-width: 1.75;
		stroke-linecap: round;
		stroke-dasharray: 3 9;
		animation:
			fade 0.6s ease-out 2.9s both,
			flow 1.1s linear 2.9s infinite;
	}
	@keyframes flow {
		from {
			stroke-dashoffset: 12;
		}
		to {
			stroke-dashoffset: 0;
		}
	}

	/* The global guard stops the flow animation, but the dash layer would
	   still show as a static overlay — the design hides it at rest. */
	@media (prefers-reduced-motion: reduce) {
		.flow {
			display: none;
		}
	}
</style>
